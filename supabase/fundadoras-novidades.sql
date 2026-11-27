-- CriaHub · Novidades pras fundadoras (Crias Beta)
-- Rode no SQL Editor do Supabase DEPOIS do afiliadas.sql e do aquecimento-alarme.sql (pode rodar de novo: nada é duplicado).
--   • A fundadora escreve a novidade no painel (aba Fundadoras 🍒) e toca em "Mandar".
--   • Cada Cria Beta recebe uma notificação no celular (pela fila do aquecimento, que roda a cada minuto)
--     e, ao tocar, o app abre direto na novidade (criahub.app.br/#novidade).
--   • As novidades também ficam guardadas no topo do Guia da Fundadora.

create schema if not exists private;

-- quem é fundadora: afiliada ativa Cria Beta (comissão maior no começo)
create or replace function private.is_founder(p_user uuid) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.affiliates a where a.user_id = p_user and a.active
                 and (a.note = 'Cria Beta' or a.rate_first > a.rate_after))
$$;

create table if not exists public.founder_news (
  id         uuid primary key default gen_random_uuid(),
  title      text not null check (char_length(title) between 1 and 90),
  body       text check (char_length(body) <= 600),
  go         text not null default 'guia' check (go ~ '^[a-z]{2,20}$'),
  created_at timestamptz not null default now()
);
alter table public.founder_news enable row level security;
revoke all on public.founder_news from anon, authenticated;

-- o app lê (só fundadoras e admins)
create or replace function public.founder_news_list() returns jsonb
  language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.is_founder(auth.uid()) or public.is_admin()) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'body', n.body, 'go', n.go, 'at', n.created_at) order by n.created_at desc)
    from (select * from public.founder_news order by created_at desc limit 30) n), '[]'::jsonb);
end $$;
revoke all on function public.founder_news_list() from public, anon;
grant execute on function public.founder_news_list() to authenticated;

-- o painel manda: guarda a novidade e coloca uma notificação na fila pra cada fundadora
create or replace function public.admin_founder_news(p_title text, p_body text, p_go text) returns jsonb
  language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_n int; v_push int; v_go text := coalesce(nullif(lower(trim(p_go)), ''), 'guia');
begin
  perform private.must_admin();
  if v_go !~ '^[a-z]{2,20}$' then v_go := 'guia'; end if;
  insert into public.founder_news (title, body, go) values (left(trim(p_title), 90), nullif(left(trim(coalesce(p_body, '')), 600), ''), v_go)
    returning id into v_id;
  insert into public.warm_alerts (user_id, send_at, title, body, tag, url)
    select a.user_id, now(), left('🍒 ' || trim(p_title), 120), left(coalesce(nullif(trim(p_body), ''), 'Toque pra ver a novidade no app ✨'), 240), 'fundadoras', '/#novidade'
    from public.affiliates a where private.is_founder(a.user_id);
  get diagnostics v_n = row_count;
  select count(distinct s.user_id) into v_push from public.push_subs s where private.is_founder(s.user_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'founders', v_n, 'with_push', v_push);
end $$;
revoke all on function public.admin_founder_news(text, text, text) from public, anon;
grant execute on function public.admin_founder_news(text, text, text) to authenticated;

create or replace function public.admin_founder_news_list() returns jsonb
  language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.must_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'body', n.body, 'go', n.go, 'at', n.created_at) order by n.created_at desc)
    from public.founder_news n), '[]'::jsonb);
end $$;
revoke all on function public.admin_founder_news_list() from public, anon;
grant execute on function public.admin_founder_news_list() to authenticated;

create or replace function public.admin_founder_news_delete(p_id uuid) returns void
  language plpgsql security definer set search_path = '' as $$
begin
  perform private.must_admin();
  delete from public.founder_news where id = p_id;
end $$;
revoke all on function public.admin_founder_news_delete(uuid) from public, anon;
grant execute on function public.admin_founder_news_delete(uuid) to authenticated;
