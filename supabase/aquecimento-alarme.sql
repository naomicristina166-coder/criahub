-- CriaHub · alarme do aquecimento (aviso no celular quando o cronômetro acaba, mesmo com o app fechado)
-- Precisa de: emails.sql já rodado (usa a mesma chave do agendador) e a função "caixa" atualizada.
-- Rode no SQL Editor do Supabase (pode rodar de novo: nada é duplicado).
--   • quando a creator começa o cronômetro, o app agenda um alarme aqui (só dela, no máximo 3 horas pra frente)
--   • a cada minuto o banco vê se tem alarme vencido e pede pra função "caixa" mandar a notificação
--   • se ela concluir ou cancelar antes, o app apaga o alarme
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- chave do agendador e funções que a "caixa" usa (as mesmas do emails.sql; aqui pra o alarme funcionar
-- mesmo sem o e-mail configurado)
create schema if not exists private;
create table if not exists private.mail_key (id int primary key default 1, hook text not null, cron text not null);
alter table private.mail_key enable row level security;
revoke all on private.mail_key from anon, authenticated;
insert into private.mail_key (id, hook, cron)
  values (1, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
             replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
  on conflict (id) do nothing;
create or replace function public.mail_key_ok(p_kind text, p_val text) returns boolean
  language sql security definer set search_path = private as $$
  select coalesce((select case p_kind when 'hook' then hook when 'cron' then cron end from private.mail_key where id = 1) = p_val, false)
$$;
revoke all on function public.mail_key_ok(text, text) from public, anon, authenticated;
grant execute on function public.mail_key_ok(text, text) to service_role;
create or replace function public.mail_vapid() returns jsonb
  language sql security definer set search_path = private as $$
  select jsonb_build_object('pub', to_jsonb(pub), 'priv', to_jsonb(priv)) from private.push_vapid order by id desc limit 1
$$;
revoke all on function public.mail_vapid() from public, anon, authenticated;
grant execute on function public.mail_vapid() to service_role;

create table if not exists public.warm_alerts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  send_at    timestamptz not null,
  title      text not null check (char_length(title) <= 120),
  body       text check (char_length(body) <= 240),
  tag        text check (char_length(tag) <= 60),
  url        text check (char_length(url) <= 60),
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index if not exists warm_alerts_due on public.warm_alerts (send_at) where sent_at is null;
alter table public.warm_alerts enable row level security;
revoke all on public.warm_alerts from anon;
grant select, insert, delete on public.warm_alerts to authenticated;

drop policy if exists "warm_alerts: ver os meus" on public.warm_alerts;
create policy "warm_alerts: ver os meus" on public.warm_alerts for select to authenticated using (user_id = auth.uid());
drop policy if exists "warm_alerts: criar os meus" on public.warm_alerts;
create policy "warm_alerts: criar os meus" on public.warm_alerts for insert to authenticated
  with check (user_id = auth.uid() and sent_at is null
    and send_at > now() - interval '1 minute' and send_at < now() + interval '3 hours'
    and (select count(*) from public.warm_alerts w where w.user_id = auth.uid() and w.sent_at is null) < 10);
drop policy if exists "warm_alerts: apagar os meus" on public.warm_alerts;
create policy "warm_alerts: apagar os meus" on public.warm_alerts for delete to authenticated using (user_id = auth.uid());

-- a cada minuto: só chama a função se tiver alarme vencido
select cron.unschedule('aquecimento-criahub') where exists (select 1 from cron.job where jobname = 'aquecimento-criahub');
select cron.schedule('aquecimento-criahub', '* * * * *', $cron$
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
    body := jsonb_build_object('action', 'aquecer', 'key', (select cron from private.mail_key where id = 1)))
  where exists (select 1 from public.warm_alerts where sent_at is null and send_at <= now());
$cron$);

-- alarmes antigos que ficaram presos: não manda mais (seria uma enxurrada de avisos velhos)
update public.warm_alerts set sent_at = now() where sent_at is null and send_at < now() - interval '10 minutes';

select jobname, schedule from cron.job where jobname = 'aquecimento-criahub';
