-- CriaHub · comissão das afiliadas (regra de 27/11/2026)
-- Todas começam com 20% enquanto a indicada pagar. Quem chegar a 10 indicadas no Pro sobe pra 25%.
-- As Crias Beta continuam marcadas como "Cria Beta" (pra aparecer como fundadora), mas com 20%.
-- Pode rodar de novo sem medo.

create or replace function public.admin_aff_make(p_user uuid, p_code text, p_beta boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_code text := lower(regexp_replace(trim(coalesce(p_code, '')), '[^a-zA-Z0-9_-]', '', 'g'));
begin
  perform private.must_admin();
  if char_length(v_code) < 2 then raise exception 'Escolha um código com pelo menos 2 letras (sem espaço nem acento).'; end if;
  if exists (select 1 from public.affiliates where code = v_code and user_id <> p_user) then raise exception 'Esse código já é de outra afiliada.'; end if;
  insert into public.affiliates (user_id, code, rate_first, first_months, rate_after, note)
    values (p_user, v_code, 20, 12, 20, case when p_beta then 'Cria Beta' else null end)
    on conflict (user_id) do update set code = excluded.code, active = true,
      note = coalesce(excluded.note, public.affiliates.note);
  return jsonb_build_object('ok', true, 'code', v_code);
end $$;
revoke all on function public.admin_aff_make(uuid, text, boolean) from public, anon;
grant execute on function public.admin_aff_make(uuid, text, boolean) to authenticated;

-- bateu a meta: a fundadora sobe a comissão (vale pros próximos pagamentos)
create or replace function public.admin_aff_rate(p_user uuid, p_rate numeric)
returns void language plpgsql security definer set search_path = ''
as $$ begin
  perform private.must_admin();
  if p_rate not in (20, 25) then raise exception 'Comissão inválida'; end if;
  update public.affiliates set rate_first = p_rate, rate_after = p_rate where user_id = p_user;
end $$;
revoke all on function public.admin_aff_rate(uuid, numeric) from public, anon;
grant execute on function public.admin_aff_rate(uuid, numeric) to authenticated;

-- as afiliadas que já existiam ficam em 20%, sem mudar nada (as que já bateram a meta a fundadora sobe pelo painel)
update public.affiliates set rate_first = 20, rate_after = 20 where rate_first > rate_after;
