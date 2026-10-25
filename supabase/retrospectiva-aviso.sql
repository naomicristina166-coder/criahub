-- CriaHub · aviso da retrospectiva (usa a ação "send" da função push que já existe)
-- Rode uma vez no SQL Editor. Ninguém precisa ver nem copiar chave:
--   1. liga o agendador (pg_cron) e as chamadas HTTP do banco (pg_net)
--   2. o banco sorteia uma chave própria da retrospectiva e guarda no schema private
--   3. radar_key_ok passa a aceitar a chave do Radar (id 1) e essa nova (id 2)
--   4. todo dia às 19h de Brasília o banco confere a data e, só no dia certo, avisa todas as creators:
--        • último dia de cada mês → "Sua retrospectiva de <mês> chegou ✨" (abre a do mês)
--        • 1º de dezembro        → "Sua retrospectiva de <ano> chegou 🎉" (abre a do ano)
create extension if not exists pg_cron;
create extension if not exists pg_net;

create table if not exists private.retro_key (id int primary key default 1, key text not null);
revoke all on private.retro_key from anon, authenticated;
insert into private.retro_key (id, key)
  values (1, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
  on conflict (id) do nothing;
insert into private.radar_key (id, key_hash)
  select 2, encode(sha256(convert_to(key, 'UTF8')), 'hex') from private.retro_key where id = 1
  on conflict (id) do update set key_hash = excluded.key_hash;

create or replace function public.radar_key_ok(p_key text) returns boolean
  language sql security definer set search_path to 'private' as $function$
  select coalesce(encode(sha256(convert_to(p_key, 'UTF8')), 'hex') in (select key_hash from private.radar_key where key_hash is not null), false)
$function$;

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
    body := msg || jsonb_build_object('action', 'send', 'key', (select key from private.retro_key where id = 1))
  ) from m where msg is not null;
$cron$);

select jobname, schedule from cron.job where jobname = 'retrospectiva-criahub';
