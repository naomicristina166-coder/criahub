-- CriaHub · Painel da fundadora (criahub.app.br/admin)
-- Rode uma vez no SQL Editor do Supabase (pode rodar de novo: nada é duplicado).
--   • só quem está em private.admins consegue ver o painel. Para as outras creators, ele não existe
--   • plano de cada creator (Grátis ou Pro): só a admin muda; cada creator só enxerga o próprio
--   • uso do app: o app soma quantos segundos cada creator passa em cada tela, por dia.
--     Guarda só tempo e nome da tela, nunca o que ela escreveu
--   • o painel mostra QUANTAS marcas, entregas, ideias… cada uma tem, sem abrir o conteúdo
--   • feedback: as creators mandam mensagem pelo app (Ajustes › Fale com o CriaHub) e você responde no painel
--   • erros do app: o app avisa sozinho quando dá erro (só a mensagem técnica)
--   • finanças: você registra cada pagamento e o painel calcula receita do mês, recorrente e vencimentos
-- 👉 Se o painel disser "acesso só da fundadora", troque os e-mails da linha marcada pelo
--    e-mail que você usa pra entrar no CriaHub e rode de novo.

create schema if not exists private;

-- ---------- quem é admin ----------
create table if not exists private.admins (
  user_id    uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
alter table private.admins enable row level security;
revoke all on private.admins from anon, authenticated;

-- a lista abaixo manda: quem estiver nela vira admin, quem não estiver deixa de ser
insert into private.admins (user_id)
select id from auth.users
where lower(email) in ('naomicristinacontato@gmail.com', 'criahubb@gmail.com')   -- 👉 seus e-mails de login
on conflict (user_id) do nothing;
delete from private.admins a using auth.users u
where u.id = a.user_id and lower(u.email) not in ('naomicristinacontato@gmail.com', 'criahubb@gmail.com');

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from private.admins where user_id = auth.uid()) $$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ---------- plano de cada creator ----------
create table if not exists public.plans (
  user_id    uuid primary key references auth.users on delete cascade,
  plan       text not null default 'free' check (plan in ('free', 'pro')),
  since      timestamptz not null default now(),
  note       text check (char_length(note) <= 200),
  updated_at timestamptz not null default now()
);
alter table public.plans add column if not exists until date;
alter table public.plans enable row level security;
drop policy if exists "plans: cada uma vê o seu" on public.plans;
create policy "plans: cada uma vê o seu" on public.plans
  for select to authenticated using (user_id = auth.uid());
-- (sem permissão de gravar: só a função admin_set_plan muda o plano)

-- ---------- tempo de uso por tela ----------
create table if not exists public.usage_days (
  user_id uuid not null references auth.users on delete cascade,
  day     date not null,
  screen  text not null check (screen ~ '^[a-z._]{1,40}$'),
  secs    int  not null default 0,
  opens   int  not null default 0,
  primary key (user_id, day, screen)
);
alter table public.usage_days enable row level security;
revoke all on public.usage_days from anon, authenticated;

-- o app chama a cada minuto: p_secs = {"inicio": 42, "estudio.ideias": 18}
create or replace function public.track_usage(p_secs jsonb, p_open boolean default false)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  u uuid := auth.uid();
  d date := (now() at time zone 'America/Sao_Paulo')::date;
  k text; v text; n int := 0;
begin
  if u is null then return; end if;
  if p_open then
    insert into public.usage_days (user_id, day, screen, opens) values (u, d, '_app', 1)
    on conflict (user_id, day, screen) do update set opens = least(public.usage_days.opens + 1, 500);
  end if;
  if p_secs is null or jsonb_typeof(p_secs) <> 'object' then return; end if;
  for k, v in select * from jsonb_each_text(p_secs) loop
    n := n + 1; exit when n > 30;
    continue when k !~ '^[a-z._]{1,40}$' or v !~ '^\d{1,6}$';
    insert into public.usage_days (user_id, day, screen, secs) values (u, d, k, least(v::int, 900))
    on conflict (user_id, day, screen) do update set secs = least(public.usage_days.secs + excluded.secs, 86400);
  end loop;
end $$;
revoke all on function public.track_usage(jsonb, boolean) from public, anon;
grant execute on function public.track_usage(jsonb, boolean) to authenticated;

-- ---------- feedback das creators ----------
create table if not exists public.feedback (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id    uuid not null references auth.users on delete cascade,
  kind       text not null default 'ideia' check (kind in ('erro', 'ideia', 'duvida', 'elogio')),
  message    text not null check (char_length(message) between 1 and 2000),
  screen     text check (char_length(screen) <= 40),
  ua         text check (char_length(ua) <= 200),
  status     text not null default 'novo' check (status in ('novo', 'vendo', 'resolvido')),
  reply      text check (char_length(reply) <= 2000),
  replied_at timestamptz
);
alter table public.feedback enable row level security;
drop policy if exists "feedback: manda a sua" on public.feedback;
create policy "feedback: manda a sua" on public.feedback for insert to authenticated
  with check (user_id = auth.uid() and status = 'novo' and reply is null);
