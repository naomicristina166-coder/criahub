-- CriaHub · "E-mails importantes": encaminhamento + aviso se ficar sem ver
-- Rode uma vez no SQL Editor do Supabase (pode rodar de novo: nada é duplicado).
--   • cada creator ganha um endereço de encaminhamento só dela (endereço do Postmark + um apelido sorteado)
--   • o e-mail encaminhado chega pela função "caixa" e aparece na Início do CriaHub
--   • guardamos só remetente, assunto, data e um trechinho. Some sozinho depois de 30 dias
--   • se ela não tocar em "Abrir" nem em "Já vi" em 24h, a função manda UM lembrete no celular
--   • nunca pedimos senha de e-mail
-- Antes de rodar: troque COLE_O_ENDERECO_DO_POSTMARK (linha marcada com 👉) pelo endereço de
-- entrada do Postmark (Servers › seu servidor › Default Inbound Stream › Settings, termina em
-- @inbound.postmarkapp.com). No fim aparece o endereço do webhook pra colar no Postmark.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- configuração (o app lê o endereço de entrada; segredos ficam no schema private)
create table if not exists public.mail_cfg (id int primary key default 1, inbound text);
alter table public.mail_cfg enable row level security;
drop policy if exists "mail_cfg: leitura" on public.mail_cfg;
create policy "mail_cfg: leitura" on public.mail_cfg for select to authenticated using (true);
insert into public.mail_cfg (id, inbound) values (1, null) on conflict (id) do nothing;
-- 👉 troque aqui:
update public.mail_cfg set inbound = lower(trim('COLE_O_ENDERECO_DO_POSTMARK')) where id = 1;

create table if not exists private.mail_key (id int primary key default 1, hook text not null, cron text not null);
alter table private.mail_key enable row level security;
revoke all on private.mail_key from anon, authenticated;
insert into private.mail_key (id, hook, cron)
  values (1, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
             replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
  on conflict (id) do nothing;

-- apelido de cada creator (vai depois do + no endereço)
create table if not exists public.mail_alias (
  user_id uuid primary key references auth.users on delete cascade,
  alias text not null unique,
  work_email text,
  created_at timestamptz not null default now()
);
alter table public.mail_alias enable row level security;
drop policy if exists "mail_alias: só a dona" on public.mail_alias;
create policy "mail_alias: só a dona" on public.mail_alias for select to authenticated using (user_id = auth.uid());

-- e-mails recebidos (só o resumo)
create table if not exists public.mail_msgs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  kind text not null default 'outro',          -- proposta | mei | pagamento | outro | confirma
  from_name text, from_addr text, subject text, snippet text,
  msgid text, code text, link text,
  received_at timestamptz not null default now(),
  seen_at timestamptz, reminded_at timestamptz
);
create unique index if not exists mail_msgs_uniq on public.mail_msgs (user_id, msgid);
create index if not exists mail_msgs_user on public.mail_msgs (user_id, received_at desc);
alter table public.mail_msgs enable row level security;
drop policy if exists "mail_msgs: ler as minhas" on public.mail_msgs;
create policy "mail_msgs: ler as minhas" on public.mail_msgs for select to authenticated using (user_id = auth.uid());
drop policy if exists "mail_msgs: apagar as minhas" on public.mail_msgs;
create policy "mail_msgs: apagar as minhas" on public.mail_msgs for delete to authenticated using (user_id = auth.uid());

-- meu endereço (cria o apelido na primeira vez)
create or replace function public.mail_me() returns jsonb
  language plpgsql security definer set search_path = public as $$
declare a public.mail_alias; b text;
begin
  if auth.uid() is null then raise exception 'sem login'; end if;
  select * into a from public.mail_alias where user_id = auth.uid();
  if not found then
    loop
      begin
        insert into public.mail_alias (user_id, alias)
          values (auth.uid(), substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
          returning * into a;
        exit;
      exception when unique_violation then
        select * into a from public.mail_alias where user_id = auth.uid();
        if found then exit; end if;
      end;
    end loop;
  end if;
  select inbound into b from public.mail_cfg where id = 1;
  return jsonb_build_object('ready', b is not null and b like '%@%',
    'address', case when b like '%@%' then split_part(b, '@', 1) || '+' || lower(a.alias) || '@' || split_part(b, '@', 2) end,
    'work_email', a.work_email);
end $$;
revoke all on function public.mail_me() from public, anon;
grant execute on function public.mail_me() to authenticated;

create or replace function public.mail_set_email(p_email text) returns void
  language sql security definer set search_path = public as $$
  update public.mail_alias set work_email = nullif(lower(trim(p_email)), '') where user_id = auth.uid();
$$;
revoke all on function public.mail_set_email(text) from public, anon;
grant execute on function public.mail_set_email(text) to authenticated;

create or replace function public.mail_seen(p_id uuid) returns void
  language sql security definer set search_path = public as $$
  update public.mail_msgs set seen_at = coalesce(seen_at, now()) where id = p_id and user_id = auth.uid();
$$;
revoke all on function public.mail_seen(uuid) from public, anon;
grant execute on function public.mail_seen(uuid) to authenticated;

-- a função "caixa" confere os segredos por aqui (só ela, com a chave de serviço)
create or replace function public.mail_key_ok(p_kind text, p_val text) returns boolean
  language sql security definer set search_path = private as $$
  select coalesce((select case p_kind when 'hook' then hook when 'cron' then cron end from private.mail_key where id = 1) = p_val, false)
$$;
revoke all on function public.mail_key_ok(text, text) from public, anon, authenticated;
grant execute on function public.mail_key_ok(text, text) to service_role;

-- AGENDAMENTO: de hora em hora, das 8h às 20h de Brasília, manda os lembretes e apaga o que tem mais de 30 dias
select cron.unschedule('emails-criahub') where exists (select 1 from cron.job where jobname = 'emails-criahub');
select cron.schedule('emails-criahub', '17 11-23 * * *', $cron$
  delete from public.mail_msgs where received_at < now() - interval '30 days';
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('action', 'lembrar', 'key', (select cron from private.mail_key where id = 1)));
$cron$);

-- cole este endereço no Postmark (Default Inbound Stream › Settings › Webhook). Não mande pra ninguém.
select 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa?t=' || hook as webhook_do_postmark,
       (select inbound from public.mail_cfg where id = 1) as endereco_de_entrada
  from private.mail_key where id = 1;
