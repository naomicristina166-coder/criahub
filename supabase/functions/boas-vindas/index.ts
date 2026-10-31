/* CriaHub · e-mail de boas-vindas da lista de espera
   Quem chama: o gatilho do banco (supabase/boas-vindas.sql) sempre que alguém entra em public.waitlist.
   O que faz: busca a inscrição, manda o e-mail pelo Resend e marca welcomed_at (nunca manda duas vezes).

   Como colocar no ar (uma vez):
   1. Supabase › Edge Functions › Deploy a new function › Via Editor › nome: boas-vindas › cole este arquivo › Deploy
   2. Na função boas-vindas › Details: desligue "Verify JWT with legacy secret" › Save
   3. Edge Functions › Secrets (Manage secrets), adicione:
        RESEND_API_KEY        a chave do Resend (começa com re_)
        WAITLIST_HOOK_SECRET  o código que aparece no fim do supabase/boas-vindas.sql
        MAIL_FROM             (opcional) ex.: CriaHub <oi@criahub.app.br>
        MAIL_REPLY_TO         (opcional) ex.: criahubb@gmail.com */
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const env = (k: string) => Deno.env.get(k) || '';
const sb = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
const FROM = env('MAIL_FROM') || 'CriaHub <oi@criahub.app.br>';
const REPLY_TO = env('MAIL_REPLY_TO') || 'criahubb@gmail.com';
const LAUNCH = '23 de novembro';

const esc = (s: string) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const firstName = (n: string) => (String(n || '').trim().split(/\s+/)[0] || 'cria').slice(0, 40);