drop policy if exists "feedback: vê as suas" on public.feedback;
create policy "feedback: vê as suas" on public.feedback for select to authenticated using (user_id = auth.uid());
create index if not exists feedback_user on public.feedback (user_id, created_at desc);

-- ---------- erros do app ----------
create table if not exists public.app_errors (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id    uuid references auth.users on delete set null,
  msg        text not null,
  src        text,
  screen     text,
  ua         text
);
alter table public.app_errors enable row level security;
revoke all on public.app_errors from anon, authenticated;

create or replace function public.log_error(p_msg text, p_src text default null, p_screen text default null, p_ua text default null)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  if auth.uid() is null or coalesce(p_msg, '') = '' then return; end if;
  if (select count(*) from public.app_errors where user_id = auth.uid() and created_at > now() - interval '1 day') >= 30 then return; end if;
  insert into public.app_errors (user_id, msg, src, screen, ua)
  values (auth.uid(), left(p_msg, 300), left(p_src, 200), left(p_screen, 40), left(p_ua, 200));
end $$;
revoke all on function public.log_error(text, text, text, text) from public, anon;
grant execute on function public.log_error(text, text, text, text) to authenticated;

-- ---------- finanças do CriaHub (cada pagamento de creator) ----------
create table if not exists public.revenue (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id    uuid references auth.users on delete set null,
  payer      text check (char_length(payer) <= 120),
  amount     numeric(10,2) not null check (amount >= 0),
  paid_at    date not null,
  method     text not null default 'pix' check (method in ('pix', 'cartao', 'google_play', 'app_store', 'boleto', 'outro')),
  period     text not null default 'mensal' check (period in ('mensal', 'anual', 'avulso')),
  note       text check (char_length(note) <= 200)
);
alter table public.revenue enable row level security;
revoke all on public.revenue from anon, authenticated;

-- ---------- funções do painel (todas conferem se quem chama é admin) ----------
create or replace function private.must_admin()
returns void language plpgsql stable security definer set search_path = ''
as $$ begin
  if not exists (select 1 from private.admins where user_id = auth.uid()) then
    raise exception 'acesso só da fundadora' using errcode = '42501';
  end if;
end $$;

-- números do topo (sem contar as contas de admin)
create or replace function public.admin_overview()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r jsonb;
begin
  perform private.must_admin();
  with us as (select * from auth.users where id not in (select user_id from private.admins)),
       ud as (select * from public.usage_days where user_id not in (select user_id from private.admins)),
       d30 as (select user_id, day, sum(secs) s from ud where day > hoje - 30 group by 1, 2)
  select jsonb_build_object(
    'users',        (select count(*) from us),
    'new7',         (select count(*) from us where created_at > now() - interval '7 days'),
    'new30',        (select count(*) from us where created_at > now() - interval '30 days'),
    'activeToday',  (select count(distinct user_id) from ud where day = hoje),
    'active7',      (select count(distinct user_id) from ud where day > hoje - 7),
    'active30',     (select count(distinct user_id) from ud where day > hoje - 30),
    'pro',          (select count(*) from public.plans p join us on us.id = p.user_id where p.plan = 'pro'),
    'waitlist',     (select count(*) from public.waitlist),
    'waitlist7',    (select count(*) from public.waitlist where created_at > now() - interval '7 days'),
    'secs30',       (select coalesce(sum(s), 0) from d30),
    'avgDaySecs',   (select coalesce(round(avg(s)), 0) from d30 where s > 0),
    'feedbackNew',  (select count(*) from public.feedback where status = 'novo'),
    'errors7',      (select count(*) from public.app_errors where created_at > now() - interval '7 days'),
    'monthRevenue', (select coalesce(sum(amount), 0) from public.revenue where date_trunc('month', paid_at) = date_trunc('month', hoje)),
    'expiring',     (select count(*) from public.plans p join us on us.id = p.user_id where p.plan = 'pro' and p.until is not null and p.until <= hoje + 7)
  ) into r;
  return r;
end $$;

