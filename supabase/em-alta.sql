-- CriaHub · "Em alta": músicas e trends da semana por nicho
-- Rode uma vez no SQL Editor do Supabase.
--   • tabela public.trends: uma linha por semana (segunda-feira), dados em JSON
--   • todo mundo pode LER (o app mostra pra todas as creators)
--   • só a tarefa semanal ESCREVE, pela função publish_trends, que confere uma chave própria
--   • no fim aparece a chave da tarefa (copie e guarde como CRIAHUB_TRENDS_KEY nas
--     configurações do ambiente do Claude). Não mande essa chave pra ninguém.
create table if not exists public.trends (
  week date primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.trends enable row level security;
drop policy if exists "trends: leitura pra todos" on public.trends;
create policy "trends: leitura pra todos" on public.trends for select to anon, authenticated using (true);

create or replace function public.publish_trends(p_key text, p_week date, p_data jsonb) returns text
  language plpgsql security definer set search_path = public as $$
begin
  if not public.radar_key_ok(p_key) then raise exception 'chave inválida'; end if;
  insert into public.trends (week, data, updated_at) values (p_week, p_data, now())
    on conflict (week) do update set data = excluded.data, updated_at = now();
  delete from public.trends where week < p_week - 84;  -- guarda só as últimas 12 semanas
  return 'ok ' || p_week;
end $$;
revoke all on function public.publish_trends(text, date, jsonb) from public;
grant execute on function public.publish_trends(text, date, jsonb) to anon, authenticated;

-- chave própria da tarefa "Em alta" (separada da do Radar; aceita pela mesma conferência)
create table if not exists private.trends_key (id int primary key default 1, key text not null);
alter table private.trends_key enable row level security;
revoke all on private.trends_key from anon, authenticated;
insert into private.trends_key (id, key)
  values (1, 'alta_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
  on conflict (id) do nothing;
insert into private.radar_key (id, key_hash)
  select 3, encode(sha256(convert_to(key, 'UTF8')), 'hex') from private.trends_key where id = 1
  on conflict (id) do update set key_hash = excluded.key_hash;

select key as copie_esta_chave from private.trends_key where id = 1;
