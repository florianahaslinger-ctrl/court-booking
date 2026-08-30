-- ============================================================
-- Migration 27 – Admin-verwaltete Abos (Feature manual_abo, RV Wiking)
--
-- In manchen Clubs werden Abos NICHT online im Self-Service gebucht,
-- sondern der/die Zuständige trägt sie persönlich ein und legt dabei
-- einen Preis fest sowie eine Stundenzahl ODER ein Enddatum.
--
-- admin_create_abo: nur für Club-Verwaltung (manages_club). Legt das Abo
-- für ein Mitglied (oder einen Gast) an, erzeugt sofort die komplette
-- Serie und verteilt den festgelegten Gesamtpreis gleichmäßig auf die
-- Termine. Optional direkt als bezahlt markieren (Zahlung in Persona).
-- ============================================================

create or replace function public.admin_create_abo(
  p_club_slug text, p_court uuid, p_weekday int, p_start_time time, p_duration_minutes int,
  p_member_id uuid default null, p_guest_name text default null, p_guest_email text default null,
  p_valid_from date default null, p_valid_until date default null, p_total_hours numeric default null,
  p_price numeric default 0, p_paid boolean default false
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_club clubs; v_court courts; v_member members;
  d date; v_from date; v_until date; v_sessions int; v_id uuid; v_mode text; v_status text;
  v_price numeric := round(coalesce(p_price,0),2); v_n int; v_per numeric;
begin
  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  if not manages_club(v_club.id) then raise exception 'Keine Berechtigung.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;
  if p_weekday < 0 or p_weekday > 6 then raise exception 'Ungültiger Wochentag.'; end if;
  if p_duration_minutes <= 0 then raise exception 'Ungültige Dauer.'; end if;

  v_from := greatest(coalesce(p_valid_from, current_date), current_date);

  if p_total_hours is not null and p_total_hours > 0 then
    v_sessions := ceil(p_total_hours * 60.0 / p_duration_minutes)::int;
    if v_sessions < 1 then v_sessions := 1; end if;
    if v_sessions > 520 then raise exception 'Maximal 520 Termine (~10 Jahre) pro Abo.'; end if;
    d := v_from;
    while extract(dow from d)::int <> p_weekday loop d := d + 1; end loop;
    v_from := d; v_until := d + (7 * (v_sessions - 1));
  else
    if p_valid_until is null then raise exception 'Bitte Enddatum oder Stundenkontingent angeben.'; end if;
    if p_valid_until < v_from then raise exception 'Enddatum vor Startdatum.'; end if;
    v_until := p_valid_until;
  end if;

  if p_member_id is not null then
    select * into v_member from members where id = p_member_id and club_id = v_club.id;
    if not found then raise exception 'Mitglied nicht gefunden.'; end if;
  else
    if coalesce(nullif(trim(p_guest_name),''),'') = '' then
      raise exception 'Bitte Mitglied wählen oder Namen angeben.';
    end if;
  end if;

  v_mode := coalesce(v_club.abo_payment_mode, 'series');
  v_status := case when v_price <= 0 or p_paid then 'paid' else 'unpaid' end;

  insert into subscriptions(club_id, member_id, court_id, weekday, start_time, duration_minutes,
        valid_from, valid_until, guest_name, guest_email, price, price_override, payment_mode, payment_status, created_by)
    values (v_club.id, p_member_id, v_court.id, p_weekday, p_start_time, p_duration_minutes,
        v_from, v_until,
        case when p_member_id is null then p_guest_name end,
        case when p_member_id is not null then lower(v_member.email) else lower(nullif(trim(p_guest_email),'')) end,
        v_price, v_price, v_mode, v_status, public.jwt_email())
    returning id into v_id;

  perform public.gen_subscription_bookings_one(v_id);

  -- Festgelegten Gesamtpreis gleichmäßig auf die Termine verteilen + Zahlstatus setzen
  select count(*) into v_n from bookings where subscription_id = v_id and kind = 'subscription';
  if v_n > 0 then
    v_per := round(v_price / v_n, 2);
    update bookings set price = v_per,
        payment_status = case when v_status = 'paid' or v_per <= 0 then 'paid' else 'pending' end
      where subscription_id = v_id and kind = 'subscription';
  end if;

  return json_build_object('id', v_id, 'price', v_price, 'sessions', v_n,
                           'valid_from', v_from, 'valid_until', v_until, 'payment_status', v_status);
end $$;
grant execute on function public.admin_create_abo(text,uuid,int,time,int,uuid,text,text,date,date,numeric,numeric,boolean) to authenticated;

-- Feature für RV Wiking aktivieren
update public.clubs set features = features || '{"manual_abo":true}'::jsonb where slug = 'rv-wiking-linz';

notify pgrst, 'reload schema';
