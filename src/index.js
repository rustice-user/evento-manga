// Neon Function: inscrições + controle de aforo para o encontro com Luciano Manga.
// Serve a página pública (/), o ingresso (/t/:code), o painel (/admin) e a API (/api/*).
// Toda a regra de negócio está em db/schema.sql; aqui só roteamos HTTP -> funções SQL.
// Sem dependências: fala com o Postgres pelo endpoint SQL-over-HTTP da Neon.
import { timingSafeEqual } from 'node:crypto';
import indexHtml from '../public/index.html';
import adminHtml from '../public/admin.html';
import { sendTicketEmail } from './email.js';

// APP_DATABASE_URL: usuário restrito ao schema evento_manga.
const DB_URL = process.env.APP_DATABASE_URL || '';
const SQL_ENDPOINT = DB_URL ? 'https://' + new URL(DB_URL).hostname.replace(/^[^.]+\./, 'api.') + '/sql' : '';
const ADMIN_KEY = process.env.ADMIN_KEY || '';
const POSTER_URL = process.env.POSTER_URL || '';

async function call(fn, ...params) {
  const placeholders = params.map((_, i) => `$${i + 1}`).join(', ');
  const res = await fetch(SQL_ENDPOINT, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Neon-Connection-String': DB_URL,
      'Neon-Raw-Text-Output': 'true',
      'Neon-Array-Mode': 'true',
    },
    body: JSON.stringify({ query: `SELECT evento_manga.${fn}(${placeholders})::text`, params }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`${fn}: ${body.message || res.status}`);
  return JSON.parse(body.rows[0][0]);
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, X-Admin-Key',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

function json(data) {
  const { http = 200, ...rest } = data;
  return new Response(JSON.stringify(rest), {
    status: http,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...CORS },
  });
}

const page = (body) => new Response(body.replaceAll('%POSTER_URL%', POSTER_URL), {
  headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' },
});

function isAdmin(req) {
  const k = req.headers.get('X-Admin-Key') || '';
  if (!ADMIN_KEY || k.length !== ADMIN_KEY.length) return false;
  return timingSafeEqual(Buffer.from(k), Buffer.from(ADMIN_KEY));
}

async function body(req) {
  try { const b = await req.json(); return b && typeof b === 'object' ? b : {}; } catch { return {}; }
}

async function route(req) {
  const { pathname } = new URL(req.url);
  const m = req.method;
  let p;

  if (m === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (m === 'GET' && (pathname === '/' || /^\/t\/[A-Za-z0-9]+\/?$/.test(pathname))) return page(indexHtml);
  if (m === 'GET' && pathname === '/admin') return page(adminHtml);
  if (m === 'GET' && pathname === '/health') return new Response('ok');

  // ---- API pública ----
  if (m === 'GET' && pathname === '/api/status') return json(await call('status'));
  if (m === 'POST' && pathname === '/api/register') {
    const b = await body(req);
    const r = await call('register', JSON.stringify(b));
    if (r.http === 201) {
      r.email_sent = await sendTicketEmail({ email: String(b.email).trim(), ...r.ticket, origin: new URL(req.url).origin });
    }
    return json(r);
  }
  if (m === 'POST' && pathname === '/api/lookup') return json(await call('lookup', JSON.stringify(await body(req))));
  if (m === 'GET' && (p = pathname.match(/^\/api\/ticket\/([^/]+)$/))) return json(await call('ticket', p[1]));
  if (m === 'POST' && (p = pathname.match(/^\/api\/ticket\/([^/]+)\/cancel$/))) return json(await call('cancel', p[1]));

  // ---- API admin ----
  if (pathname.startsWith('/api/admin/')) {
    if (!isAdmin(req)) return json({ http: 401, error: 'Chave de acesso inválida.' });
    if (m === 'GET' && pathname === '/api/admin/summary') return json(await call('admin_summary'));
    if (m === 'GET' && pathname === '/api/admin/registrations') return json(await call('admin_list'));
    if (m === 'POST' && pathname === '/api/admin/settings') return json(await call('admin_settings', JSON.stringify(await body(req))));
    if (m === 'POST' && (p = pathname.match(/^\/api\/admin\/registrations\/([^/]+)\/([a-z_]+)$/))) {
      const r = await call('admin_action', decodeURIComponent(p[1]), p[2]);
      // Quem sai da lista de espera recebe o ingresso confirmado por e-mail.
      if (p[2] === 'promote' && r.registration) {
        r.email_sent = await sendTicketEmail({ ...r.registration, origin: new URL(req.url).origin });
      }
      return json(r);
    }
  }
  return pathname.startsWith('/api/') ? json({ http: 404, error: 'Não encontrado.' }) : new Response('Não encontrado', { status: 404 });
}

export default {
  async fetch(req) {
    let res;
    try {
      res = await route(req);
    } catch (e) {
      console.error(e);
      res = json({ http: 500, error: 'Erro no servidor. Tente de novo em instantes.' });
    }
    const { pathname } = new URL(req.url);
    if (pathname.startsWith('/api/')) console.log(`${req.method} ${pathname.replace(/\/t(icket)?\/[^/]+/, '/ticket/:code')} -> ${res.status}`);
    return res;
  },
};
