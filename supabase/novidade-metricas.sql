-- =============== NOVIDADE: ANÁLISE DE MÉTRICAS ===============
-- Avisa todas as creators da novidade: e-mail (pelo Gmail do CriaHub) + notificação no celular de quem ligou as notificações.
-- Cada creator recebe UMA vez só (tabela public.news_sent). Dá pra rodar de novo sem medo: quem já recebeu é pulado.
--
-- Antes: publique as funções "caixa" e "boas-vindas" com o código novo (Edge Functions › Code › cole › Deploy).
--
-- PASSO 1 · rode este arquivo inteiro até a linha "PASSO 2". Ele cria a tabela e as funções.
-- PASSO 2 · TESTE: rode só o bloco do PASSO 2. Vai só pra você (admins). Confira o e-mail e a notificação.
-- PASSO 3 · PRA TODAS: rode só o bloco do PASSO 3. Ele liga o envio automático: vai mandando sozinho, aos poucos,
--           e se desliga quando todas receberem.

create table if not exists public.news_sent (
  user_id uuid not null references auth.users on delete cascade,
  news    text not null,
  mail    boolean not null default false,
  pushes  int not null default 0,
  sent_at timestamptz not null default now(),
  primary key (user_id, news)
);
alter table public.news_sent enable row level security;
revoke all on public.news_sent from anon, authenticated;

-- quem recebe: todas as contas (menos admins) que ainda não receberam essa novidade. No teste: só as admins.
create or replace function public.news_feed(p_news text, p_test boolean, p_limit int)
returns table (user_id uuid, name text, email text)
language sql stable security definer set search_path = ''
as $$
  select u.id,
    coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', split_part(u.email, '@', 1))::text,
    u.email::text
  from auth.users u
  left join public.profiles pr on pr.user_id = u.id
  where u.email is not null
    and case when p_test then exists (select 1 from private.admins a where a.user_id = u.id)
             else not exists (select 1 from private.admins a where a.user_id = u.id)
                  and not exists (select 1 from public.news_sent n where n.user_id = u.id and n.news = p_news) end
  order by u.created_at
  limit greatest(1, least(p_limit, 500))
$$;
revoke all on function public.news_feed(text, boolean, int) from public, anon, authenticated;
grant execute on function public.news_feed(text, boolean, int) to service_role;

create or replace function public.news_left(p_news text)
returns int language sql stable security definer set search_path = ''
as $$
  select count(*)::int from auth.users u
  where u.email is not null
    and not exists (select 1 from private.admins a where a.user_id = u.id)
    and not exists (select 1 from public.news_sent n where n.user_id = u.id and n.news = p_news)
$$;
revoke all on function public.news_left(text) from public, anon, authenticated;
grant execute on function public.news_left(text) to service_role;


-- PASSO 2 · TESTE (só pra você) -------------------------------------------------------------------------
select net.http_post(
  url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
  headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
  body := jsonb_build_object('action', 'novidade', 'news', 'metricas', 'teste', true, 'key', (select cron from private.mail_key where id = 1)),
  timeout_milliseconds := 60000);
-- pra ver o resultado, espere uns segundos e rode:  select status_code, content from net._http_response order by created desc limit 1;


-- PASSO 3 · PRA TODAS AS CREATORS, NO AUTOMÁTICO ------------------------------------------------------
-- Liga um envio automático: das 9h às 19h (Brasília), a cada 2 horas, manda pra mais 60 creators.
-- São até 360 por dia (dentro do limite do Gmail). Quando todas receberem, o agendador se desliga sozinho.
-- Você não precisa fazer mais nada. Tire os "-- " do começo das linhas abaixo e rode só esse bloco.
-- select cron.unschedule('novidade-metricas') where exists (select 1 from cron.job where jobname = 'novidade-metricas');
-- select cron.schedule('novidade-metricas', '13 12-23/2 * * *', $cron$
--   select case when public.news_left('metricas') = 0
--     then (select cron.unschedule('novidade-metricas'))::text
--     else (select net.http_post(
--       url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
--       headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
--       body := jsonb_build_object('action', 'novidade', 'news', 'metricas', 'key', (select cron from private.mail_key where id = 1)),
--       timeout_milliseconds := 300000))::text end;
-- $cron$);
--
-- Pra acompanhar quantas já receberam:  select count(*) filter (where mail) e_mails, sum(pushes) notificacoes, count(*) pessoas from public.news_sent where news = 'metricas';
-- Pra parar antes da hora:               select cron.unschedule('novidade-metricas');
