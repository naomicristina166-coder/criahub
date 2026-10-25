-- CriaHub · chama a função todo dia às 19h de Brasília (22h UTC). Ela só avisa no último dia
-- do mês (retrospectiva do mês) e em 1º de dezembro (retrospectiva do ano).
-- Rode no SQL Editor do Supabase depois de publicar a função mes-de-cria.
-- Troque TROQUE_PELO_CRON_SECRET pelo mesmo valor do secret CRON_SECRET da função.
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule('mes-de-cria') where exists (select 1 from cron.job where jobname = 'mes-de-cria');
select cron.schedule('mes-de-cria', '0 22 * * *', $$
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/mes-de-cria',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', 'TROQUE_PELO_CRON_SECRET'),
    body := '{}'::jsonb
  );
$$);
