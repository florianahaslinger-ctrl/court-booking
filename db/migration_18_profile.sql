-- ============================================================
-- Migration 18 – Profildaten bei der Registrierung (Telefon + Geburtsdatum)
--
-- members.phone existiert bereits; neu: birthdate.
-- register_profile(): fuellt/aktualisiert die eigene members-Zeile mit
-- Kontaktdaten (aus den Auth-Metadaten). Legt sie bei Bedarf INAKTIV an
-- (keine automatische Mitgliedschaft) und verknuepft auth_uid.
-- Wird nach dem Login von konto.html aufgerufen (Session vorhanden).
-- ============================================================

alter table public.members add column if not exists birthdate date;

create or replace function public.register_profile(
  p_club_slug text,
  p_full_name text default null,
  p_phone     text default null,
  p_birthdate date default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_email text := public.jwt_email(); v_uid uuid := auth.uid();
begin
  if v_email = '' then return; end if;
  select id into v_club from clubs where slug = p_club_slug and active;
  if v_club is null then return; end if;

  update members set
      full_name = coalesce(nullif(full_name,''), nullif(p_full_name,'')),
      phone     = coalesce(nullif(phone,''),     nullif(p_phone,'')),
      birthdate = coalesce(birthdate,            p_birthdate),
      auth_uid  = coalesce(auth_uid,             v_uid)
    where club_id = v_club and lower(email) = v_email;

  if not found then
    insert into members(club_id, email, full_name, phone, birthdate, auth_uid, active)
      values (v_club, v_email, nullif(p_full_name,''), nullif(p_phone,''), p_birthdate, v_uid, false)
      on conflict (club_id, email) do nothing;
  end if;
end $$;
grant execute on function public.register_profile(text, text, text, date) to authenticated;

notify pgrst, 'reload schema';
