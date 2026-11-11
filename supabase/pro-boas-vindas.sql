-- CriaHub · e-mail automático quando uma conta vira Pro (pagou pelo Asaas ou ganhou de presente)
-- Rode no SQL Editor do Supabase DEPOIS do boas-vindas.sql e do fundadora.sql (pode rodar de novo: nada é duplicado).
--   • quando public.plans passa pra 'pro', o banco chama a função "boas-vindas" com {kind:'pro'}
--   • a função manda o e-mail pelo Gmail do CriaHub e marca o recado "virou Pro" como enviado na aba Momentos
--   • renovação (já era Pro) não manda de novo; a fundadora (admin) nunca recebe

-- quem passa de Grátis pra Pro ganha a data de entrada de hoje (o pagamento antigo não mexia nisso,
-- e o recado "virou Pro" da aba Momentos não aparecia)
create or replace function private.pro_since()
returns trigger language plpgsql set search_path = public
as $$ begin
  if new.plan = 'pro' and old.plan <> 'pro' then new.since := now(); end if;
  return new;
end $$;
drop trigger if exists pro_since on public.plans;
create trigger pro_since before update of plan on public.plans for each row execute function private.pro_since();

create or replace function private.pro_welcome()
returns trigger language plpgsql security definer set search_path = public, private
as $$
declare h private.waitlist_hook; v_email text; v_name text; v_ref text;
begin
  if new.plan <> 'pro' or (tg_op = 'UPDATE' and old.plan = 'pro') then return new; end if;
  if exists (select 1 from private.admins a where a.user_id = new.user_id) then return new; end if;
  v_ref := to_char(new.since, 'YYYY-MM-DD');
  if exists (select 1 from public.moments_done d where d.user_id = new.user_id and d.kind = 'virou_pro' and d.ref = v_ref) then return new; end if;
  select u.email, left(coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', split_part(u.email, '@', 1)), 100)
    into v_email, v_name
    from auth.users u left join public.profiles pr on pr.user_id = u.id where u.id = new.user_id;
  select * into h from private.waitlist_hook where id = 1;
  if h.url is not null and v_email is not null then
    perform net.http_post(
      url     := h.url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', h.secret),
      body    := jsonb_build_object('kind', 'pro', 'user_id', new.user_id, 'email', v_email, 'name', v_name, 'ref', v_ref, 'until', new.until),
      timeout_milliseconds := 30000);
  end if;
  return new;
end $$;

drop trigger if exists pro_welcome on public.plans;
create trigger pro_welcome
  after insert or update of plan on public.plans
  for each row execute function private.pro_welcome();

select 'E-mail automático do Pro ligado ✨' as resultado;
