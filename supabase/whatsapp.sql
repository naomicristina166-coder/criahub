-- CriaHub · o painel passa a ver o WhatsApp que a creator colocou no cadastro ou em Ajustes › Perfil
-- (antes só aparecia o da lista de espera). Pode rodar de novo.
-- Troca só a coluna do WhatsApp nas funções admin_users() e admin_moments(), sem mexer no resto delas.
do $$
declare d text; f text;
begin
  foreach f in array array['public.admin_users()', 'public.admin_moments()'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('pr.data->>''wa''' in d) = 0 then
      d := replace(d, 'w.whatsapp::text', 'coalesce(nullif(pr.data->>''wa'', ''''), nullif(u.raw_user_meta_data->>''whatsapp'', ''''), w.whatsapp)::text');
      execute d;
    end if;
  end loop;
end $$;
select 'WhatsApp no painel ✨' as resultado;
