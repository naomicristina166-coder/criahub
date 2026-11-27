-- CriaHub · lista de espera aberta pra todo tipo de creator (UGC, nano, micro e influenciadora)
-- O campo "kind" passa a aceitar várias opções separadas por vírgula (ex.: 'ugc,micro').
-- Pode rodar de novo sem medo.
alter table public.waitlist drop constraint if exists waitlist_kind_check;
alter table public.waitlist add constraint waitlist_kind_check
  check (kind is null or kind ~ '^(ugc|tech|ambos|comecando|nano|micro|influ)(,(ugc|tech|ambos|comecando|nano|micro|influ)){0,6}$');
