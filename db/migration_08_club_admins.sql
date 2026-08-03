-- ============================================================
-- Migration 08 – Mehrere Admins je Club verwalten
-- RPCs mit Berechtigungsprüfung (manages_club). Ein Club-Admin kann
-- weitere Club-Admins für SEINEN Club hinzufügen/entfernen; Head-Admins
-- werden nie überschrieben oder entfernt. Keine Rechte-Eskalation.
-- ============================================================

-- Liste der Club-Admins eines Clubs (nur wer den Club verwaltet)
create or replace function public.club_admins_list(p_club uuid)
returns table(email text, role text)
language sql stable security definer set search_path = public as $$
  select a.email, a.role
  from app_admins a
  where a.club_id = p_club and public.manages_club(p_club)
  order by a.email;
$$;

-- Club-Admin hinzufügen (Head-Admins bleiben unangetastet)
create or replace function public.club_admin_add(p_club uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(coalesce(p_email,'')));
begin
  if not public.manages_club(p_club) then raise exception 'Keine Berechtigung für diesen Club.'; end if;
  if v_email = '' then raise exception 'E-Mail nötig.'; end if;
  if exists (select 1 from app_admins where email = v_email and role = 'head_admin') then
    raise exception 'Diese E-Mail ist bereits Head-Admin.';
  end if;
  insert into app_admins(email, role, club_id)
    values (v_email, 'club_admin', p_club)
    on conflict (email) do update set role = 'club_admin', club_id = p_club;
end $$;

-- Club-Admin entfernen (nur club_admin dieses Clubs)
create or replace function public.club_admin_remove(p_club uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.manages_club(p_club) then raise exception 'Keine Berechtigung für diesen Club.'; end if;
  delete from app_admins
    where lower(email) = lower(trim(p_email)) and club_id = p_club and role = 'club_admin';
end $$;

grant execute on function public.club_admins_list(uuid) to authenticated;
grant execute on function public.club_admin_add(uuid, text) to authenticated;
grant execute on function public.club_admin_remove(uuid, text) to authenticated;

notify pgrst, 'reload schema';
