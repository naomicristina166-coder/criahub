-- CriaHub · programa de afiliadas
-- Rode no SQL Editor do Supabase DEPOIS do admin.sql e do pagamento.sql (pode rodar de novo: nada é duplicado).
--   • affiliates: quem é afiliada, o código do link, as porcentagens e a chave Pix pra receber
--   • referrals: quem chegou por qual afiliada (pelo link do app ?ref=codigo ou pela lista ?origem=codigo)
--   • commissions: a comissão de cada pagamento de uma indicada (a fundadora paga até o dia 10 do mês seguinte)
-- Regra combinada (09/11/2026): 20% enquanto a cliente pagar; primeiras afiliadas (Crias Beta) 30% nos
-- primeiros 12 meses de cada cliente e 20% depois.

create table if not exists public.affiliates (
  user_id      uuid primary key references auth.users on delete cascade,
  code         text not null unique check (code ~ '^[a-z0-9_-]{2,30}$'),
  rate_first   numeric not null default 20 check (rate_first between 0 and 60),
  first_months int     not null default 12 check (first_months between 0 and 120),
  rate_after   numeric not null default 20 check (rate_after between 0 and 60),
  pix_type     text,
  pix_key      text check (char_length(pix_key) <= 120),
  active       boolean not null default true,
  note         text,
  created_at   timestamptz not null default now()
);
alter table public.affiliates enable row level security;

create table if not exists public.referrals (
  referred_user uuid primary key references auth.users on delete cascade,
  affiliate_id  uuid not null references public.affiliates(user_id) on delete cascade,
  code          text not null,
  via           text not null default 'app',
  created_at    timestamptz not null default now()
);
alter table public.referrals enable row level security;

create table if not exists public.commissions (
  id            bigint generated always as identity primary key,
  affiliate_id  uuid not null references public.affiliates(user_id) on delete cascade,
  referred_user uuid references auth.users on delete set null,
  payment_id    text not null unique,
  pay_value     numeric not null,
  rate          numeric not null,
  amount        numeric not null,
  month         date not null,
  status        text not null default 'a pagar' check (status in ('a pagar', 'pago', 'cancelado')),
  paid_at       timestamptz,
  created_at    timestamptz not null default now()
);
alter table public.commissions enable row level security;
create index if not exists commissions_aff_idx on public.commissions (affiliate_id, status);

