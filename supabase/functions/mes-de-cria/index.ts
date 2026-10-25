/* CriaHub · aviso da retrospectiva do mês (último dia de cada mês) e do ano (1º de dezembro)
   Manda a notificação para todas as inscrições de push_subs. Não usa IA e não lê dados das creators:
   a retrospectiva é calculada no próprio app quando ela abre.

   Como ligar (uma vez só):
   1. Secrets da função (Supabase › Edge Functions › Secrets), as mesmas chaves VAPID da função "push":
        VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (ex.: mailto:contato@criahub.app.br)
        CRON_SECRET = uma senha longa qualquer
   2. supabase functions deploy mes-de-cria --no-verify-jwt
   3. Rode supabase/mes-de-cria.sql no SQL Editor (troque o segredo pelo CRON_SECRET).
   A função é chamada todo dia e decide sozinha se é dia de avisar. */
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];

Deno.serve(async req => {
  const secret = Deno.env.get('CRON_SECRET');
  if (!secret || req.headers.get('x-cron-secret') !== secret) return new Response('forbidden', { status: 403 });
  webpush.setVapidDetails(Deno.env.get('VAPID_SUBJECT') ?? 'mailto:contato@criahub.app.br', Deno.env.get('VAPID_PUBLIC_KEY')!, Deno.env.get('VAPID_PRIVATE_KEY')!);
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  /* roda todo dia às 19h de Brasília e só avisa no último dia do mês (retrospectiva do mês)
     e em 1º de dezembro (retrospectiva do ano) */
  const br = new Date(Date.now() - 3 * 3600e3), amanha = new Date(br.getTime() + 864e5);
  const ultimoDia = amanha.getUTCDate() === 1, dezembro1 = br.getUTCMonth() === 11 && br.getUTCDate() === 1;
  if (!ultimoDia && !dezembro1) return Response.json({ skipped: true });
  const mes = MESES[br.getUTCMonth()], ano = br.getUTCFullYear();
  const payload = JSON.stringify(dezembro1
    ? { title: `Sua retrospectiva de ${ano} chegou 🎉`, body: 'Veja tudo o que você construiu no ano: marcas, entregas e conquistas.', tag: 'anodecria', url: '/#anodecria' }
    : { title: `Sua retrospectiva de ${mes} chegou ✨`, body: 'Veja o que você construiu neste mês. Toque pra abrir.', tag: 'mesdecria', url: '/#mesdecria' });

  const subs: { endpoint: string; sub: webpush.PushSubscription }[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb.from('push_subs').select('endpoint,sub').range(from, from + 999);
    if (error) return new Response(error.message, { status: 500 });
    subs.push(...data); if (data.length < 1000) break;
  }
  let sent = 0; const gone: string[] = [];
  for (let i = 0; i < subs.length; i += 50) {
    await Promise.all(subs.slice(i, i + 50).map(async r => {
      try { await webpush.sendNotification(r.sub, payload, { TTL: 86400 }); sent++; }
      catch (e) { const c = (e as { statusCode?: number }).statusCode; if (c === 404 || c === 410) gone.push(r.endpoint); }
    }));
  }
  if (gone.length) await sb.from('push_subs').delete().in('endpoint', gone);
  return Response.json({ mes, sent, removed: gone.length });
});
