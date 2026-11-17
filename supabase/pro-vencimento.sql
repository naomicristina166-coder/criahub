-- =============== LEMBRETE DO PRO VENCENDO (no automático, junto com os Momentos) ===============
-- Entram dois momentos novos na lista que já sai sozinha todo dia às 10h (e-mail + notificação):
--   • pro_vence  → 3 dias antes do vencimento: "Seu Pro vence dia X"
--   • pro_venceu → no dia seguinte ao vencimento, se ela não renovou: "Seu Pro venceu"
-- Cada lembrete sai uma vez por vencimento. Se ela renovar, a data muda e o lembrete passa a valer pro próximo.
-- Eles também aparecem no Painel › Momentos, como os outros, até saírem.
-- Antes: publique as funções caixa e boas-vindas com o código novo. Depois rode este arquivo inteiro no SQL Editor.
-- (Ele só substitui a função private.moments_feed; o resto dos Momentos continua igual.)

create or replace function private.moments_feed()
returns table (user_id uuid, name text, email text, whatsapp text, instagram text, kind text, ref text, happened date, detail text)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  return query
  with ev as (
    -- 1ª marca cadastrada
    select i.user_id, 'primeira_marca'::text kind, ''::text ref, min(private.dt(i.data->>'created', i.updated_at)) happened, count(*)::text detail
      from public.items i where i.col = 'brands' and coalesce(i.data->>'example', '') <> 'true' group by i.user_id
    union all
    -- 1º vídeo no ar
    select i.user_id, 'primeiro_video', '', min((i.updated_at at time zone 'America/Sao_Paulo')::date), count(*)::text
      from public.items i where i.col = 'deliveries' and i.data->>'stage' = '5' and coalesce(i.data->>'example', '') <> 'true' group by i.user_id
    union all
    -- 1º pagamento recebido de marca
    select i.user_id, 'primeiro_pagamento', '', min(private.dt(i.data->>'paidAt', i.updated_at)), count(*)::text
      from public.items i where i.col = 'payments' and i.data->>'paid' = 'true' and coalesce(i.data->>'example', '') <> 'true' group by i.user_id
    union all
    -- 30 dias de CriaHub
    select u.id, '30_dias', '', (u.created_at at time zone 'America/Sao_Paulo')::date + 30, null
      from auth.users u
    union all
    -- aniversário (dia e mês, nos próximos 7 dias)
    select p.user_id, 'aniversario', extract(year from private.next_bday(p.data->>'bday', hoje))::text, private.next_bday(p.data->>'bday', hoje), null
      from public.profiles p where private.next_bday(p.data->>'bday', hoje) is not null
    union all
    -- virou Pro
    select pl.user_id, 'virou_pro', to_char(pl.since, 'YYYY-MM-DD'), (pl.since at time zone 'America/Sao_Paulo')::date, pl.note
      from public.plans pl where pl.plan = 'pro' and pl.since is not null
    union all
    -- Pro vence em 3 dias (ref = a data de vencimento: renovou, a data muda e o lembrete volta a valer pro próximo)
    select pl.user_id, 'pro_vence', pl.until::text, pl.until - 3, null
      from public.plans pl where pl.plan = 'pro' and pl.until is not null
    union all
    -- Pro venceu ontem e não renovou
    select pl.user_id, 'pro_venceu', pl.until::text, pl.until + 1, null
      from public.plans pl where pl.plan = 'pro' and pl.until is not null
    union all
    -- sumiu há 7+ dias (usou pelo menos 3 dias antes)
    select x.user_id, 'sumida', max(x.day)::text, max(x.day) + 7, count(distinct x.day)::text
      from public.usage_days x group by x.user_id having count(distinct x.day) >= 3
  )
  select ev.user_id,
    coalesce(nullif(pr.data->>'name', ''), u.raw_user_meta_data->>'name', w.name, split_part(u.email, '@', 1))::text,
    u.email::text, coalesce(nullif(pr.data->>'wa', ''), nullif(u.raw_user_meta_data->>'whatsapp', ''), w.whatsapp)::text,
    coalesce(nullif(pr.data->>'ig', ''), nullif(ltrim(pr.data#>>'{kit,ig}', '@'), ''), nullif(ltrim(w.instagram, '@'), ''))::text,
    ev.kind, ev.ref, ev.happened, ev.detail
  from ev
  join auth.users u on u.id = ev.user_id
  left join public.profiles pr on pr.user_id = ev.user_id
  left join lateral (select * from public.waitlist w0 where lower(w0.email) = lower(u.email) limit 1) w on true
  where not exists (select 1 from private.admins a where a.user_id = ev.user_id)
    and not exists (select 1 from public.moments_done d where d.user_id = ev.user_id and d.kind = ev.kind and d.ref = ev.ref)
    and case when ev.kind = 'aniversario' then ev.happened between hoje and hoje + 7
             when ev.kind = 'sumida' then ev.happened <= hoje and ev.happened > hoje - 14
             when ev.kind = 'pro_vence' then hoje between ev.happened and ev.happened + 3
             when ev.kind = 'pro_venceu' then ev.happened <= hoje and ev.happened > hoje - 7
             else ev.happened between hoje - 14 and hoje end
  order by case when ev.kind = 'aniversario' then 0 else 1 end, ev.happened desc;
end $$;
