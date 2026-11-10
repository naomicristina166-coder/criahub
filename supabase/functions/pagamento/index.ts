/* CriaHub · função "pagamento": assinatura do Pro pelo Asaas
   • POST {action:'setup'} com o login da fundadora → cria (ou atualiza) os 4 links de pagamento no Asaas
     e guarda em public.pay_links. Preços em PRICES, logo abaixo.
   • POST do webhook do Asaas (eventos de cobrança) → a função confere o pagamento direto na API do Asaas
     (não confia no que chegou), descobre o e-mail da cliente e chama pay_grant: a conta com esse e-mail vira
     Pro (1 mês no mensal, 12 meses no anual). Assim o webhook não precisa de senha.

   Como ligar (uma vez só), no painel do Supabase:
   1. Rode supabase/pagamento.sql no SQL Editor
   2. Edge Functions › Secrets › ASAAS_API_KEY (a chave de produção do Asaas)
   3. Edge Functions › Deploy a new function › Via Editor › nome: pagamento › cole este arquivo › Deploy
   4. Na função pagamento › Details: desligue "Verify JWT with legacy secret" (o Asaas não manda login) › Save
   5. No Asaas › Integrações › Webhooks › Criar: URL = <SUPABASE_URL>/functions/v1/pagamento,
      eventos de cobrança (PAYMENT_CONFIRMED e PAYMENT_RECEIVED), fila sincronizada ligada.
   6. No app, como fundadora: tela do Pro › "Criar links no Asaas". */
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const KEY = Deno.env.get('ASAAS_API_KEY') || '';
const API = KEY.includes('_hmlg_') ? 'https://api-sandbox.asaas.com/v3' : 'https://api.asaas.com/v3';
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const PRICES: Record<string, { name: string; value: number; months: number; note: string; annual: boolean }> = {
  fund_mensal: { name: 'CriaHub Pro · Cria Fundadora (mensal)', value: 24.90, months: 1, note: 'Cria Fundadora · mensal', annual: false },
  fund_anual: { name: 'CriaHub Pro · Cria Fundadora (anual)', value: 199.00, months: 12, note: 'Cria Fundadora · anual', annual: true },
  pro_mensal: { name: 'CriaHub Pro (mensal)', value: 29.90, months: 1, note: 'Pro mensal', annual: false },
  pro_anual: { name: 'CriaHub Pro (anual)', value: 239.00, months: 12, note: 'Pro anual', annual: true },
};
// versões só Pix: mensal (assinatura no Pix) e anual à vista no Pix
for (const k of Object.keys(PRICES)) PRICES[k + '_pix'] = { ...PRICES[k], name: PRICES[k].name.replace(')', ' · Pix)'), note: PRICES[k].note + ' · Pix' };

async function asaas(path: string, init: RequestInit = {}) {
  const r = await fetch(API + path, { ...init, headers: { access_token: KEY, 'Content-Type': 'application/json', 'User-Agent': 'CriaHub', ...(init.headers || {}) } });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`Asaas ${r.status}: ${JSON.stringify(body).slice(0, 300)}`);
  return body;
}