export function welcomeEmail(row: { name: string; pain?: string | null }) {
  const nome = esc(firstName(row.name));
  const pain = row.pain ? esc(String(row.pain).trim().slice(0, 280)) : '';
  const subject = 'Você está na lista, cria! 🍒';
  const text = [
    `Oi, ${firstName(row.name)}!`,
    '',
    'Que bom ter você aqui. Você acabou de entrar na lista de espera do CriaHub, o app que junta rotina, marcas, conteúdo e dinheiro de quem cria num lugar só.',
    '',
    'O que acontece agora:',
    `1. No dia ${LAUNCH}, você recebe o acesso antes de todo mundo.`,
    '2. O valor do Pro chega primeiro pra você, com uma condição especial de lançamento.',
    '3. Até lá, eu mostro os bastidores no Instagram: @criahubapp e @naomicristinna_',
    ...(row.pain ? ['', `Você me contou que o que mais te atrapalha é: "${String(row.pain).trim()}". Anotei. É exatamente pra isso que o CriaHub existe.`] : []),
    '',
    'Qualquer dúvida, é só responder este e-mail.',
    '',
    'Com carinho,',
    'Naomi',
    'Fundadora do CriaHub',
    'quem cria, se organiza.',
  ].join('\n');

  const btn = (href: string, label: string, bg: string, fg: string) =>
    `<a href="${href}" style="display:inline-block;background:${bg};color:${fg};text-decoration:none;font:700 15px/1 Arial,Helvetica,sans-serif;padding:14px 22px;border-radius:999px;margin:4px 6px 4px 0">${label}</a>`;
  const step = (n: string, t: string) =>
    `<tr><td valign="top" style="padding:0 12px 14px 0;width:34px"><div style="width:30px;height:30px;border-radius:50%;background:#F2C9CF;color:#420725;font:700 15px/30px Arial,Helvetica,sans-serif;text-align:center">${n}</div></td><td style="padding:4px 0 14px;font:400 16px/1.5 Arial,Helvetica,sans-serif;color:#2A1218">${t}</td></tr>`;

  const html = `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${subject}</title></head>
<body style="margin:0;padding:0;background:#F6EEE8">
<div style="display:none;max-height:0;overflow:hidden;opacity:0">Dia ${LAUNCH} você recebe o acesso antes de todo mundo.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F6EEE8"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:24px;overflow:hidden">
  <tr><td style="background:#420725;padding:36px 32px 32px">
    <div style="font:700 40px/1 Arial,Helvetica,sans-serif;letter-spacing:-1.5px"><span style="color:#F2C9CF">cria</span><span style="color:#ffffff">hub</span></div>
    <div style="font:700 30px/1.15 Georgia,'Times New Roman',serif;color:#F6EEE8;margin-top:26px">Você está na lista, <em style="color:#F2C9CF">${nome}</em>!</div>
    <div style="font:400 16px/1.5 Arial,Helvetica,sans-serif;color:#E3C9CE;margin-top:12px">Lançamento em ${LAUNCH}</div>
  </td></tr>
  <tr><td style="padding:32px">
    <p style="margin:0 0 18px;font:400 16px/1.6 Arial,Helvetica,sans-serif;color:#2A1218">Que bom ter você aqui. Você acabou de entrar na lista de espera do <b>CriaHub</b>, o app que junta rotina, marcas, conteúdo e dinheiro de quem cria num lugar só.</p>
    <p style="margin:0 0 14px;font:700 13px/1 Arial,Helvetica,sans-serif;letter-spacing:1.5px;text-transform:uppercase;color:#7A4A53">O que acontece agora</p>
    <table role="presentation" cellpadding="0" cellspacing="0">
      ${step('1', `No dia <b>${LAUNCH}</b>, você recebe o acesso antes de todo mundo.`)}
      ${step('2', 'O valor do Pro chega primeiro pra você, com uma condição especial de lançamento.')}
      ${step('3', 'Até lá, eu mostro os bastidores no Instagram.')}
    </table>
    <div style="margin:6px 0 4px">${btn('https://www.instagram.com/criahubapp/', 'Seguir @criahubapp', '#420725', '#F6EEE8')}${btn('https://www.instagram.com/naomicristinna_/', 'Seguir @naomicristinna_', '#F2C9CF', '#420725')}</div>
    ${pain ? `<div style="margin:26px 0 0;padding:18px 20px;border-radius:16px;background:#F7DDE1;font:400 15px/1.55 Arial,Helvetica,sans-serif;color:#2A1218">Você me contou que o que mais te atrapalha é:<br><i style="font-family:Georgia,'Times New Roman',serif;font-size:17px;color:#420725">"${pain}"</i><br>Anotei. É exatamente pra isso que o CriaHub existe.</div>` : ''}
    <p style="margin:26px 0 0;font:400 16px/1.6 Arial,Helvetica,sans-serif;color:#2A1218">Qualquer dúvida, é só responder este e-mail.</p>
    <p style="margin:22px 0 0;font:400 16px/1.5 Arial,Helvetica,sans-serif;color:#2A1218">Com carinho,<br><b>Naomi</b><br><span style="color:#7A4A53">Fundadora do CriaHub</span></p>
  </td></tr>
  <tr><td style="background:#420725;padding:22px 32px;font:italic 700 18px/1.3 Georgia,'Times New Roman',serif;color:#F2C9CF">quem cria, se organiza.
    <div style="font:400 12px/1.5 Arial,Helvetica,sans-serif;color:#E3C9CE;font-style:normal;margin-top:8px">Você recebeu este e-mail porque entrou na lista de espera em criahub.app.br/lista. Pra sair, responda com "sair".</div>
  </td></tr>
</table>
</td></tr></table>
</body></html>`;
  return { subject, html, text };
}

Deno.serve(async req => {
  if (req.method !== 'POST') return new Response('ok');
  const secret = env('WAITLIST_HOOK_SECRET');
  if (!secret || req.headers.get('x-hook-secret') !== secret) return new Response('nope', { status: 401 });

  const { id } = await req.json().catch(() => ({}));
  if (!id) return new Response('sem id', { status: 400 });

  const { data: row, error } = await sb.from('waitlist').select('id,name,email,pain,welcomed_at').eq('id', id).maybeSingle();
  if (error || !row) return new Response('não achei', { status: 404 });
  if (row.welcomed_at) return new Response('já enviado');

  const key = env('RESEND_API_KEY');
  if (!key) return new Response('falta RESEND_API_KEY', { status: 500 });

  const mail = welcomeEmail(row);
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to: [row.email], reply_to: REPLY_TO, subject: mail.subject, html: mail.html, text: mail.text }),
  });
  if (!r.ok) return new Response(`resend: ${r.status} ${await r.text()}`, { status: 502 });

  await sb.from('waitlist').update({ welcomed_at: new Date().toISOString() }).eq('id', id);
  return new Response('enviado');
});
