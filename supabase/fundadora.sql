-- CriaHub · Ferramentas da fundadora: Radar da fundadora, CRM e Momentos
-- Rode no SQL Editor do Supabase DEPOIS do admin.sql (pode rodar de novo: nada é duplicado).
--   • Radar da fundadora: uma tarefa diária grava 1 notícia + 1 aprendizado de marketing.
--     Só a fundadora lê (pelo painel). Usa a mesma chave do Radar UGC.
--   • CRM: seus contatos (testadoras, afiliadas, creators, parcerias, imprensa…), etapa,
--     próximo follow-up e histórico de conversas. Ninguém além da fundadora acessa.
--   • Momentos: o banco percebe marcos de cada creator (1ª marca, 1º vídeo no ar, 1º pagamento,
--     30 dias de app, aniversário, virou Pro, sumiu) e o painel sugere um recado pessoal.
--     Ele só CONTA o que existe; não mostra o conteúdo do que ela cadastrou.

create schema if not exists private;

-- =============== RADAR DA FUNDADORA ===============
create table if not exists public.founder_days (
  date       date primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.founder_days enable row level security;
revoke all on public.founder_days from anon, authenticated;

-- a tarefa diária publica aqui (confere a chave do Radar)
create or replace function public.publish_founder(p_key text, p_date date, p_data jsonb) returns text
  language plpgsql security definer set search_path = public as $$
begin
  if not public.radar_key_ok(p_key) then raise exception 'chave inválida'; end if;
  insert into public.founder_days (date, data, updated_at) values (p_date, p_data, now())
    on conflict (date) do update set data = excluded.data, updated_at = now();
  delete from public.founder_days where date < p_date - 120;  -- guarda 4 meses
  return 'ok ' || p_date;
end $$;
revoke all on function public.publish_founder(text, date, jsonb) from public;
grant execute on function public.publish_founder(text, date, jsonb) to anon, authenticated;

-- a tarefa diária consulta só os títulos dos últimos dias, pra não repetir assunto
create or replace function public.founder_recent(p_key text) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
begin
  if not public.radar_key_ok(p_key) then raise exception 'chave inválida'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('date', d.date, 'news', d.data#>>'{news,title}', 'lesson', d.data#>>'{lesson,title}', 'area', d.data#>>'{lesson,area}') order by d.date desc)
    from (select * from public.founder_days order by date desc limit 21) d), '[]'::jsonb);
end $$;
revoke all on function public.founder_recent(text) from public;
grant execute on function public.founder_recent(text) to anon, authenticated;

-- o painel lê os últimos dias (e o que você já marcou como lido/salvo)
create table if not exists public.founder_marks (
  date   date primary key references public.founder_days on delete cascade,
  saved  boolean not null default false,
  done   boolean not null default false,
  note   text check (char_length(note) <= 1000),
  updated_at timestamptz not null default now()
);
alter table public.founder_marks enable row level security;
revoke all on public.founder_marks from anon, authenticated;