-- um dia por linha: cadastros, creators ativas, minutos e lista de espera
create or replace function public.admin_daily(p_days int default 30)
returns table (day date, signups int, active int, mins int, waitlist int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform private.must_admin();
  return query
  select g.d,
    (select count(*)::int from auth.users u where (u.created_at at time zone 'America/Sao_Paulo')::date = g.d
       and u.id not in (select user_id from private.admins)),
    (select count(distinct x.user_id)::int from public.usage_days x where x.day = g.d
       and x.user_id not in (select user_id from private.admins)),
    (select (coalesce(sum(x.secs), 0) / 60)::int from public.usage_days x where x.day = g.d
       and x.user_id not in (select user_id from private.admins)),
    (select count(*)::int from public.waitlist w where (w.created_at at time zone 'America/Sao_Paulo')::date = g.d)
  from (select (hoje - i) as d from generate_series(0, least(greatest(p_days, 7), 120) - 1) i) g
  order by 1;
end $$;

-- telas mais e menos usadas
create or replace function public.admin_screens(p_days int default 30)
returns table (screen text, mins int, users int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform private.must_admin();
  return query
  select x.screen, (sum(x.secs) / 60)::int, count(distinct x.user_id)::int
  from public.usage_days x
  where x.day > hoje - least(greatest(p_days, 1), 365) and x.screen <> '_app'
    and x.user_id not in (select user_id from private.admins)
  group by x.screen order by 2 desc;
end $$;

-- todas as creators cadastradas
drop function if exists public.admin_users();
create or replace function public.admin_users()
returns table (
  user_id uuid, email text, name text, instagram text, whatsapp text, kinds jsonb, from_waitlist boolean,
  created_at timestamptz, last_sign_in_at timestamptz, confirmed boolean, is_admin boolean,
  plan text, plan_since timestamptz, plan_until date, plan_note text, paid_total numeric, feedbacks int,
  mins_total int, mins_30 int, days_30 int, last_seen date, opens_30 int, top_screen text, counts jsonb
)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform private.must_admin();
  return query
  select u.id, u.email::text,
    coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', w.name, '')::text,
    coalesce(nullif(pr.data->>'ig', ''), nullif(ltrim(pr.data#>>'{kit,ig}', '@'), ''), nullif(ltrim(w.instagram, '@'), ''))::text,
    w.whatsapp::text,
    coalesce(pr.data->'obKinds', '[]'::jsonb),
    w.id is not null,
    u.created_at, u.last_sign_in_at, u.email_confirmed_at is not null,
    exists (select 1 from private.admins a where a.user_id = u.id),
    coalesce(pl.plan, 'free'), pl.since, pl.until, pl.note,
    coalesce((select sum(r.amount) from public.revenue r where r.user_id = u.id), 0),
    (select count(*)::int from public.feedback f where f.user_id = u.id),
    coalesce(us.tot, 0), coalesce(us.m30, 0), coalesce(us.d30, 0), us.last, coalesce(us.o30, 0),
    (select x.screen from public.usage_days x where x.user_id = u.id and x.screen <> '_app' and x.day > hoje - 30
       group by x.screen order by sum(x.secs) desc limit 1),
    coalesce((select jsonb_object_agg(c.col, c.n) from (
       select i.col, count(*) n from public.items i
       where i.user_id = u.id and coalesce(i.data->>'example', '') <> 'true' group by i.col) c), '{}'::jsonb)
  from auth.users u
  left join public.profiles pr on pr.user_id = u.id
  left join public.plans pl on pl.user_id = u.id
  left join lateral (select * from public.waitlist w0 where lower(w0.email) = lower(u.email) limit 1) w on true
  left join lateral (
    select (sum(x.secs) / 60)::int tot,
      (sum(x.secs) filter (where x.day > hoje - 30) / 60)::int m30,
      count(distinct x.day) filter (where x.day > hoje - 30)::int d30,
      max(x.day) last,
      sum(x.opens) filter (where x.day > hoje - 30)::int o30
    from public.usage_days x where x.user_id = u.id
  ) us on true
  order by u.created_at desc;
end $$;

-- tempo de uma creator em cada tela (últimos 30 dias)
create or replace function public.admin_user_screens(p_user uuid)
returns table (screen text, mins int, days int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform private.must_admin();
  return query
  select x.screen, round(sum(x.secs) / 60.0)::int, count(distinct x.day)::int
  from public.usage_days x
  where x.user_id = p_user and x.day > hoje - 30 and x.screen <> '_app'
  group by x.screen order by sum(x.secs) desc;
end $$;

-- mudar o plano (Grátis ↔ Pro)
create or replace function public.admin_set_plan(p_user uuid, p_plan text, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform private.must_admin();
  if p_plan not in ('free', 'pro') then raise exception 'plano inválido'; end if;
  insert into public.plans (user_id, plan, since, note, updated_at)
  values (p_user, p_plan, now(), left(p_note, 200), now())
  on conflict (user_id) do update set
    since = case when public.plans.plan = excluded.plan then public.plans.since else now() end,
    plan = excluded.plan, note = coalesce(excluded.note, public.plans.note), updated_at = now();
end $$;

-- lista de espera completa
create or replace function public.admin_waitlist()
returns setof public.waitlist language plpgsql stable security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  return query select * from public.waitlist order by created_at desc;
end $$;

-- tirar alguém da lista (quem pediu pra sair)
create or replace function public.admin_waitlist_remove(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  delete from public.waitlist where id = p_id;
end $$;

-- feedbacks com nome de quem mandou
create or replace function public.admin_feedback()
returns table (id uuid, created_at timestamptz, user_id uuid, name text, email text, kind text, message text,
  screen text, ua text, status text, reply text, replied_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.must_admin();
  return query
  select f.id, f.created_at, f.user_id, coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', '')::text, u.email::text,
    f.kind, f.message, f.screen, f.ua, f.status, f.reply, f.replied_at
  from public.feedback f
  left join auth.users u on u.id = f.user_id
  left join public.profiles pr on pr.user_id = f.user_id
  order by (f.status = 'resolvido'), f.created_at desc
  limit 500;
end $$;

create or replace function public.admin_feedback_update(p_id uuid, p_status text, p_reply text default null)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  if p_status not in ('novo', 'vendo', 'resolvido') then raise exception 'status inválido'; end if;
  update public.feedback set status = p_status,
    reply = case when nullif(trim(p_reply), '') is null then reply else left(trim(p_reply), 2000) end,
    replied_at = case when nullif(trim(p_reply), '') is null then replied_at else now() end
  where id = p_id;
end $$;

-- erros agrupados (últimos 30 dias)
create or replace function public.admin_errors()
returns table (msg text, n int, users int, last_at timestamptz, screens text, src text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.must_admin();
  return query
  select e.msg, count(*)::int, count(distinct e.user_id)::int, max(e.created_at),
    string_agg(distinct e.screen, ', '), max(e.src)
  from public.app_errors e where e.created_at > now() - interval '30 days'
  group by e.msg order by max(e.created_at) desc limit 100;
end $$;

-- pagamentos
create or replace function public.admin_revenue()
returns table (id uuid, user_id uuid, payer text, email text, amount numeric, paid_at date, method text, period text, note text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.must_admin();
  return query
  select r.id, r.user_id, coalesce(nullif(r.payer, ''), nullif(pr.data->>'name', ''), u.email::text, '')::text, u.email::text,
    r.amount, r.paid_at, r.method, r.period, r.note
  from public.revenue r
  left join auth.users u on u.id = r.user_id
  left join public.profiles pr on pr.user_id = r.user_id
  order by r.paid_at desc, r.created_at desc;
end $$;

-- registrar pagamento: se for de uma creator, ela vira Pro até o fim do período pago
create or replace function public.admin_add_payment(p_user uuid, p_amount numeric, p_paid date, p_method text,
  p_period text, p_note text default null, p_payer text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare cur date; base date; ate date;
begin
  perform private.must_admin();
  insert into public.revenue (user_id, payer, amount, paid_at, method, period, note)
  values (p_user, left(p_payer, 120), p_amount, coalesce(p_paid, (now() at time zone 'America/Sao_Paulo')::date),
    coalesce(p_method, 'pix'), coalesce(p_period, 'mensal'), left(p_note, 200));
  if p_user is not null and p_period in ('mensal', 'anual') then
    select until into cur from public.plans where user_id = p_user;
    base := greatest(coalesce(cur, p_paid), p_paid);
    ate := (base + case when p_period = 'anual' then interval '1 year' else interval '1 month' end)::date;
    insert into public.plans (user_id, plan, since, until, updated_at) values (p_user, 'pro', now(), ate, now())
    on conflict (user_id) do update set
      since = case when public.plans.plan = 'pro' then public.plans.since else now() end,
      plan = 'pro', until = ate, updated_at = now();
  end if;
end $$;

create or replace function public.admin_delete_payment(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  delete from public.revenue where id = p_id;
end $$;

do $$ declare f text; begin
  foreach f in array array['admin_overview()', 'admin_daily(int)', 'admin_screens(int)', 'admin_users()',
    'admin_user_screens(uuid)', 'admin_set_plan(uuid,text,text)', 'admin_waitlist()', 'admin_waitlist_remove(uuid)',
    'admin_feedback()', 'admin_feedback_update(uuid,text,text)', 'admin_errors()', 'admin_revenue()',
    'admin_add_payment(uuid,numeric,date,text,text,text,text)', 'admin_delete_payment(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- 👇 deve aparecer o seu e-mail aqui. Se vier vazio, troque os e-mails lá em cima e rode de novo
select u.email as "admin do painel" from private.admins a join auth.users u on u.id = a.user_id;
