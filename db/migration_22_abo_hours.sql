-- ============================================================
-- Migration 22 – Abo nach Stundenkontingent
--
-- create_abo kann ein Abo jetzt entweder nach ENDDATUM (wie bisher)
-- ODER nach STUNDENKONTINGENT anlegen. Bei p_total_hours wird die
-- nötige Anzahl gleicher Wochentermine abgeleitet
--   sessions = ceil(gewuenschte_stunden / slot_stunden)
-- und daraus valid_until berechnet. Intern bleibt alles beim Alten
-- (valid_from/valid_until), d.h. Generator, Zahlung, Rechnung, Farben
-- funktionieren unveraendert.
-- ============================================================

-- Alte Signatur entfernen (sonst Overload-Mehrdeutigkeit in PostgREST).
drop function if exists public.create_abo(text,uuid,int,time,int,date,date,text,text);

create or replace function public.create_abo(
  p_club_slug text, p_court uuid, p_weekday int, p_start_time time, p_duration_minutes int,
  p_valid_from date, p_valid_until date default null, p_guest_name text default null,
  p_guest_email text default null, p_total_hours numeric default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_club clubs; v_court courts; v_email text := public.jwt_email(); v_authed boolean := (public.jwt_email() <> '');
  v_member members; v_is_member boolean := false; v_factor numeric; v_total numeric := 0;
  d date; v_from date; v_until date; v_sessions int; v_start timestamptz; v_mode text; v_status text; v_id uuid;
begin
  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;
  if p_weekday < 0 or p_weekday > 6 then raise exception 'Ungültiger Wochentag.'; end if;
  if p_duration_minutes <= 0 then raise exception 'Ungültige Dauer.'; end if;

  v_from := greatest(p_valid_from, current_date);

  if p_total_hours is not null and p_total_hours > 0 then
    -- Stundenkontingent: nötige Terminanzahl aus gewünschten Stunden ableiten.
    v_sessions := ceil(p_total_hours * 60.0 / p_duration_minutes)::int;
    if v_sessions < 1 then v_sessions := 1; end if;
    if v_sessions > 520 then raise exception 'Maximal 520 Termine (~10 Jahre) pro Abo.'; end if;
    -- ersten passenden Wochentag ab v_from suchen, dann N-1 Wochen weiter.
    d := v_from;
    while extract(dow from d)::int <> p_weekday loop d := d + 1; end loop;
    v_from  := d;
    v_until := d + (7 * (v_sessions - 1));
  else
    -- Enddatum-Modus (wie bisher).
    if p_valid_until is null then raise exception 'Bitte Enddatum oder Stundenkontingent angeben.'; end if;
    if p_valid_until < p_valid_from then raise exception 'Enddatum vor Startdatum.'; end if;
    if p_valid_until < current_date then raise exception 'Zeitraum liegt in der Vergangenheit.'; end if;
    v_until := p_valid_until;
  end if;

  if v_authed then
    select * into v_member from members
      where club_id = v_club.id and lower(email) = v_email and active
        and (valid_until is null or valid_until >= current_date);
    if found then v_is_member := true; end if;
  end if;
  if not v_is_member then
    if coalesce(nullif(trim(p_guest_email),''),'') = '' or coalesce(nullif(trim(p_guest_name),''),'') = '' then
      raise exception 'Für Gast-Abos sind Name und E-Mail nötig.';
    end if;
  end if;

  v_factor := case when not v_is_member then 1
    else case (case when v_court.environment='indoor' then v_club.member_pricing_mode_indoor else v_club.member_pricing_mode_outdoor end)
      when 'free' then 0
      when 'discount' then (100 - coalesce(case when v_court.environment='indoor' then v_club.member_discount_percent_indoor else v_club.member_discount_percent_outdoor end,0))::numeric/100
      else 1 end end;

  d := v_from;
  while d <= v_until loop
    if extract(dow from d)::int = p_weekday then
      v_start := (d::text || ' ' || p_start_time::text)::timestamp at time zone v_club.timezone;
      v_total := v_total + public._slot_unit_price(v_club.id, v_court.environment, v_court.price_per_hour, v_start, v_club.timezone, p_duration_minutes) * v_factor;
    end if;
    d := d + 1;
  end loop;
  v_total := round(v_total, 2);

  v_mode := coalesce(v_club.abo_payment_mode, 'series');
  v_status := case when v_total <= 0 then 'paid' else 'unpaid' end;

  insert into subscriptions(club_id, member_id, court_id, weekday, start_time, duration_minutes,
        valid_from, valid_until, guest_name, guest_email, price, payment_mode, payment_status, created_by)
    values (v_club.id, case when v_is_member then v_member.id end, v_court.id, p_weekday, p_start_time, p_duration_minutes,
        v_from, v_until,
        case when v_is_member then null else p_guest_name end,
        case when v_is_member then lower(v_member.email) else lower(p_guest_email) end,
        v_total, v_mode, v_status, nullif(v_email,''))
    returning id into v_id;

  perform public.gen_subscription_bookings(v_club.id, 21);

  return json_build_object('id', v_id, 'price', v_total, 'payment_mode', v_mode,
                           'payment_status', v_status, 'is_member', v_is_member, 'currency', v_club.currency);
end $$;
grant execute on function public.create_abo(text,uuid,int,time,int,date,date,text,text,numeric) to anon, authenticated;

notify pgrst, 'reload schema';
