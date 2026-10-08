// E-mail de confirmação via Brevo (API HTTP). Desligado enquanto BREVO_API_KEY/EMAIL_FROM não estiverem definidos.
const API_KEY = process.env.BREVO_API_KEY || '';
const FROM = process.env.EMAIL_FROM || '';
const FROM_NAME = process.env.EMAIL_FROM_NAME || 'Vineyard Church Barcelona';
const REPLY_TO = process.env.EMAIL_REPLY_TO || FROM;

export const emailEnabled = () => !!(API_KEY && FROM);

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const MAPS = 'https://www.google.com/maps/search/?api=1&query=Vineyard+Church+Barcelona';

function html({ name, code, seats, status, url }) {
  const confirmed = status === 'confirmed';
  const qr = `https://api.qrserver.com/v1/create-qr-code/?size=220x220&margin=8&data=${encodeURIComponent(url)}`;
  const intro = confirmed
    ? 'Sua inscrição está <b>confirmada</b>! Mostre o QR code abaixo (ou o código) na entrada.'
    : 'Você está na <b>lista de espera</b>. Se abrir vaga, avisamos — e seu ingresso passa a aparecer como confirmado.';
  return `<!doctype html><html><body style="margin:0;background:#eef1f5;font-family:Arial,Helvetica,sans-serif;color:#0a1626">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef1f5;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:16px;overflow:hidden">
<tr><td style="background:#0a1626;padding:22px 24px;border-bottom:5px solid #ffd21f">
  <div style="color:#a9b8cc;font-size:11px;letter-spacing:2px;text-transform:uppercase;font-weight:bold">Vineyard Church Barcelona</div>
  <div style="color:#ffffff;font-size:28px;font-weight:bold;margin-top:4px">LUCIANO <span style="color:#ffd21f">MANGA</span></div>
</td></tr>
<tr><td style="padding:24px">
  <p style="margin:0 0 12px;font-size:17px">Olá, <b>${esc(name.split(' ')[0])}</b>!</p>
  <p style="margin:0 0 18px;font-size:15px;line-height:1.5">${intro}</p>
  <table role="presentation" width="100%" style="background:#f6f1de;border-radius:12px"><tr><td style="padding:16px 18px;font-size:15px;line-height:1.7">
    <b>📅 Domingo, 3 de janeiro</b><br>🕔 17h às 19h<br>📍 <a href="${MAPS}" style="color:#0a1626">Vineyard Church Barcelona</a><br>
    👥 ${seats} ${seats === 1 ? 'lugar' : 'lugares'} · ${esc(name)}
  </td></tr></table>
  ${confirmed ? `<p style="text-align:center;margin:22px 0 6px"><img src="${qr}" width="220" height="220" alt="QR code do ingresso" style="display:inline-block"></p>` : ''}
  <p style="text-align:center;margin:6px 0 4px;font-size:12px;letter-spacing:2px;color:#3a4a5e;font-weight:bold">CÓDIGO</p>
  <p style="text-align:center;margin:0 0 20px;font-family:Menlo,Consolas,monospace;font-size:28px;letter-spacing:6px;font-weight:bold">${esc(code)}</p>
  <p style="text-align:center;margin:0 0 18px"><a href="${url}" style="background:#ffd21f;color:#1a1400;text-decoration:none;font-weight:bold;padding:13px 22px;border-radius:10px;display:inline-block">Ver meu ingresso</a></p>
  <p style="margin:0;font-size:13px;color:#5a6a7e;line-height:1.5;text-align:center">Não vai poder ir? Abra seu ingresso e cancele para liberar o lugar para outra pessoa.</p>
</td></tr>
<tr><td style="background:#0a1626;color:#ffffff;text-align:center;padding:14px;font-weight:bold;letter-spacing:3px;font-size:14px">PALAVRA <span style="color:#ffd21f">•</span> COMUNHÃO</td></tr>
</table></td></tr></table></body></html>`;
}

// Nunca lança: falha no e-mail não pode derrubar a inscrição.
export async function sendTicketEmail({ email, name, code, seats, status, origin }) {
  if (!emailEnabled() || !email) return false;
  const url = `${process.env.PUBLIC_URL || origin}/t/${code}`;
  const subject = status === 'confirmed'
    ? `Sua entrada para Luciano Manga em Barcelona · ${code}`
    : `Lista de espera · Luciano Manga em Barcelona`;
  try {
    const res = await fetch('https://api.brevo.com/v3/smtp/email', {
      method: 'POST',
      headers: { 'api-key': API_KEY, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({
        sender: { name: FROM_NAME, email: FROM },
        replyTo: { email: REPLY_TO },
        to: [{ email, name }],
        subject,
        htmlContent: html({ name, code, seats, status, url }),
      }),
    });
    if (!res.ok) { console.error(`email ${code}: ${res.status} ${await res.text()}`); return false; }
    return true;
  } catch (e) {
    console.error(`email ${code}: ${e.message}`);
    return false;
  }
}
