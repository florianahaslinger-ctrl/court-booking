-- ============================================================
-- Migration 30 – Turnier: Klarname automatisch aus dem Mitgliedskonto
--
-- Nur Clubmitglieder dürfen mitspielen; ihr Klarname steht bereits im
-- Mitgliedskonto (members.full_name, vom Admin angelegt). Die Anmeldung soll
-- den Namen NICHT mehr abfragen/überschreiben – nur die ITN wird selbst
-- eingegeben. Daher tournament_register ohne p_name.
-- ============================================================

drop function if exists public.tournament_register(uuid, text, text);

create or replace function public.tournament_register(p_tournament_id uuid, p_itn text default null)
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

  insert into tournament_participants(tournament_id, club_id, member_id, itn)
    values (p_tournament_id, v_club, v_member, nullif(trim(p_itn),''))
    on conflict (tournament_id, member_id) do update set itn = excluded.itn;
end $$;

grant execute on function public.tournament_register(uuid, text) to authenticated;

notify pgrst, 'reload schema';
