-- ============================================================
-- Migration 29 – Turnier: Klarname + eigene ITN bei der Anmeldung
--
-- 1) tournament_participants.itn (text): ITN, vom Mitglied selbst eingegeben.
-- 2) tournament_register erweitert um p_name (Klarname) + p_itn:
--    - Klarname wird in members.full_name gespeichert (damit überall der Name
--      statt der E-Mail erscheint),
--    - ITN am Teilnehmer gespeichert (hilft dem Admin beim Reihen).
-- ============================================================

alter table public.tournament_participants add column if not exists itn text;

-- Alte Signatur entfernen (sonst PostgREST-Überladung) und neu anlegen
drop function if exists public.tournament_register(uuid);

create or replace function public.tournament_register(p_tournament_id uuid, p_name text default null, p_itn text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_status text; v_deadline timestamptz; v_member uuid;
begin
  select club_id, status, registration_deadline
    into v_club, v_status, v_deadline
    from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if v_status <> 'registration' then raise exception 'Die Anmeldung ist geschlossen.'; end if;
  if v_deadline is not null and now() > v_deadline then raise exception 'Die Anmeldefrist ist abgelaufen.'; end if;
  select id into v_member from members
    where club_id = v_club and lower(email) = jwt_email() and active;
  if v_member is null then raise exception 'Nur aktive Mitglieder können sich anmelden.'; end if;

  -- Klarname setzen/aktualisieren (nur wenn angegeben)
  if coalesce(trim(p_name),'') <> '' then
    update members set full_name = trim(p_name) where id = v_member;
  end if;

  insert into tournament_participants(tournament_id, club_id, member_id, itn)
    values (p_tournament_id, v_club, v_member, nullif(trim(p_itn),''))
    on conflict (tournament_id, member_id) do update set itn = excluded.itn;
end $$;

grant execute on function public.tournament_register(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
