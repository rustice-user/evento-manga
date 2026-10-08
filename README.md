# Luciano Manga em Barcelona · Inscrições

App de inscrição gratuita com controle de aforo para o encontro com **Luciano Manga**
(ex-vocalista da Oficina G3) na **Vineyard Church Barcelona** — domingo, 3 de janeiro (2027), 17h às 19h.

## Links

- Página pública: https://br-still-boat-b26dg009-eventomanga.compute.c-6.eu-central-1.aws.neon.tech/
- Painel da equipe: https://br-still-boat-b26dg009-eventomanga.compute.c-6.eu-central-1.aws.neon.tech/admin

## O que faz

**Página pública (`/`)**
- Cartaz, informações do evento e contador de lugares disponíveis em tempo real.
- Formulário: nome, e-mail, WhatsApp (opcional), nº de lugares (1–4 por padrão), como soube, consentimento de dados.
- Gera um **ingresso com QR code** e código de 6 letras, com link próprio (`/t/CÓDIGO`).
- Ingresso: adicionar ao calendário (.ics), imprimir, convidar amigos no WhatsApp, cancelar (libera o lugar).
- Mesmo e-mail não se inscreve duas vezes (devolve o ingresso existente).
- Quando lota, oferece **lista de espera**.
- "Recuperar meu ingresso" com primeiro nome + e-mail.

**Painel da equipe (`/admin`)** — protegido por chave de acesso
- Números: confirmados / capacidade, lugares livres, quem já entrou, lista de espera.
- **Check-in na porta**: escanear QR pela câmera do celular ou digitar o código.
- Configurar capacidade, máximo de lugares por inscrição, abrir/fechar inscrições e lista de espera.
- Lista com busca e filtros; check-in, desfazer, cancelar, restaurar, confirmar quem está na espera
  (com link direto para o WhatsApp da pessoa).
- Exportar CSV (abre no Excel).

## Arquitetura

- **Neon Function** (`src/index.js`): serve as páginas e a API. Sem dependências em runtime.
- **Postgres na Neon**, schema isolado `evento_manga` (`db/schema.sql`). Toda a regra de negócio
  (aforo, lista de espera, duplicados, check-in) está em funções SQL. A inscrição trava a linha de
  configuração (`FOR UPDATE`), então duas pessoas ao mesmo tempo nunca estouram a capacidade.
- A Function usa um usuário de banco restrito (`evento_manga_web`) que só enxerga esse schema.

### Variáveis de ambiente da Function

| Variável | Uso |
| --- | --- |
| `APP_DATABASE_URL` | connection string do usuário `evento_manga_web` |
| `ADMIN_KEY` | chave de acesso do painel `/admin` |
| `POSTER_URL` | URL pública da imagem do cartaz: `https://raw.githubusercontent.com/rustice-user/evento-manga/main/public/poster.jpg` |

## Deploy

```bash
npm install
npm run build                       # gera dist/function.zip
neon functions deploy eventomanga --src dist/index.mjs --no-bundle \
  --env APP_DATABASE_URL=... --env ADMIN_KEY=... --env POSTER_URL=...
```

Alterações no banco: aplicar `db/schema.sql` (idempotente).
