-- =============== LEMBRETE DAS TAREFAS ===============
-- 07h07 (Brasília): resumo das tarefas do dia no celular de cada creator com as notificações ligadas.
-- A cada 5 min: aviso 30 min antes das tarefas com horário.
-- Cada creator liga ou desliga em Ajustes › Avisos. Rode tudo de uma vez no SQL Editor.

select cron.unschedule('tarefas-manha') where exists (select 1 from cron.job where jobname = 'tarefas-manha');
select cron.schedule('tarefas-manha', '7 10 * * *', $cron$
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
    body := jsonb_build_object('action', 'tarefas', 'modo', 'manha', 'key', (select cron from private.mail_key where id = 1)),
    timeout_milliseconds := 60000);
$cron$);

select cron.unschedule('tarefas-hora') where exists (select 1 from cron.job where jobname = 'tarefas-hora');
select cron.schedule('tarefas-hora', '*/5 * * * *', $cron$
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
    body := jsonb_build_object('action', 'tarefas', 'modo', 'hora', 'key', (select cron from private.mail_key where id = 1)),
    timeout_milliseconds := 30000);
$cron$);
