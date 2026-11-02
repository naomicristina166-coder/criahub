/* CriaHub · função "caixa": e-mails importantes encaminhados pela creator
   • POST do Postmark (webhook de entrada, ?t=<segredo>) → guarda remetente, assunto, data e um trechinho
   • POST {action:'lembrar', key} do agendador → 1 lembrete no celular para e-mail sem "Abrir"/"Já vi" há 24h
   • POST {action:'aniver', key} do agendador (9h) → parabéns no celular de quem faz aniversário hoje
   • POST {action:'aquecer', key} do agendador (a cada minuto, só quando tem alarme vencido) → avisa que o
     cronômetro do aquecimento acabou (tabela public.warm_alerts, rode supabase/aquecimento-alarme.sql)
   Não guarda o e-mail inteiro, não lê a caixa de ninguém e não usa IA: a classificação é por palavras.

   Como ligar (uma vez só), no painel do Supabase:
   1. Edge Functions › Deploy a new function › Via Editor › nome: caixa › cole este arquivo › Deploy
   2. Na função caixa › Details: desligue "Verify JWT with legacy secret" (o Postmark não manda login) › Save
   3. Rode supabase/emails.sql no SQL Editor
   O lembrete no celular usa as mesmas chaves da função "push" (tabela private.push_vapid). */
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const env = (...k: string[]) => k.map(x => Deno.env.get(x)).find(Boolean);
const keyOk = async (kind: string, val: string | null) => !!val && (await sb.rpc('mail_key_ok', { p_kind: kind, p_val: val })).data === true;

const fold = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const has = (t: string, words: string[]) => words.some(w => new RegExp('(^|[^a-z0-9])' + w + '($|[^a-z0-9])').test(t));
const MEI = ['das[ -]mei', 'das do mei', 'guia do das', 'mei', 'pgmei', 'simples nacional', 'receita federal', 'gov\\.br', 'inss', 'imposto', 'impostos', 'cnpj', 'nota fiscal', 'nfs-?e', 'darf'];
const PAG = ['pagamento', 'pagamentos', 'pix', 'fatura', 'recebimento', 'transferencia', 'deposito', 'comprovante', 'invoice', 'payment', 'payout', 'remessa', 'reembolso', 'boleto', 'cobranca'];
const PROP = ['proposta', 'parceria', 'parcerias', 'collab', 'publi', 'publipost', 'campanha', 'ugc', 'briefing', 'contrato', 'oportunidade', 'vaga', 'job', 'entrevista', 'influenciador(a)?', 'creator', 'convite', 'orcamento', 'partnership', 'sponsorship', 'brand deal', 'freela'];
function kindOf(from: string, subject: string, text: string) {
  const t = fold(from + ' ' + subject + ' ' + text.slice(0, 1500));
  if (has(t, MEI)) return 'mei';
  if (has(t, PAG)) return 'pagamento';
  if (has(t, PROP)) return 'proposta';
  return 'outro';
}
const clean = (s: string) => s.replace(/\r/g, '').split('\n').filter(l => !/^\s*>/.test(l)).join(' ').replace(/\s+/g, ' ').trim();