-- a creator logada se liga à afiliada do link (só uma vez, nunca a si mesma)
create or replace function public.aff_claim(p_code text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_aff uuid; v_code text := lower(trim(coalesce(p_code, '')));
begin
  if auth.uid() is null or v_code = '' then return jsonb_build_object('ok', false); end if;
  if exists (select 1 from public.referrals where referred_user = auth.uid()) then return jsonb_build_object('ok', true, 'already', true); end if;
  select user_id into v_aff from public.affiliates where code = v_code and active;
  if v_aff is null or v_aff = auth.uid() then return jsonb_build_object('ok', false); end if;
  insert into public.referrals (referred_user, affiliate_id, code, via) values (auth.uid(), v_aff, v_code, 'app') on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.aff_claim(text) from public, anon;
grant execute on function public.aff_claim(text) to authenticated;

-- descobre a afiliada de uma creator: pelo vínculo do app, ou pela origem com que ela entrou na lista
create or replace function private.aff_of(p_user uuid)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_aff uuid; v_email text; v_src text;
begin
  select affiliate_id into v_aff from public.referrals where referred_user = p_user;
  if v_aff is not null then return v_aff; end if;
  select lower(email) into v_email from auth.users where id = p_user;
  select lower(source) into v_src from public.waitlist where lower(email) = v_email order by created_at limit 1;
  if v_src is null then return null; end if;
  select user_id into v_aff from public.affiliates where code = v_src and active;
  if v_aff is null or v_aff = p_user then return null; end if;
  insert into public.referrals (referred_user, affiliate_id, code, via) values (p_user, v_aff, v_src, 'lista') on conflict do nothing;
  return v_aff;
end $$;

-- comissão de um pagamento confirmado (a função "pagamento" chama a cada cobrança paga)
create or replace function public.aff_commission(p_email text, p_payment text, p_value numeric)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid; v_aff uuid; a public.affiliates; v_since timestamptz; v_rate numeric; v_amt numeric;
begin
  if p_value is null or p_value <= 0 then return jsonb_build_object('ok', false); end if;
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if v_uid is null then return jsonb_build_object('ok', false, 'reason', 'sem conta'); end if;
  v_aff := private.aff_of(v_uid);
  if v_aff is null then return jsonb_build_object('ok', true, 'aff', false); end if;
  select * into a from public.affiliates where user_id = v_aff;
  select created_at into v_since from public.referrals where referred_user = v_uid;
  v_rate := case when now() < coalesce(v_since, now()) + make_interval(months => a.first_months) then a.rate_first else a.rate_after end;
  v_amt := round(p_value * v_rate / 100, 2);
  insert into public.commissions (affiliate_id, referred_user, payment_id, pay_value, rate, amount, month)
    values (v_aff, v_uid, p_payment, p_value, v_rate, v_amt, date_trunc('month', now() at time zone 'America/Sao_Paulo')::date)
    on conflict (payment_id) do nothing;
  return jsonb_build_object('ok', true, 'aff', true, 'amount', v_amt);
end $$;
revoke all on function public.aff_commission(text, text, numeric) from public, anon, authenticated;
grant execute on function public.aff_commission(text, text, numeric) to service_role;

-- quem pagou antes de ter conta: quando ela entra (pay_claim), a comissão também é lançada
create or replace function public.pay_claim()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_email text := lower(coalesce(auth.jwt() ->> 'email', '')); r record; v_n int := 0; v_val numeric;
begin
  if auth.uid() is null or v_email = '' then return jsonb_build_object('n', 0); end if;
  for r in select * from public.pay_pending where email = v_email and claimed_at is null order by created_at loop
    update public.pay_pending set claimed_at = now() where id = r.id;
    update public.pay_events set status = 'reclamado' where payment_id = r.payment_id;
    perform public.pay_grant(v_email, r.months, r.note, r.payment_id || ':ok', null, null);
    select value into v_val from public.pay_events where payment_id = r.payment_id;
    perform public.aff_commission(v_email, r.payment_id, v_val);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('n', v_n);
end $$;

-- o painel da afiliada (só os dados dela; das indicadas, só o primeiro nome)
create or replace function public.aff_me()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare a public.affiliates; v_month date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into a from public.affiliates where user_id = auth.uid();
  if a.user_id is null then return null; end if;
  return jsonb_build_object(
    'code', a.code, 'rate_first', a.rate_first, 'first_months', a.first_months, 'rate_after', a.rate_after,
    'pix_type', a.pix_type, 'pix_key', a.pix_key, 'active', a.active,
    'referred', (select count(*) from public.referrals where affiliate_id = a.user_id),
    'pro_active', (select count(*) from public.referrals r join public.plans p on p.user_id = r.referred_user
                    where r.affiliate_id = a.user_id and p.plan = 'pro' and (p.until is null or p.until >= current_date)),
    'month_amount', (select coalesce(sum(amount), 0) from public.commissions where affiliate_id = a.user_id and month = v_month and status <> 'cancelado'),
    'to_pay', (select coalesce(sum(amount), 0) from public.commissions where affiliate_id = a.user_id and status = 'a pagar'),
    'paid', (select coalesce(sum(amount), 0) from public.commissions where affiliate_id = a.user_id and status = 'pago'),
    'people', coalesce((select jsonb_agg(jsonb_build_object(
        'name', split_part(coalesce(nullif(pr.data ->> 'name', ''), 'Creator'), ' ', 1),
        'since', r.created_at,
        'pro', exists (select 1 from public.plans p where p.user_id = r.referred_user and p.plan = 'pro' and (p.until is null or p.until >= current_date)),
        'earned', (select coalesce(sum(amount), 0) from public.commissions c where c.referred_user = r.referred_user and c.affiliate_id = a.user_id and c.status <> 'cancelado'))
        order by r.created_at desc)
      from public.referrals r left join public.profiles pr on pr.user_id = r.referred_user where r.affiliate_id = a.user_id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('month', m.month, 'amount', m.amount, 'status', m.status) order by m.month desc)
      from (select month, sum(amount) as amount, case when bool_and(status = 'pago') then 'pago' else 'a pagar' end as status
            from public.commissions where affiliate_id = a.user_id and status <> 'cancelado' group by month) m), '[]'::jsonb)
  );
