-- CriaHub · Painel da fundadora (criahub.app.br/admin)
-- Rode uma vez no SQL Editor do Supabase (pode rodar de novo: nada é duplicado).
--   • só quem está em private.admins consegue ver o painel. Para as outras creators, ele não existe
--   • plano de cada creator (Grátis ou Pro): só a admin muda; cada creator só enxerga o próprio
--   • uso do app: o app soma quantos segundos cada creator passa em cada tela, por dia.
--     Guarda só tempo e nome da tela, nunca o que ela escreveu
--   • o painel mostra QUANTAS marcas, entregas, ideias… cada uma tem, sem abrir o conteúdo
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

insert into private.admins (user_id)
select id from auth.users
where lower(email) in ('naomicristina166@gmail.com', 'criahubb@gmail.com')   -- 👉 seus e-mails de login
on conflict (user_id) do nothing;

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
    'avgDaySecs',   (select coalesce(round(avg(s)), 0) from d30 where s > 0)
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
create or replace function public.admin_users()
returns table (
  user_id uuid, email text, name text, created_at timestamptz, last_sign_in_at timestamptz,
  confirmed boolean, is_admin boolean, plan text, plan_since timestamptz, plan_note text,
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
    coalesce(pr.data->>'name', u.raw_user_meta_data->>'name', '')::text,
    u.created_at, u.last_sign_in_at, u.email_confirmed_at is not null,
    exists (select 1 from private.admins a where a.user_id = u.id),
    coalesce(pl.plan, 'free'), pl.since, pl.note,
    coalesce(us.tot, 0), coalesce(us.m30, 0), coalesce(us.d30, 0), us.last, coalesce(us.o30, 0),
    (select x.screen from public.usage_days x where x.user_id = u.id and x.screen <> '_app' and x.day > hoje - 30
       group by x.screen order by sum(x.secs) desc limit 1),
    coalesce((select jsonb_object_agg(c.col, c.n) from (
       select i.col, count(*) n from public.items i
       where i.user_id = u.id and coalesce(i.data->>'example', '') <> 'true' group by i.col) c), '{}'::jsonb)
  from auth.users u
  left join public.profiles pr on pr.user_id = u.id
  left join public.plans pl on pl.user_id = u.id
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

do $$ declare f text; begin
  foreach f in array array['admin_overview()', 'admin_daily(int)', 'admin_screens(int)', 'admin_users()',
    'admin_user_screens(uuid)', 'admin_set_plan(uuid,text,text)', 'admin_waitlist()', 'admin_waitlist_remove(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- 👇 deve aparecer o seu e-mail aqui. Se vier vazio, troque os e-mails lá em cima e rode de novo
select u.email as "admin do painel" from private.admins a join auth.users u on u.id = a.user_id;