async function setup(req: Request) {
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: u } = await sb.auth.getUser(token);
  if (!u?.user) return json({ error: 'entre na sua conta' }, 401);
  const { data: isAdm } = await createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: 'Bearer ' + token } } }).rpc('is_admin');
  if (isAdm !== true) return json({ error: 'só a fundadora' }, 403);
  if (!KEY) return json({ error: 'falta o segredo ASAAS_API_KEY no Supabase' }, 400);
  const { data: have } = await sb.from('pay_links').select('key,asaas_id');
  const old = new Map((have || []).map((x: any) => [x.key, x.asaas_id]));
  const out: Record<string, string> = {};
  for (const [key, p] of Object.entries(PRICES)) {
    const base = { name: p.name, description: 'Assinatura do CriaHub Pro. Use o mesmo e-mail da sua conta do CriaHub.', value: p.value, dueDateLimitDays: 3, notificationEnabled: true, externalReference: key };
    const pix = key.endsWith('_pix');
    const tries = pix
      ? (p.annual ? [{ ...base, billingType: 'PIX', chargeType: 'DETACHED' }] : [{ ...base, billingType: 'PIX', chargeType: 'RECURRENT', subscriptionCycle: 'MONTHLY' }, { ...base, billingType: 'PIX', chargeType: 'DETACHED', description: 'CriaHub Pro por 1 mês, no Pix. Use o mesmo e-mail da sua conta do CriaHub.' }])
      : p.annual
      ? [{ ...base, billingType: 'UNDEFINED', chargeType: 'INSTALLMENT', maxInstallmentCount: 12 }, { ...base, billingType: 'CREDIT_CARD', chargeType: 'INSTALLMENT', maxInstallmentCount: 12 }]
      : [{ ...base, billingType: 'UNDEFINED', chargeType: 'RECURRENT', subscriptionCycle: 'MONTHLY' }, { ...base, billingType: 'CREDIT_CARD', chargeType: 'RECURRENT', subscriptionCycle: 'MONTHLY' }];
    let link: any = null, err = '';
    for (const body of tries) {
      try {
        link = old.get(key) ? await asaas('/paymentLinks/' + old.get(key), { method: 'PUT', body: JSON.stringify(body) }) : await asaas('/paymentLinks', { method: 'POST', body: JSON.stringify(body) });
        break;
      } catch (e) { err = String(e); }
    }
    if (!link && pix) { console.warn('pix', key, err); continue; }   // Pix é extra: se o Asaas recusar, segue sem ele
    if (!link) return json({ error: `não consegui criar ${key}: ${err}` }, 502);
    await sb.from('pay_links').upsert({ key, asaas_id: link.id, url: link.url, value: p.value, updated_at: new Date().toISOString() });
    out[key] = link.url;
  }
  return json({ ok: true, links: out });
}

async function webhook(evt: any) {
  const type = String(evt?.event || '');
  if (!/^PAYMENT_(CONFIRMED|RECEIVED)$/.test(type) || !evt?.payment?.id) return json({ ok: true, ignored: type });
  const pay = await asaas('/payments/' + encodeURIComponent(evt.payment.id));           // confere na fonte
  if (!['CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH'].includes(pay.status)) return json({ ok: true, status: pay.status });
  const { data: links } = await sb.from('pay_links').select('key,asaas_id,value');
  let key = (links || []).find((l: any) => l.asaas_id && l.asaas_id === pay.paymentLink)?.key || '';
  if (!key && pay.subscription) {   // cobranças seguintes da assinatura mensal
    const sub = await asaas('/subscriptions/' + encodeURIComponent(pay.subscription)).catch(() => null);
    key = (links || []).find((l: any) => sub && l.asaas_id === sub.paymentLink)?.key || (sub?.externalReference in PRICES ? sub.externalReference : '');
  }
  if (!key && pay.externalReference in PRICES) key = pay.externalReference;
  if (!key) key = Number(pay.value) >= 150 ? (Number(pay.value) < 220 ? 'fund_anual' : 'pro_anual') : (Number(pay.value) < 27 ? 'fund_mensal' : 'pro_mensal');
  const p = PRICES[key];
  // anual parcelado: no cartão, a 1ª parcela confirmada já garante os 12 meses (as outras não somam);
  // no boleto (cada parcela é um boleto), cada parcela paga libera 1 mês, pra ninguém pagar 1 e levar 12.
  const card = pay.billingType === 'CREDIT_CARD';
  const months = p.annual && pay.installment && !card ? 1 : p.months;
  const ref = p.annual && pay.installment && card ? 'parc:' + pay.installment : pay.id;
  const cust = await asaas('/customers/' + encodeURIComponent(pay.customer));
  const email = String(cust.email || '').trim();
  if (!email) return json({ ok: false, error: 'cliente sem e-mail' });
  const { data, error } = await sb.rpc('pay_grant', { p_email: email, p_months: months, p_note: p.note, p_payment: ref, p_link: key, p_value: Number(pay.value) });
  if (error) throw error;
  // comissão da afiliada (cada cobrança paga conta uma vez; parcelas do anual contam cada uma)
  const { data: com } = await sb.rpc('aff_commission', { p_email: email, p_payment: pay.id, p_value: Number(pay.value) });
  return json({ ok: true, key, result: data, commission: com });
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'use POST' }, 405);
  let body: any; try { body = await req.json(); } catch { return json({ error: 'json inválido' }, 400); }
  try {
    if (body?.action === 'setup') return await setup(req);
    if (body?.event) return await webhook(body);
    return json({ error: 'ação desconhecida' }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: String(e).slice(0, 300) }, 500);
  }
});
