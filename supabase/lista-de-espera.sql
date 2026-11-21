-- CriaHub · Lista de espera (página criahub.app.br/lista)
-- Rode uma vez no SQL Editor do Supabase (pode rodar de novo: nada é duplicado).
--   • quem visita a página só consegue ENTRAR na lista; ninguém de fora lê os nomes
--   • cada e-mail entra uma vez só (se repetir, a página avisa que a pessoa já está na lista)
--   • a página mostra quantas crias já entraram, sem mostrar quem
--   • pra ver a lista: Table Editor › waitlist (dá pra exportar em CSV)

create table if not exists public.waitlist (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  name        text not null check (char_length(name) between 1 and 80),
  email       text not null check (char_length(email) <= 160 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  instagram   text check (char_length(instagram) <= 60),
  whatsapp    text check (char_length(whatsapp) <= 30),
  kind        text check (kind in ('ugc', 'tech', 'ambos', 'comecando')),
  pain        text check (char_length(pain) <= 500),
  source      text check (char_length(source) <= 60),
  consent     boolean not null default false
);

create unique index if not exists waitlist_email_unique on public.waitlist (lower(email));

alter table public.waitlist enable row level security;

drop policy if exists "waitlist: qualquer pessoa entra" on public.waitlist;
create policy "waitlist: qualquer pessoa entra" on public.waitlist
  for insert to anon, authenticated
  with check (consent = true);

-- contador público (só o número, nunca os dados)
create or replace function public.waitlist_count()
returns integer
language sql
security definer
set search_path = public
as $$ select count(*)::int from public.waitlist $$;

revoke all on function public.waitlist_count() from public;
grant execute on function public.waitlist_count() to anon, authenticated;
