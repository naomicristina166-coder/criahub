-- =============== MOMENTOS NO AUTOMÁTICO ===============
-- Todo dia às 10h (Brasília) o app manda sozinho o recado de cada momento
-- (e-mail pelo Gmail do CriaHub + notificação no celular dela).
-- Só marca como feito quando o e-mail sai. O que não sair continua em Momentos, pra você ver.
-- Rode tudo de uma vez no SQL Editor.

alter table public.moments_done drop constraint if exists moments_done_how_check;
alter table public.moments_done add constraint moments_done_how_check check (how in ('enviado', 'pulado', 'auto'));

create or replace function private.moments_feed()
returns table (user_id uuid, name text, email text, whatsapp text, instagram text, kind text, ref text, happened date, detail text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  return query
  with ev as (
    -- 1ª marca cadastrada
    select i.user_id, 'primeira_marca'::text kind, ''::text ref, min(private.dt(i.data->>'created', i.updated_at)) happened, count(*)::text detail
      from public.items i where i.col = 'brands' and coalesce(i.data->>'example', '') <> 'true' group by i.user_id
    union all
    -- 1º vídeo no ar
    select i.user_id, 'primeiro_video', '', min((i.updated_at at time zone 'America/Sao_Paulo')::date), count(*)::text
      from public.items i where i.col = 'deliveries' and i.data->>'stage' = '5' and coalesce(i.data->>'example', '') <> 'true' group by i.user_id
    union all
    -- 1º pagamento recebido de marca
    select i.user_id, 'primeiro_pagamento', '', min(private.dt(i.data->>'paidAt', i.updated_at)), count(*)::text
      from public.items i where i.col = 'payments' and i.data->>'paid' = 'true' and coalesce(i.data->>'example', '') <> 'true' group by i.user_id
    union all
    -- 30 dias de CriaHub
    select u.id, '30_dias', '', (u.created_at at time zone 'America/Sao_Paulo')::date + 30, null
      from auth.users u
    union all
    -- aniversário (dia e mês, nos próximos 7 dias)
    select p.user_id, 'aniversario', extract(year from private.next_bday(p.data->>'bday', hoje))::text, private.next_bday(p.data->>'bday', hoje), null
      from public.profiles p where private.next_bday(p.data->>'bday', hoje) is not null
    union all
    -- virou Pro
    select pl.user_id, 'virou_pro', to_char(pl.since, 'YYYY-MM-DD'), (pl.since at time zone 'America/Sao_Paulo')::date, pl.note
      from public.plans pl where pl.plan = 'pro' and pl.since is not null
    union all
    -- sumiu há 7+ dias (usou pelo menos 3 dias antes)
    select x.user_id, 'sumida', max(x.day)::text, max(x.day) + 7, count(distinct x.day)::text
      from public.usage_days x group by x.user_id having count(distinct x.day) >= 3
  )
  select ev.user_id,
    coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', w.name, split_part(u.email, '@', 1))::text,
    u.email::text, coalesce(nullif(pr.data->>'wa', ''), nullif(u.raw_user_meta_data->>'whatsapp', ''), w.whatsapp)::text,
    coalesce(nullif(pr.data->>'ig', ''), nullif(ltrim(pr.data#>>'{kit,ig}', '@'), ''), nullif(ltrim(w.instagram, '@'), ''))::text,
    ev.kind, ev.ref, ev.happened, ev.detail
  from ev
  join auth.users u on u.id = ev.user_id
  left join public.profiles pr on pr.user_id = ev.user_id
  left join lateral (select * from public.waitlist w0 where lower(w0.email) = lower(u.email) limit 1) w on true
  where not exists (select 1 from private.admins a where a.user_id = ev.user_id)
    and not exists (select 1 from public.moments_done d where d.user_id = ev.user_id and d.kind = ev.kind and d.ref = ev.ref)
    and case when ev.kind = 'aniversario' then ev.happened between hoje and hoje + 7
             when ev.kind = 'sumida' then ev.happened <= hoje and ev.happened > hoje - 14
             else ev.happened between hoje - 14 and hoje end
  order by case when ev.kind = 'aniversario' then 0 else 1 end, ev.happened desc;
end $$;

create or replace function public.admin_moments()
returns table (user_id uuid, name text, email text, whatsapp text, instagram text, kind text, ref text, happened date, detail text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform private.must_admin();
  return query select * from private.moments_feed();
end $$;

-- o que o robô manda hoje: tudo, menos aniversário que ainda não chegou (esse sai no dia)
create or replace function public.moments_auto()
returns table (user_id uuid, name text, email text, whatsapp text, instagram text, kind text, ref text, happened date, detail text)
language sql stable security definer set search_path = ''
as $$
  select * from private.moments_feed() f
  where f.kind <> 'aniversario' or f.happened = (now() at time zone 'America/Sao_Paulo')::date
$$;
revoke all on function public.moments_auto() from public, anon, authenticated;
grant execute on function public.moments_auto() to service_role;

create or replace function public.moments_auto_done(p_user uuid, p_kind text, p_ref text)
returns void language sql security definer set search_path = ''
as $$
  insert into public.moments_done (user_id, kind, ref, how) values (p_user, p_kind, coalesce(p_ref, ''), 'auto')
  on conflict (user_id, kind, ref) do nothing
$$;
revoke all on function public.moments_auto_done(uuid, text, text) from public, anon, authenticated;
grant execute on function public.moments_auto_done(uuid, text, text) to service_role;

-- números do painel: os seus recados e os que saíram sozinhos
create or replace function public.admin_moments_stats()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  return jsonb_build_object(
    'sent30', (select count(*) from public.moments_done where how = 'enviado' and done_at > now() - interval '30 days'),
    'sentAll', (select count(*) from public.moments_done where how = 'enviado'),
    'auto30', (select count(*) from public.moments_done where how = 'auto' and done_at > now() - interval '30 days'),
    'recent', coalesce((select jsonb_agg(r) from (
       select coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', split_part(u.email, '@', 1)) as name,
              d.kind, d.done_at
       from public.moments_done d join auth.users u on u.id = d.user_id
       left join public.profiles pr on pr.user_id = d.user_id
       where d.how = 'auto' order by d.done_at desc limit 12) r), '[]'::jsonb));
end $$;

-- o agendador: todo dia 10h07 de Brasília (13h07 UTC)
select cron.unschedule('momentos-criahub') where exists (select 1 from cron.job where jobname = 'momentos-criahub');
select cron.schedule('momentos-criahub', '7 13 * * *', $cron$
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
    body := jsonb_build_object('action', 'momentos', 'key', (select cron from private.mail_key where id = 1)),
    timeout_milliseconds := 60000);
$cron$);