create or replace function public.admin_founder(p_days int default 30)
returns table (date date, data jsonb, saved boolean, done boolean, note text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.must_admin();
  return query select d.date, d.data, coalesce(m.saved, false), coalesce(m.done, false), m.note
    from public.founder_days d left join public.founder_marks m on m.date = d.date
    where d.date > (now() at time zone 'America/Sao_Paulo')::date - least(greatest(p_days, 1), 120)
       or coalesce(m.saved, false)
    order by d.date desc;
end $$;

create or replace function public.admin_founder_mark(p_date date, p_saved boolean default null, p_done boolean default null, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  insert into public.founder_marks (date, saved, done, note) values (p_date, coalesce(p_saved, false), coalesce(p_done, false), left(p_note, 1000))
  on conflict (date) do update set saved = coalesce(p_saved, public.founder_marks.saved), done = coalesce(p_done, public.founder_marks.done),
    note = coalesce(left(p_note, 1000), public.founder_marks.note), updated_at = now();
end $$;

-- =============== CRM ===============
create table if not exists public.crm_contacts (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  name       text not null check (char_length(name) between 1 and 100),
  kind       text not null default 'creator' check (kind in ('testadora', 'afiliada', 'creator', 'lista', 'parceria', 'imprensa', 'marca', 'outro')),
  stage      text not null default 'novo' check (stage in ('novo', 'contatada', 'conversando', 'fechado', 'pausado')),
  instagram  text check (char_length(instagram) <= 60),
  whatsapp   text check (char_length(whatsapp) <= 30),
  email      text check (char_length(email) <= 160),
  next_date  date,
  notes      text check (char_length(notes) <= 2000),
  source     text not null default 'manual' check (source in ('manual', 'lista', 'app')),
  user_id    uuid references auth.users on delete set null
);
create unique index if not exists crm_email_unique on public.crm_contacts (lower(email)) where email is not null and email <> '';
alter table public.crm_contacts enable row level security;
revoke all on public.crm_contacts from anon, authenticated;

create table if not exists public.crm_log (
  id         uuid primary key default gen_random_uuid(),
  contact_id uuid not null references public.crm_contacts on delete cascade,
  created_at timestamptz not null default now(),
  body       text not null check (char_length(body) between 1 and 1000)
);
create index if not exists crm_log_contact on public.crm_log (contact_id, created_at desc);
alter table public.crm_log enable row level security;
revoke all on public.crm_log from anon, authenticated;

create or replace function public.admin_crm()
returns table (id uuid, name text, kind text, stage text, instagram text, whatsapp text, email text, next_date date, notes text,
  source text, user_id uuid, created_at timestamptz, updated_at timestamptz, last_log text, last_log_at timestamptz, logs int, plan text, last_seen date)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.must_admin();
  return query
  select c.id, c.name, c.kind, c.stage, c.instagram, c.whatsapp, c.email, c.next_date, c.notes, c.source, c.user_id, c.created_at, c.updated_at,
    l.body, l.created_at, (select count(*)::int from public.crm_log x where x.contact_id = c.id),
    case when c.user_id is null then null else coalesce((select p.plan from public.plans p where p.user_id = c.user_id), 'free') end,
    (select max(u.day) from public.usage_days u where u.user_id = c.user_id)
  from public.crm_contacts c
  left join lateral (select x.body, x.created_at from public.crm_log x where x.contact_id = c.id order by x.created_at desc limit 1) l on true
  order by c.next_date nulls last, c.updated_at desc;
end $$;

-- salvar (cria se não tiver id)
create or replace function public.admin_crm_save(p jsonb)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_email text := nullif(lower(trim(p->>'email')), '');
begin
  perform private.must_admin();
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'nome obrigatório'; end if;
  if v_email is not null and exists (select 1 from public.crm_contacts c where lower(c.email) = v_email and c.id is distinct from v_id) then
    raise exception 'esse e-mail já está no CRM' using errcode = '23505';
  end if;
  if v_id is null then
    insert into public.crm_contacts (name, kind, stage, instagram, whatsapp, email, next_date, notes, user_id)
    values (left(trim(p->>'name'), 100), coalesce(nullif(p->>'kind', ''), 'creator'), coalesce(nullif(p->>'stage', ''), 'novo'),
      nullif(left(ltrim(trim(p->>'instagram'), '@'), 60), ''), nullif(left(trim(p->>'whatsapp'), 30), ''), v_email,
      nullif(p->>'next_date', '')::date, nullif(left(p->>'notes', 2000), ''),
      (select u.id from auth.users u where v_email is not null and lower(u.email) = v_email limit 1))
    returning id into v_id;
  else
    update public.crm_contacts set
      name = left(trim(p->>'name'), 100), kind = coalesce(nullif(p->>'kind', ''), kind), stage = coalesce(nullif(p->>'stage', ''), stage),
      instagram = nullif(left(ltrim(trim(p->>'instagram'), '@'), 60), ''), whatsapp = nullif(left(trim(p->>'whatsapp'), 30), ''), email = v_email,
      next_date = nullif(p->>'next_date', '')::date, notes = nullif(left(p->>'notes', 2000), ''),
      user_id = coalesce(user_id, (select u.id from auth.users u where v_email is not null and lower(u.email) = v_email limit 1)),
      updated_at = now()
    where id = v_id;
  end if;
  return v_id;
end $$;

-- mudar só a etapa ou o próximo follow-up (botões rápidos)
create or replace function public.admin_crm_quick(p_id uuid, p_stage text default null, p_next date default null, p_clear_next boolean default false)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  update public.crm_contacts set stage = coalesce(p_stage, stage),
    next_date = case when p_clear_next then null else coalesce(p_next, next_date) end, updated_at = now()
  where id = p_id;
end $$;

create or replace function public.admin_crm_delete(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$ begin perform private.must_admin(); delete from public.crm_contacts where id = p_id; end $$;

create or replace function public.admin_crm_log(p_id uuid)
returns table (id uuid, body text, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.must_admin();
  return query select l.id, l.body, l.created_at from public.crm_log l where l.contact_id = p_id order by l.created_at desc limit 100;
end $$;

create or replace function public.admin_crm_add_log(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  if coalesce(trim(p_body), '') = '' then return; end if;
  insert into public.crm_log (contact_id, body) values (p_id, left(trim(p_body), 1000));
  update public.crm_contacts set updated_at = now(), stage = case when stage = 'novo' then 'contatada' else stage end where id = p_id;
end $$;

-- traz pro CRM quem está na lista de espera e quem tem conta no app (sem duplicar)
create or replace function public.admin_crm_import()
returns int language plpgsql security definer set search_path = ''
as $$
declare n1 int; n2 int;
begin
  perform private.must_admin();
  insert into public.crm_contacts (name, kind, source, instagram, whatsapp, email, notes, user_id, created_at)
  select left(w.name, 100), 'lista', 'lista', nullif(left(ltrim(w.instagram, '@'), 60), ''), nullif(left(w.whatsapp, 30), ''), lower(w.email),
    nullif(left(w.pain, 2000), ''), (select u.id from auth.users u where lower(u.email) = lower(w.email) limit 1), w.created_at
  from public.waitlist w
  where not exists (select 1 from public.crm_contacts c where lower(c.email) = lower(w.email))
  on conflict do nothing;
  get diagnostics n1 = row_count;
  insert into public.crm_contacts (name, kind, source, instagram, email, user_id, created_at)
  select left(coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', split_part(u.email, '@', 1)), 100), 'creator', 'app',
    nullif(left(coalesce(nullif(pr.data->>'ig', ''), ltrim(pr.data#>>'{kit,ig}', '@')), 60), ''), lower(u.email), u.id, u.created_at
  from auth.users u left join public.profiles pr on pr.user_id = u.id
  where not exists (select 1 from private.admins a where a.user_id = u.id)
    and not exists (select 1 from public.crm_contacts c where lower(c.email) = lower(u.email))
  on conflict do nothing;
  get diagnostics n2 = row_count;
  -- quem era da lista e agora tem conta: liga o contato à conta
  update public.crm_contacts c set user_id = u.id from auth.users u
  where c.user_id is null and c.email is not null and lower(u.email) = lower(c.email);
  return n1 + n2;
end $$;

-- =============== MOMENTOS (marketing de experiência) ===============
create table if not exists public.moments_done (
  user_id uuid not null references auth.users on delete cascade,
  kind    text not null,
  ref     text not null default '',
  done_at timestamptz not null default now(),
  how     text check (how in ('enviado', 'pulado')),
  primary key (user_id, kind, ref)
);
alter table public.moments_done enable row level security;
revoke all on public.moments_done from anon, authenticated;

create or replace function private.dt(t text, fallback timestamptz) returns date
language sql immutable as $$
  select case when t ~ '^\d{4}-\d{2}-\d{2}' then left(t, 10)::date else (fallback at time zone 'America/Sao_Paulo')::date end
$$;

-- próximo aniversário a partir de hoje (ignora data inválida em vez de quebrar)
create or replace function private.next_bday(mmdd text, hoje date) returns date
language plpgsql immutable as $$
declare d date;
begin
  if coalesce(mmdd, '') !~ '^\d{2}-\d{2}$' then return null; end if;
  begin
    d := make_date(extract(year from hoje)::int, split_part(mmdd, '-', 1)::int, split_part(mmdd, '-', 2)::int);
    if d < hoje then d := make_date(extract(year from hoje)::int + 1, split_part(mmdd, '-', 1)::int, split_part(mmdd, '-', 2)::int); end if;
  exception when others then return null;
  end;
  return d;
end $$;

-- marcos das últimas 2 semanas (e aniversários dos próximos 7 dias), ainda sem recado seu
create or replace function public.admin_moments()
returns table (user_id uuid, name text, email text, whatsapp text, instagram text, kind text, ref text, happened date, detail text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform private.must_admin();
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
    u.email::text, w.whatsapp::text,
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

create or replace function public.admin_moment_done(p_user uuid, p_kind text, p_ref text default '', p_how text default 'enviado')
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  insert into public.moments_done (user_id, kind, ref, how) values (p_user, p_kind, coalesce(p_ref, ''), case when p_how = 'pulado' then 'pulado' else 'enviado' end)
  on conflict (user_id, kind, ref) do update set how = excluded.how, done_at = now();
end $$;

-- quantos recados você já mandou (pro painel mostrar o seu ritmo)
create or replace function public.admin_moments_stats()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  return jsonb_build_object(
    'sent30', (select count(*) from public.moments_done where how = 'enviado' and done_at > now() - interval '30 days'),
    'sentAll', (select count(*) from public.moments_done where how = 'enviado'));
end $$;

-- permissões: só usuárias logadas chamam; cada função confere se é a fundadora
do $$ declare f text; begin
  foreach f in array array['admin_founder(integer)', 'admin_founder_mark(date,boolean,boolean,text)', 'admin_crm()', 'admin_crm_save(jsonb)',
    'admin_crm_quick(uuid,text,date,boolean)', 'admin_crm_delete(uuid)', 'admin_crm_log(uuid)', 'admin_crm_add_log(uuid,text)', 'admin_crm_import()',
    'admin_moments()', 'admin_moment_done(uuid,text,text,text)', 'admin_moments_stats()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select 'ferramentas da fundadora prontas ✨' as resultado;
