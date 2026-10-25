-- CriaHub · aviso da retrospectiva (sem função nova: usa a ação "send" da função push)
-- Todo dia às 19h de Brasília (22h UTC) o banco confere a data e, só quando for o dia certo,
-- pede à função push para avisar todas as creators:
--   • último dia de cada mês → "Sua retrospectiva de <mês> chegou ✨" (abre a do mês)
--   • 1º de dezembro        → "Sua retrospectiva de <ano> chegou 🎉" (abre a do ano)
-- Antes de rodar: troque COLE_AQUI_A_CHAVE_DO_RADAR pela mesma chave que o agendamento do Radar usa.
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule('retrospectiva-criahub') where exists (select 1 from cron.job where jobname = 'retrospectiva-criahub');
select cron.schedule('retrospectiva-criahub', '0 22 * * *', $cron$
  with d as (select (now() at time zone 'America/Sao_Paulo')::date as hoje),
  m as (
    select case
      when extract(month from hoje) = 12 and extract(day from hoje) = 1 then jsonb_build_object(
        'title', 'Sua retrospectiva de ' || extract(year from hoje)::int || ' chegou 🎉',
        'body', 'Veja tudo o que você construiu no ano: marcas, entregas e conquistas.',
        'url', '/#anodecria', 'tag', 'anodecria')
      when extract(day from hoje + 1) = 1 then jsonb_build_object(
        'title', 'Sua retrospectiva de ' || (array['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro'])[extract(month from hoje)::int] || ' chegou ✨',
        'body', 'Veja o que você construiu neste mês. Toque pra abrir.',
        'url', '/#mesdecria', 'tag', 'mesdecria')
    end as msg from d
  )
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F',
      'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
    body := msg || jsonb_build_object('action', 'send', 'key', 'COLE_AQUI_A_CHAVE_DO_RADAR')
  ) from m where msg is not null;
$cron$);
