-- Esquema do evento Luciano Manga (schema isolado: evento_manga).
-- Toda a regra de negócio fica aqui; a Neon Function só roteia HTTP -> estas funções.
-- Cada função devolve jsonb; a chave "http" (opcional) define o status HTTP da resposta.

CREATE SCHEMA IF NOT EXISTS evento_manga;

CREATE TABLE IF NOT EXISTS evento_manga.settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  capacity int NOT NULL DEFAULT 150 CHECK (capacity >= 0),
  max_per_registration int NOT NULL DEFAULT 4,
  registrations_open boolean NOT NULL DEFAULT true,
  waitlist_enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO evento_manga.settings (id) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS evento_manga.registrations (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  email text NOT NULL,
  phone text,
  seats int NOT NULL CHECK (seats BETWEEN 1 AND 10),
  status text NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed','waitlist','cancelled')),
  how_heard text,
  created_at timestamptz NOT NULL DEFAULT now(),
  checked_in_at timestamptz,
  cancelled_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS registrations_active_email ON evento_manga.registrations (lower(email)) WHERE status <> 'cancelled';
CREATE INDEX IF NOT EXISTS registrations_status ON evento_manga.registrations (status, created_at);

-- ---------- helpers ----------
CREATE OR REPLACE FUNCTION evento_manga.public_ticket(r evento_manga.registrations) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('code', r.code, 'name', r.name, 'seats', r.seats, 'status', r.status,
                            'checked_in', r.checked_in_at IS NOT NULL, 'created_at', r.created_at)
$$;

CREATE OR REPLACE FUNCTION evento_manga.new_code() RETURNS text
LANGUAGE sql VOLATILE AS $$
  SELECT string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
    FROM generate_series(1, 6)
$$;

CREATE OR REPLACE FUNCTION evento_manga.norm_code(c text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT left(regexp_replace(upper(coalesce(c, '')), '[^A-Z0-9]', '', 'g'), 12) $$;

CREATE OR REPLACE FUNCTION evento_manga.clean(v text, n int) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT left(btrim(regexp_replace(coalesce(v, ''), '\s+', ' ', 'g')), n) $$;

CREATE OR REPLACE FUNCTION evento_manga.phone_key(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN length(d) >= 8 THEN right(d, 9) END FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS d) x
$$;

-- ---------- público ----------
CREATE OR REPLACE FUNCTION evento_manga.status() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'capacity', s.capacity,
    'taken', t.taken,
    'waitlist', t.waitlist,
    'remaining', greatest(0, s.capacity - t.taken),
    'open', s.registrations_open,
    'waitlist_enabled', s.waitlist_enabled,
    'max_per_registration', s.max_per_registration)
  FROM evento_manga.settings s,
       LATERAL (SELECT coalesce(sum(seats) FILTER (WHERE status = 'confirmed'), 0)::int AS taken,
                       coalesce(sum(seats) FILTER (WHERE status = 'waitlist'), 0)::int AS waitlist
                  FROM evento_manga.registrations) t
  WHERE s.id = 1
$$;

CREATE OR REPLACE FUNCTION evento_manga.register(p jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  cfg evento_manga.settings;
  v_name text := evento_manga.clean(p->>'name', 120);
  v_email text := lower(evento_manga.clean(p->>'email', 160));
  v_phone text := nullif(evento_manga.clean(p->>'phone', 40), '');
  v_how text := nullif(evento_manga.clean(p->>'how_heard', 200), '');
  v_seats int;
  v_taken int;
  v_remaining int;
  v_status text := 'confirmed';
  r evento_manga.registrations;
BEGIN
  IF coalesce(p->>'website', '') <> '' THEN RETURN jsonb_build_object('http', 400, 'error', 'Pedido inválido.'); END IF;
  IF length(v_name) < 2 THEN RETURN jsonb_build_object('http', 400, 'error', 'Informe seu nome.'); END IF;
  IF v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' THEN RETURN jsonb_build_object('http', 400, 'error', 'Informe um e-mail válido.'); END IF;
  IF coalesce((p->>'consent')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('http', 400, 'error', 'É preciso aceitar o uso dos dados para a inscrição.');
  END IF;

  -- Trava a configuração: serializa inscrições simultâneas e evita overbooking.
  SELECT * INTO cfg FROM evento_manga.settings WHERE id = 1 FOR UPDATE;

  v_seats := CASE WHEN (p->>'seats') ~ '^\d{1,2}$' THEN (p->>'seats')::int END;
  IF v_seats IS NULL OR v_seats < 1 OR v_seats > cfg.max_per_registration THEN
    RETURN jsonb_build_object('http', 400, 'error', format('Escolha entre 1 e %s lugares.', cfg.max_per_registration));
  END IF;

  SELECT * INTO r FROM evento_manga.registrations WHERE lower(email) = v_email AND status <> 'cancelled';
  IF FOUND THEN RETURN jsonb_build_object('already', true, 'ticket', evento_manga.public_ticket(r)); END IF;

  -- Mesmo WhatsApp com outro e-mail: bloqueia (compara os últimos 9 dígitos, ignora +34/+55, espaços etc.).
  IF evento_manga.phone_key(v_phone) IS NOT NULL AND EXISTS (
       SELECT 1 FROM evento_manga.registrations
        WHERE status <> 'cancelled' AND evento_manga.phone_key(phone) = evento_manga.phone_key(v_phone)) THEN
    RETURN jsonb_build_object('http', 409, 'error',
      'Este WhatsApp já tem uma inscrição. Se for você, use "Recuperar meu ingresso" com o e-mail usado. Para trazer mais pessoas, aumente a quantidade de lugares na mesma inscrição.');
  END IF;

  IF NOT cfg.registrations_open THEN RETURN jsonb_build_object('http', 409, 'error', 'As inscrições estão encerradas.'); END IF;

  SELECT coalesce(sum(seats), 0) INTO v_taken FROM evento_manga.registrations WHERE status = 'confirmed';
  v_remaining := cfg.capacity - v_taken;
  IF v_seats > v_remaining THEN
    IF NOT cfg.waitlist_enabled OR coalesce((p->>'accept_waitlist')::boolean, false) IS NOT TRUE THEN
      RETURN jsonb_build_object('http', 409, 'full', true, 'remaining', greatest(v_remaining, 0),
        'waitlist_enabled', cfg.waitlist_enabled,
        'error', CASE WHEN v_remaining > 0
          THEN format('Só restam %s lugar(es). Diminua a quantidade%s.', v_remaining,
                      CASE WHEN cfg.waitlist_enabled THEN ' ou entre na lista de espera' ELSE '' END)
          ELSE 'Lotado!' || CASE WHEN cfg.waitlist_enabled THEN ' Você pode entrar na lista de espera.' ELSE '' END END);
    END IF;
    v_status := 'waitlist';
  END IF;

  FOR i IN 1..5 LOOP
    INSERT INTO evento_manga.registrations (code, name, email, phone, seats, status, how_heard)
    VALUES (evento_manga.new_code(), v_name, v_email, v_phone, v_seats, v_status, v_how)
    ON CONFLICT (code) DO NOTHING
    RETURNING * INTO r;
    EXIT WHEN r.id IS NOT NULL;
  END LOOP;
  RETURN jsonb_build_object('http', 201, 'ticket', evento_manga.public_ticket(r));
END $$;

CREATE OR REPLACE FUNCTION evento_manga.ticket(p_code text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT jsonb_build_object('ticket', evento_manga.public_ticket(r))
       FROM evento_manga.registrations r WHERE r.code = evento_manga.norm_code(p_code)),
    jsonb_build_object('http', 404, 'error', 'Ingresso não encontrado.'))
$$;

-- Recuperar ingresso com e-mail + primeiro nome.
CREATE OR REPLACE FUNCTION evento_manga.lookup(p jsonb) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT jsonb_build_object('ticket', evento_manga.public_ticket(r))
       FROM evento_manga.registrations r
      WHERE lower(r.email) = lower(evento_manga.clean(p->>'email', 160)) AND r.status <> 'cancelled'
        AND split_part(lower(r.name), ' ', 1) = split_part(lower(evento_manga.clean(p->>'name', 120)), ' ', 1)
        AND evento_manga.clean(p->>'name', 120) <> ''),
    jsonb_build_object('http', 404, 'error', 'Não encontramos inscrição com esses dados.'))
