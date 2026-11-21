-- CriaHub · pagamento do Pro pelo Asaas
-- Rode no SQL Editor do Supabase (pode rodar de novo: nada é duplicado). Precisa do admin.sql já rodado.
--   • pay_links: os 4 links de pagamento (fundadora/normal × mensal/anual), criados pela função "pagamento"
--   • quando o Asaas confirma um pagamento, a função chama pay_grant: a conta com o mesmo e-mail vira Pro
--     até a data certa. Se ainda não existe conta com esse e-mail, fica guardado em pay_pending e vira Pro
--     sozinho quando ela entrar (pay_claim, chamado pelo app).
--   • pay_events: histórico de cada pagamento (só a fundadora vê, pelo painel).

create table if not exists public.pay_links (
  key        text primary key,
  asaas_id   text not null,
  url        text not null,
  value      numeric not null,
  updated_at timestamptz not null default now()
);
alter table public.pay_links drop constraint if exists pay_links_key_check;
alter table public.pay_links add constraint pay_links_key_check check (key ~ '^(fund|pro)_(mensal|anual)(_pix)?$');
alter table public.pay_links enable row level security;
drop policy if exists "pay_links: todas veem" on public.pay_links;
create policy "pay_links: todas veem" on public.pay_links for select to authenticated using (true);

create table if not exists public.pay_events (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  payment_id  text not null unique,
  email       text,
  user_id     uuid references auth.users on delete set null,
  link_key    text,
  value       numeric,
  months      int,
  until       date,
  status      text
);
alter table public.pay_events enable row level security;  -- sem policy: só service_role e funções de admin

create table if not exists public.pay_pending (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  email       text not null,
  months      int not null,
  note        text,
  payment_id  text not null unique,
  claimed_at  timestamptz
);
alter table public.pay_pending enable row level security;

-- dá (ou estende) o Pro de quem tem esse e-mail. Só a função "pagamento" (service_role) chama.
create or replace function public.pay_grant(p_email text, p_months int, p_note text, p_payment text, p_link text, p_value numeric)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid; v_until date; v_cur date;
begin
  if exists (select 1 from public.pay_events where payment_id = p_payment and status = 'ok') then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if v_uid is null then
    insert into public.pay_pending (email, months, note, payment_id) values (lower(trim(p_email)), p_months, p_note, p_payment)
      on conflict (payment_id) do nothing;
    insert into public.pay_events (payment_id, email, link_key, value, months, status)
      values (p_payment, lower(trim(p_email)), p_link, p_value, p_months, 'pendente')
      on conflict (payment_id) do nothing;
    return jsonb_build_object('ok', true, 'pending', true);
  end if;
  select until into v_cur from public.plans where user_id = v_uid and plan = 'pro';
  v_until := (greatest(coalesce(v_cur, current_date), current_date) + make_interval(months => p_months))::date;
  insert into public.plans (user_id, plan, until, note, updated_at)
    values (v_uid, 'pro', v_until, left(p_note, 200), now())
    on conflict (user_id) do update set plan = 'pro', until = excluded.until, note = excluded.note, updated_at = now();
  insert into public.pay_events (payment_id, email, user_id, link_key, value, months, until, status)
    values (p_payment, lower(trim(p_email)), v_uid, p_link, p_value, p_months, v_until, 'ok')
    on conflict (payment_id) do update set user_id = v_uid, until = v_until, status = 'ok';
  return jsonb_build_object('ok', true, 'until', v_until);
end $$;
revoke all on function public.pay_grant(text, int, text, text, text, numeric) from public, anon, authenticated;
grant execute on function public.pay_grant(text, int, text, text, text, numeric) to service_role;

-- o app chama ao abrir: se ela pagou antes de criar a conta (ou com a conta deslogada), vira Pro agora
create or replace function public.pay_claim()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_email text := lower(coalesce(auth.jwt() ->> 'email', '')); r record; v_n int := 0;
begin
  if auth.uid() is null or v_email = '' then return jsonb_build_object('n', 0); end if;
  for r in select * from public.pay_pending where email = v_email and claimed_at is null order by created_at loop
    update public.pay_pending set claimed_at = now() where id = r.id;
    update public.pay_events set status = 'reclamado' where payment_id = r.payment_id;
    perform public.pay_grant(v_email, r.months, r.note, r.payment_id || ':ok', null, null);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('n', v_n);
end $$;
revoke all on function public.pay_claim() from public, anon;
grant execute on function public.pay_claim() to authenticated;

-- ela está na lista de espera? (preço de Cria Fundadora)
create or replace function public.pay_is_founder()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.waitlist where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))) $$;
revoke all on function public.pay_is_founder() from public, anon;
grant execute on function public.pay_is_founder() to authenticated;

-- painel: últimos pagamentos
create or replace function public.admin_payments()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  return coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from (select * from public.pay_events order by created_at desc limit 100) e), '[]'::jsonb);
end $$;
revoke all on function public.admin_payments() from public, anon;
grant execute on function public.admin_payments() to authenticated;

select 'Pagamento do Pro pronto 💸' as resultado;