async function inbound(req: Request, url: URL) {
  if (!(await keyOk('hook', url.searchParams.get('t')))) return new Response('forbidden', { status: 403 });
  let m: Record<string, any>; try { m = await req.json(); } catch { return new Response('bad json', { status: 400 }); }
  /* apelido: depois do + no endereço (o Postmark manda como MailboxHash) */
  const rcpts = [m.OriginalRecipient, m.To, m.Cc, ...(m.ToFull || []).map((x: any) => x.Email)].filter(Boolean).join(',');
  const alias = (m.MailboxHash || (/\+([a-z0-9]{6,20})@/i.exec(rcpts) || [])[1] || '').toLowerCase();
  if (!alias) return Response.json({ ok: false, why: 'sem apelido' });
  const { data: who } = await sb.from('mail_alias').select('user_id').eq('alias', alias).maybeSingle();
  if (!who) return Response.json({ ok: false, why: 'apelido desconhecido' });

  const fromAddr = String(m.FromFull?.Email || m.From || '').slice(0, 200), fromName = String(m.FromFull?.Name || m.FromName || '').slice(0, 120);
  const subject = String(m.Subject || '(sem assunto)').slice(0, 250);
  const text = String(m.TextBody || '').trim() || String(m.HtmlBody || '').replace(/<style[\s\S]*?<\/style>|<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ');
  const hdr = (n: string) => ((m.Headers || []).find((h: any) => String(h.Name).toLowerCase() === n) || {}).Value;
  const row: Record<string, unknown> = { user_id: who.user_id, from_addr: fromAddr, from_name: fromName, subject, snippet: clean(text).slice(0, 240), msgid: String(hdr('message-id') || m.MessageID || '').slice(0, 300) || null };

  /* confirmação de encaminhamento do Gmail: mostra o código no app */
  if (/forwarding-noreply@google\.com/i.test(fromAddr)) {
    const code = (/\(#(\d{6,12})\)/.exec(subject) || /(?:c[oó]digo|code)[^0-9]{0,40}(\d{6,12})/i.exec(text) || [])[1] || null;
    const link = (/https:\/\/mail-settings\.google\.com\/mail\/vf-[^\s"'<>]+/.exec(text + ' ' + String(m.HtmlBody || '')) || [])[0] || null;
    Object.assign(row, { kind: 'confirma', code, link, snippet: 'Confirmação do encaminhamento do Gmail' });
  } else row.kind = kindOf(fromName + ' ' + fromAddr, subject, text);

  const { error } = row.msgid
    ? await sb.from('mail_msgs').upsert(row, { onConflict: 'user_id,msgid', ignoreDuplicates: true })
    : await sb.from('mail_msgs').insert(row);
  if (error) return new Response(error.message, { status: 500 });
  return Response.json({ ok: true, kind: row.kind });
}

/* as mesmas chaves da função "push" (tabela private.push_vapid, lida pela função mail_vapid) */
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - s.length % 4) % 4)), c => c.charCodeAt(0));
const asJwk = (v: unknown) => { if (v && typeof v === 'object') return v as Record<string, string>; if (typeof v === 'string' && v.trim().startsWith('{')) try { return JSON.parse(v); } catch { /* texto */ } return null; };
async function vapid() {
  let pub: unknown = env('VAPID_PUBLIC_KEY'), priv: unknown = env('VAPID_PRIVATE_KEY');
  if (!pub || !priv) { const { data } = await sb.rpc('mail_vapid'); pub = data?.pub; priv = data?.priv; }
  if (!pub || !priv) return false;
  /* aceita a chave em texto (base64url) ou em JWK */
  const jp = asJwk(pub), jk = asJwk(priv);
  const P = jp && jp.x ? b64u(new Uint8Array([4, ...unb64u(jp.x), ...unb64u(jp.y)])) : jk && jk.x ? b64u(new Uint8Array([4, ...unb64u(jk.x), ...unb64u(jk.y)])) : String(pub);
  const K = jk && jk.d ? jk.d : String(priv);
  webpush.setVapidDetails(env('VAPID_SUBJECT') || 'mailto:contato@criahub.app.br', P, K); return true;
}
/* manda pra todos os aparelhos dela; apaga inscrições que não existem mais */
async function pushTo(uid: string, msg: Record<string, string>, ttl = 6 * 3600) {
  const { data: subs } = await sb.from('push_subs').select('endpoint,sub').eq('user_id', uid); let n = 0; const gone: string[] = [];
  for (const s of subs || []) {
    try { await webpush.sendNotification(s.sub, JSON.stringify(msg), { TTL: ttl, urgency: ttl < 3600 ? 'high' : 'normal' }); n++; }
    catch (e) { const c = (e as { statusCode?: number }).statusCode; if (c === 404 || c === 410) gone.push(s.endpoint); }
  }
  if (gone.length) await sb.from('push_subs').delete().in('endpoint', gone);
  return n;
}

const LABEL: Record<string, string> = { proposta: '💼 Proposta', mei: '🧾 MEI e impostos', pagamento: '💸 Pagamento', outro: '📩 E-mail importante' };
async function lembrar() {
  if (!(await vapid())) return Response.json({ ok: false, why: 'não achei as chaves das notificações (private.push_vapid)' });
  const { data: due, error } = await sb.from('mail_msgs').select('id,user_id,kind,subject,from_name,from_addr')
    .is('seen_at', null).is('reminded_at', null).neq('kind', 'confirma')
    .lt('received_at', new Date(Date.now() - 24 * 3600e3).toISOString()).limit(1000);
  if (error) return new Response(error.message, { status: 500 });
  const byUser = new Map<string, any[]>(); (due || []).forEach(r => byUser.set(r.user_id, [...(byUser.get(r.user_id) || []), r]));
  let sent = 0;
  for (const [uid, list] of byUser) {
    const f = list[0], n = list.length;
    sent += await pushTo(uid, {
      title: n === 1 ? `${LABEL[f.kind] || LABEL.outro}: você ainda não viu` : `${n} e-mails importantes que você ainda não viu`,
      body: n === 1 ? `${f.from_name || f.from_addr}: ${f.subject}` : list.slice(0, 3).map(r => r.subject).join(' · '),
      tag: 'emails', url: '/#emails' });
    await sb.from('mail_msgs').update({ reminded_at: new Date().toISOString() }).in('id', list.map(r => r.id));
  }
  return Response.json({ ok: true, users: byUser.size, sent });
}

/* aniversário: às 9h, quem faz aniversário hoje (dia e mês guardados no perfil) recebe os parabéns no celular */
const BD_MSG = [
  'Hoje o dia é todo seu. Que esse novo ciclo venha com marcas incríveis, saúde, leveza e muitas conquistas. A gente torce por você! 💖',
  'Mais um ano de você criando, aprendendo e crescendo. Celebre cada passo, porque ele é seu. Que venham parcerias lindas e dias leves! ✨',
  'Parabéns pela pessoa e pela creator que você é. Que o seu novo ano tenha tempo pra descansar, sonhar grande e realizar. 🎉',
];
async function aniver() {
  if (!(await vapid())) return Response.json({ ok: false, why: 'não achei as chaves das notificações (private.push_vapid)' });
  const br = new Date(Date.now() - 3 * 3600e3), y = br.getUTCFullYear(), md = br.toISOString().slice(5, 10);
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0, days = md === '02-28' && !leap ? [md, '02-29'] : [md];
  const { data: who, error } = await sb.from('profiles').select('user_id,data->>name').in('data->>bday', days);
  if (error) return new Response(error.message, { status: 500 });
  let sent = 0;
  for (const p of who || []) {
    const name = String((p as any).name || '').trim().split(/\s+/)[0];
    sent += await pushTo((p as any).user_id, { title: `Feliz aniversário${name ? ', ' + name : ''}! 🎂`, body: BD_MSG[y % BD_MSG.length], tag: 'aniver', url: '/#inicio' });
  }
  return Response.json({ ok: true, people: (who || []).length, sent });
}

/* alarme do aquecimento: manda os alarmes vencidos (cada um uma vez só) */
async function aquecer() {
  if (!(await vapid())) return Response.json({ ok: false, why: 'não achei as chaves das notificações (private.push_vapid)' });
  const { data: due, error } = await sb.from('warm_alerts').select('id').is('sent_at', null).lte('send_at', new Date().toISOString()).limit(500);
  if (error) return new Response(error.message, { status: 500 });
  const ids = (due || []).map(r => r.id); let sent = 0, users = 0;
  if (ids.length) {
    /* marca antes de mandar: se o agendador rodar duas vezes, ninguém recebe repetido */
    const { data: mine } = await sb.from('warm_alerts').update({ sent_at: new Date().toISOString() }).in('id', ids).is('sent_at', null).select('user_id,title,body,tag,url');
    for (const a of mine || []) { users++; sent += await pushTo(a.user_id, { title: a.title, body: a.body || '', tag: a.tag || 'aquecer', url: a.url || '/#contas', alarm: '1' }, 900); }
  }
  await sb.from('warm_alerts').delete().lt('created_at', new Date(Date.now() - 2 * 864e5).toISOString());
  return Response.json({ ok: true, alarms: users, sent });
}

Deno.serve(async req => {
  if (req.method !== 'POST') return new Response('ok');
  const url = new URL(req.url);
  if (url.searchParams.has('t')) return inbound(req, url);
  let b: Record<string, any> = {}; try { b = await req.json(); } catch { /* vazio */ }
  if (b.action === 'lembrar' && await keyOk('cron', b.key)) return lembrar();
  if (b.action === 'aniver' && await keyOk('cron', b.key)) return aniver();
  if (b.action === 'aquecer' && await keyOk('cron', b.key)) return aquecer();
  return new Response('forbidden', { status: 403 });
});
