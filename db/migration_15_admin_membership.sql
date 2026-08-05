-- ============================================================
-- Migration 15 – Admins sind automatisch UNBEGRENZTE Mitglieder
--
-- Jeder Admin bekommt in seinem Club eine members-Zeile mit
-- active=true, valid_until=NULL (= unbegrenzt gültig).
--   * head_admin (club_id NULL): Mitglied in ALLEN Clubs
--   * club_admin: Mitglied in seinem club_id
-- Gilt für Bestand (Backfill) und automatisch für neue Admins/Clubs (Trigger).
-- Alle Mitglieds-Prüfungen (create_booking, Konto, Buchungsseite, Preise)
-- lesen die members-Tabelle, daher wirkt das überall konsistent.
-- ============================================================

-- Eine (Club, E-Mail) als unbegrenztes aktives Mitglied sicherstellen.
create or replace function public._ensure_member(p_club uuid, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(coalesce(p_email,'')));
begin
  if v_email = '' or p_club is null then return; end if;
  update members set active = true, valid_until = null
    where club_id = p_club and lower(email) = v_email;
  if not found then
    insert into members(club_id, email, active, valid_until)
      values (p_club, v_email, true, null)
      on conflict (club_id, email) do update set active = true, valid_until = null;
  end if;
end $$;
revoke all on function public._ensure_member(uuid, text) from public;

-- Mitgliedschaft(en) für einen Admin je nach Rolle sicherstellen.
create or replace function public._sync_admin_membership(p_email text, p_role text, p_club uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_role = 'head_admin' then
    perform public._ensure_member(c.id, p_email) from clubs c;      -- alle Clubs
  elsif p_club is not null then
    perform public._ensure_member(p_club, p_email);
  end if;
end $$;
revoke all on function public._sync_admin_membership(text, text, uuid) from public;

-- Trigger: neuer/geänderter Admin -> Mitgliedschaft sicherstellen.
create or replace function public._trg_admin_membership()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._sync_admin_membership(new.email, new.role, new.club_id);
  return new;
end $$;
drop trigger if exists admin_membership_sync on public.app_admins;
create trigger admin_membership_sync after insert or update on public.app_admins
  for each row execute function public._trg_admin_membership();

-- Trigger: neuer Club -> alle head_admins werden dort Mitglied.
create or replace function public._trg_club_head_membership()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._ensure_member(new.id, a.email)
    from app_admins a where a.role = 'head_admin';
  return new;
end $$;
drop trigger if exists club_head_membership on public.clubs;
create trigger club_head_membership after insert on public.clubs
  for each row execute function public._trg_club_head_membership();

-- Backfill für alle bestehenden Admins.
select public._sync_admin_membership(email, role, club_id) from app_admins;

notify pgrst, 'reload schema';
