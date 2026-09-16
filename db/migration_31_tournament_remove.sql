-- ============================================================
-- Migration 31 – Turnier: Admin kann Teilnehmer entfernen
--
-- Fuer Fehleintragungen / versehentliche Anmeldungen: der Admin kann einen
-- Teilnehmer vor der Auslosung (Status registration/seeding) entfernen.
-- Nach der Auslosung (running) wuerde das den Baum zerreissen -> dann bitte
-- ueber "Neu reihen/auslosen" zuruecksetzen.
-- ============================================================

create or replace function public.tournament_remove_participant(p_tournament_id uuid, p_member_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_status text;
begin
  select club_id, status into v_club, v_status from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  if v_status not in ('registration','seeding') then
    raise exception 'Teilnehmer können nur vor der Auslosung entfernt werden. Bitte zuerst „Neu reihen / auslosen".';
  end if;
  delete from tournament_participants where tournament_id = p_tournament_id and member_id = p_member_id;
end $$;

grant execute on function public.tournament_remove_participant(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