end $$;
revoke all on function public.aff_me() from public, anon;
grant execute on function public.aff_me() to authenticated;

create or replace function public.aff_set_pix(p_type text, p_key text)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  update public.affiliates set pix_type = left(p_type, 20), pix_key = left(trim(p_key), 120) where user_id = auth.uid();
end $$;
revoke all on function public.aff_set_pix(text, text) from public, anon;
grant execute on function public.aff_set_pix(text, text) to authenticated;

-- ===== painel da fundadora =====
create or replace function public.admin_aff_make(p_user uuid, p_code text, p_beta boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_code text := lower(regexp_replace(trim(coalesce(p_code, '')), '[^a-zA-Z0-9_-]', '', 'g'));
begin
  perform private.must_admin();
  if char_length(v_code) < 2 then raise exception 'Escolha um código com pelo menos 2 letras (sem espaço nem acento).'; end if;
  if exists (select 1 from public.affiliates where code = v_code and user_id <> p_user) then raise exception 'Esse código já é de outra afiliada.'; end if;
  insert into public.affiliates (user_id, code, rate_first, first_months, rate_after, note)
    values (p_user, v_code, case when p_beta then 30 else 20 end, 12, 20, case when p_beta then 'Cria Beta' else null end)
    on conflict (user_id) do update set code = excluded.code, rate_first = excluded.rate_first, rate_after = excluded.rate_after, active = true;
  return jsonb_build_object('ok', true, 'code', v_code);
end $$;
revoke all on function public.admin_aff_make(uuid, text, boolean) from public, anon;
grant execute on function public.admin_aff_make(uuid, text, boolean) to authenticated;

create or replace function public.admin_affiliates()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  return coalesce((select jsonb_agg(x order by x.to_pay desc, x.code) from (
    select a.user_id, a.code, a.rate_first, a.first_months, a.rate_after, a.pix_type, a.pix_key, a.active, a.note,
      coalesce(nullif(pr.data ->> 'name', ''), u.email) as name, u.email,
      (select count(*) from public.referrals r where r.affiliate_id = a.user_id) as referred,
      (select count(*) from public.referrals r join public.plans p on p.user_id = r.referred_user
        where r.affiliate_id = a.user_id and p.plan = 'pro' and (p.until is null or p.until >= current_date)) as pro_active,
      (select coalesce(sum(amount), 0) from public.commissions c where c.affiliate_id = a.user_id and c.status = 'a pagar') as to_pay,
      (select coalesce(sum(amount), 0) from public.commissions c where c.affiliate_id = a.user_id and c.status = 'pago') as paid
    from public.affiliates a join auth.users u on u.id = a.user_id left join public.profiles pr on pr.user_id = a.user_id) x), '[]'::jsonb);
end $$;
revoke all on function public.admin_affiliates() from public, anon;
grant execute on function public.admin_affiliates() to authenticated;

-- marca como pago tudo que estava a pagar dessa afiliada (depois que você fez o Pix)
create or replace function public.admin_aff_paid(p_user uuid)
returns numeric language plpgsql security definer set search_path = ''
as $$
declare v numeric;
begin
  perform private.must_admin();
  update public.commissions set status = 'pago', paid_at = now() where affiliate_id = p_user and status = 'a pagar';
  select coalesce(sum(amount), 0) into v from public.commissions where affiliate_id = p_user and paid_at > now() - interval '1 minute';
  return v;
end $$;
revoke all on function public.admin_aff_paid(uuid) from public, anon;
grant execute on function public.admin_aff_paid(uuid) to authenticated;

create or replace function public.admin_aff_toggle(p_user uuid, p_active boolean)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  update public.affiliates set active = p_active where user_id = p_user;
end $$;
revoke all on function public.admin_aff_toggle(uuid, boolean) from public, anon;
grant execute on function public.admin_aff_toggle(uuid, boolean) to authenticated;

select 'Programa de afiliadas pronto 💸' as resultado;
