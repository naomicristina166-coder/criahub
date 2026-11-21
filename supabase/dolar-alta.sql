-- =============== AVISO: O DÓLAR SUBIU ===============
-- Nos dias úteis, das 10h às 17h (Brasília), de hora em hora, a função "caixa" confere a cotação do dólar.
-- Se ele subiu 1% ou mais no dia, avisa no celular quem tem ganhos em dólar cadastrados
-- (marca, pagamento ou outra renda em US$). No máximo UM aviso por dia. Quem desligou na aba US$ não recebe.
--
-- Antes: publique a função "caixa" com o código novo (Edge Functions › caixa › Code › cole › Deploy).
-- PASSO 1 · rode este arquivo inteiro até a linha "PASSO 2". Ele cria a tabela, a função e liga o agendador.
-- PASSO 2 · TESTE (só pra você): rode só o bloco do PASSO 2. Chega no seu celular um aviso de teste com a cotação de agora.
-- Pra mudar o quanto o dólar precisa subir: troque o 1.0 em 'min' (ex.: 0.5 = meio por cento) e rode o PASSO 1 de novo.

-- dias em que o aviso já saiu (só a função lê e escreve)
create table if not exists public.fx_alerts (
  day        date primary key,
  rate       numeric not null,
  pct        numeric not null,
  users      int,
  sent       int,
  created_at timestamptz not null default now()
);
alter table public.fx_alerts enable row level security;
revoke all on public.fx_alerts from anon, authenticated;

-- quem recebe: tem ganho em dólar cadastrado (sem contar os exemplos), não desligou o aviso e ligou as notificações.
-- No teste: só as admins.
create or replace function public.fx_usd_users(p_test boolean)
returns table (user_id uuid)
language sql stable security definer set search_path = ''
as $$
  select s.user_id from public.push_subs s
  where case when p_test then exists (select 1 from private.admins a where a.user_id = s.user_id)
    else exists (select 1 from public.items i
                 where i.user_id = s.user_id and i.col in ('brands', 'payments', 'extras')
                   and i.data->>'currency' = 'USD' and coalesce(i.data->>'example', '') <> 'true')
         and not exists (select 1 from public.profiles p where p.user_id = s.user_id and p.data->>'fxAlert' = 'off') end
  group by s.user_id
$$;
revoke all on function public.fx_usd_users(boolean) from public, anon, authenticated;
grant execute on function public.fx_usd_users(boolean) to service_role;

-- agendador: segunda a sexta, das 10h às 17h de Brasília (13h às 20h UTC), aos 23 minutos de cada hora
select cron.unschedule('dolar-alta') where exists (select 1 from cron.job where jobname = 'dolar-alta');
select cron.schedule('dolar-alta', '23 13-20 * * 1-5', $cron$
  select net.http_post(
    url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
    body := jsonb_build_object('action', 'dolar', 'min', 1.0, 'key', (select cron from private.mail_key where id = 1)),
    timeout_milliseconds := 120000);
$cron$);

select jobname, schedule from cron.job where jobname = 'dolar-alta';


-- PASSO 2 · TESTE (só pra você) -------------------------------------------------------------------------
select net.http_post(
  url := 'https://dvzfllqcgozecvhodygz.supabase.co/functions/v1/caixa',
  headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F', 'Authorization', 'Bearer sb_publishable_a-svz0y1Hv6AaeP3J7om9g_Qot6D66F'),
  body := jsonb_build_object('action', 'dolar', 'min', 1.0, 'teste', true, 'key', (select cron from private.mail_key where id = 1)),
  timeout_milliseconds := 60000);
-- pra ver o resultado, espere uns segundos e rode:  select status_code, content from net._http_response order by created desc limit 1;
--
-- Pra ver os dias em que o aviso saiu:  select * from public.fx_alerts order by day desc;
-- Pra desligar de vez:                 select cron.unschedule('dolar-alta');
