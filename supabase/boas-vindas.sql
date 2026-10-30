-- CriaHub · e-mail de boas-vindas automático da lista de espera
-- Rode uma vez no SQL Editor do Supabase, DEPOIS de colocar a função "boas-vindas" no ar
-- (pode rodar de novo: nada é duplicado).
--   • sempre que alguém entra na lista, o banco chama a função boas-vindas
--   • a função manda o e-mail e marca welcomed_at, então ninguém recebe duas vezes
--   • no fim aparece um código: copie e salve como segredo WAITLIST_HOOK_SECRET nas Edge Functions

create extension if not exists pg_net;
create schema if not exists private;

alter table public.waitlist add column if not exists welcomed_at timestamptz;

create table if not exists private.waitlist_hook (
  id     int primary key default 1,
  url    text not null,
  secret text not null
);
alter table private.waitlist_hook enable row level security;
revoke all on private.waitlist_hook from anon, authenticated;

insert into private.waitlist_hook (id, url, secret)
values (1,
  'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/boas-vindas',
  replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (id) do nothing;

create or replace function private.waitlist_welcome()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare h private.waitlist_hook;
begin
  select * into h from private.waitlist_hook where id = 1;
  if h.url is not null then
    perform net.http_post(
      url     := h.url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', h.secret),
      body    := jsonb_build_object('id', new.id)
    );
  end if;
  return new;
end $$;

drop trigger if exists waitlist_welcome on public.waitlist;
create trigger waitlist_welcome
  after insert on public.waitlist
  for each row execute function private.waitlist_welcome();

-- 👇 copie este código e salve como WAITLIST_HOOK_SECRET (Edge Functions › Secrets)
select secret as "WAITLIST_HOOK_SECRET" from private.waitlist_hook where id = 1;
