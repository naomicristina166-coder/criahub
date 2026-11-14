-- CriaHub · a fundadora exclui uma conta pelo painel (contas de teste, por exemplo). Pode rodar de novo.
-- Apaga a conta e tudo dela (os dados do app saem junto). Opcional: tira o e-mail da lista de espera também.
-- Nunca apaga a conta de quem é admin.
create or replace function public.admin_delete_user(p_user uuid, p_waitlist boolean default true)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_email text;
begin
  perform private.must_admin();
  if p_user = auth.uid() or exists (select 1 from private.admins a where a.user_id = p_user) then
    raise exception 'Essa conta é de admin e não pode ser excluída por aqui.';
  end if;
  select email into v_email from auth.users where id = p_user;
  if v_email is null then return jsonb_build_object('ok', false, 'error', 'conta não encontrada'); end if;
  delete from public.referrals where referred_user = p_user;   -- a chave dela não aceita ficar vazia
  if p_waitlist then delete from public.waitlist where lower(email) = lower(v_email); end if;
  delete from auth.users where id = p_user;
  return jsonb_build_object('ok', true, 'email', v_email);
end $$;
revoke all on function public.admin_delete_user(uuid, boolean) from public, anon;
grant execute on function public.admin_delete_user(uuid, boolean) to authenticated;

select 'Excluir conta pelo painel pronto' as resultado;