$$;

CREATE OR REPLACE FUNCTION evento_manga.cancel(p_code text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r evento_manga.registrations;
BEGIN
  UPDATE evento_manga.registrations SET status = 'cancelled', cancelled_at = now()
   WHERE code = evento_manga.norm_code(p_code) AND status <> 'cancelled' AND checked_in_at IS NULL
  RETURNING * INTO r;
  IF NOT FOUND THEN RETURN jsonb_build_object('http', 404, 'error', 'Não foi possível cancelar.'); END IF;
  RETURN jsonb_build_object('ticket', evento_manga.public_ticket(r));
END $$;

-- ---------- admin (a Function só chama depois de validar ADMIN_KEY) ----------
CREATE OR REPLACE FUNCTION evento_manga.admin_summary() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT evento_manga.status() || jsonb_build_object(
    'registrations_open', s.registrations_open,
    'checked_in', (SELECT coalesce(sum(seats), 0)::int FROM evento_manga.registrations WHERE status = 'confirmed' AND checked_in_at IS NOT NULL))
  FROM evento_manga.settings s WHERE s.id = 1
$$;

CREATE OR REPLACE FUNCTION evento_manga.admin_list() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('registrations', coalesce(jsonb_agg(to_jsonb(r) - 'id' ORDER BY r.created_at), '[]'::jsonb))
    FROM evento_manga.registrations r
$$;

CREATE OR REPLACE FUNCTION evento_manga.admin_settings(p jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE cap int; mx int;
BEGIN
  cap := CASE WHEN (p->>'capacity') ~ '^\d{1,6}$' THEN (p->>'capacity')::int END;
  mx := CASE WHEN (p->>'max_per_registration') ~ '^\d{1,2}$' THEN (p->>'max_per_registration')::int END;
  IF cap IS NULL THEN RETURN jsonb_build_object('http', 400, 'error', 'Capacidade inválida.'); END IF;
  IF mx IS NULL OR mx < 1 OR mx > 10 THEN RETURN jsonb_build_object('http', 400, 'error', 'Máximo por inscrição deve ser 1–10.'); END IF;
  UPDATE evento_manga.settings SET capacity = cap, max_per_registration = mx,
         registrations_open = coalesce((p->>'registrations_open')::boolean, false),
         waitlist_enabled = coalesce((p->>'waitlist_enabled')::boolean, false),
         updated_at = now()
   WHERE id = 1;
  RETURN evento_manga.admin_summary();
END $$;

-- p_action: checkin | undo_checkin | cancel | restore | promote
CREATE OR REPLACE FUNCTION evento_manga.admin_action(p_code text, p_action text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r evento_manga.registrations; c text := evento_manga.norm_code(p_code);
BEGIN
  SELECT * INTO r FROM evento_manga.registrations WHERE code = c FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('http', 404, 'error', format('Código %s não encontrado.', c)); END IF;

  IF p_action = 'checkin' THEN
    IF r.status <> 'confirmed' THEN
      RETURN jsonb_build_object('http', 409, 'registration', to_jsonb(r) - 'id',
        'error', CASE r.status WHEN 'waitlist' THEN 'Inscrição na lista de espera.' ELSE 'Inscrição cancelada.' END);
    END IF;
    IF r.checked_in_at IS NOT NULL THEN
      RETURN jsonb_build_object('warning', 'Já fez check-in.', 'registration', to_jsonb(r) - 'id');
    END IF;
    UPDATE evento_manga.registrations SET checked_in_at = now() WHERE id = r.id RETURNING * INTO r;
  ELSIF p_action = 'undo_checkin' THEN
    UPDATE evento_manga.registrations SET checked_in_at = NULL WHERE id = r.id RETURNING * INTO r;
  ELSIF p_action = 'cancel' THEN
    UPDATE evento_manga.registrations SET status = 'cancelled', cancelled_at = now(), checked_in_at = NULL WHERE id = r.id RETURNING * INTO r;
  ELSIF p_action IN ('restore', 'promote') THEN
    -- Volta para confirmado sem checar capacidade: decisão consciente da equipe.
    UPDATE evento_manga.registrations SET status = 'confirmed', cancelled_at = NULL WHERE id = r.id RETURNING * INTO r;
  ELSE
    RETURN jsonb_build_object('http', 400, 'error', 'Ação inválida.');
  END IF;
  RETURN jsonb_build_object('registration', to_jsonb(r) - 'id');
END $$;

-- ---------- usuário restrito usado pela Function ----------
-- CREATE ROLE evento_manga_web LOGIN PASSWORD '...' CONNECTION LIMIT 10;   (feito uma vez, fora do repo)
GRANT USAGE ON SCHEMA evento_manga TO evento_manga_web;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA evento_manga TO evento_manga_web;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA evento_manga TO evento_manga_web;
