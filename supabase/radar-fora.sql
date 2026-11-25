-- =============== RADAR LÁ FORA (só a fundadora vê) ===============
-- Toda sexta, a tarefa agendada traz 3 novidades de fora (apps, tendências, formatos) com o que são,
-- por que fariam sucesso no Brasil e como usar. Aparece na aba "Lá fora 🌎" do painel admin.
-- Rode depois do fundadora.sql (usa radar_key_ok e private.admins).

create table if not exists public.fora_weeks (
  week       date primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.fora_weeks enable row level security;
revoke all on public.fora_weeks from anon, authenticated;

create table if not exists public.fora_marks (
  week  date not null,
  idx   int  not null,
  saved boolean not null default false,
  primary key (week, idx)
);
alter table public.fora_marks enable row level security;
revoke all on public.fora_marks from anon, authenticated;

create or replace function public.publish_fora(p_key text, p_week date, p_data jsonb) returns text
  language plpgsql security definer set search_path = public as $$
declare novo boolean;
begin
  if not public.radar_key_ok(p_key) then raise exception 'chave inválida'; end if;
  novo := not exists (select 1 from public.fora_weeks where week = p_week);
  insert into public.fora_weeks (week, data, updated_at) values (p_week, p_data, now())
    on conflict (week) do update set data = excluded.data, updated_at = now();
  delete from public.fora_weeks where week < p_week - 365;
  if novo and to_regclass('public.warm_alerts') is not null then
    execute format('insert into public.warm_alerts (user_id, send_at, title, body, tag, url) select a.user_id, now(), %L, %L, %L, %L from private.admins a',
      '🌎 Novidades de fora da semana', left(coalesce(p_data->>'headline', '3 novidades de fora pra você trazer pro Brasil'), 200), 'fora-' || p_week, '/#painel');
  end if;
  return 'ok ' || p_week;
end $$;
revoke all on function public.publish_fora(text, date, jsonb) from public;
grant execute on function public.publish_fora(text, date, jsonb) to anon, authenticated;

create or replace function public.fora_recent(p_key text) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
begin
  if not public.radar_key_ok(p_key) then raise exception 'chave inválida'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('week', w.week, 'titles', (select jsonb_agg(x->>'title') from jsonb_array_elements(w.data->'items') x)) order by w.week desc)
    from (select * from public.fora_weeks order by week desc limit 12) w), '[]'::jsonb);
end $$;
revoke all on function public.fora_recent(text) from public;
grant execute on function public.fora_recent(text) to anon, authenticated;

create or replace function public.admin_fora(p_weeks int default 26) returns jsonb
  language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.must_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('week', w.week, 'data', w.data,
      'saved', coalesce((select jsonb_agg(m.idx) from public.fora_marks m where m.week = w.week and m.saved), '[]'::jsonb)) order by w.week desc)
    from (select * from public.fora_weeks order by week desc limit greatest(1, least(p_weeks, 104))) w), '[]'::jsonb);
end $$;
revoke all on function public.admin_fora(int) from public, anon;
grant execute on function public.admin_fora(int) to authenticated;

create or replace function public.admin_fora_save(p_week date, p_idx int) returns void
  language plpgsql security definer set search_path = '' as $$
begin
  perform private.must_admin();
  insert into public.fora_marks (week, idx, saved) values (p_week, p_idx, true) on conflict (week, idx) do update set saved = true;
end $$;
revoke all on function public.admin_fora_save(date, int) from public, anon;
grant execute on function public.admin_fora_save(date, int) to authenticated;
