-- ============================================================
-- Migration 02 – Stripe-Zahlung / Zahlungs-Hold
-- Gäste-Buchungen mit Preis > 0 sind bis zur Zahlung nur reserviert
-- ("hold"). Abgebrochene Checkouts geben den Platz nach Ablauf wieder frei.
-- ============================================================

alter table public.bookings add column if not exists hold_expires_at timestamptz;

-- Öffentliche Belegung: abgelaufene, unbezahlte Reservierungen NICHT als belegt zeigen
create or replace view public.court_busy
with (security_invoker = off) as
  select court_id, club_id, start_at, end_at
  from public.bookings
  where status <> 'cancelled'
    and not (payment_status = 'pending'
             and hold_expires_at is not null
             and hold_expires_at < now());
grant select on public.court_busy to anon, authenticated;

-- create_booking neu: räumt abgelaufene Holds weg und setzt bei Gäste-
-- Zahlbuchungen ein Ablaufdatum (20 Min bis zur Zahlung).
create or replace function public.create_booking(
  p_club_slug   text,
  p_court       uuid,
  p_start       timestamptz,
  p_end         timestamptz,
  p_guest_name  text default null,
  p_guest_email text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_club    clubs;
  v_court   courts;
  v_email   text := public.jwt_email();
  v_member  members;
  v_is_member boolean := false;
  v_minutes int;
  v_max     int;
  v_price   numeric(10,2);
  v_kind    text;
  v_payment text;
  v_status  text;
  v_hold    timestamptz := null;
  v_id      uuid;
begin
  -- abgelaufene, unbezahlte Reservierungen freigeben
  delete from bookings
    where status = 'pending' and payment_status = 'pending'
      and hold_expires_at is not null and hold_expires_at < now();

  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;

  if p_end <= p_start then raise exception 'Ungültiger Zeitraum.'; end if;
  if p_start < now() then raise exception 'Startzeit liegt in der Vergangenheit.'; end if;

  v_minutes := (extract(epoch from (p_end - p_start)) / 60)::int;

  if v_email <> '' then
    select * into v_member from members
      where club_id = v_club.id and lower(email) = v_email and active
        and (valid_until is null or valid_until >= current_date);
    if found then v_is_member := true; end if;
  end if;

  v_max := 24 * 60;
  if v_is_member and v_club.member_pricing_mode = 'free' then
    v_max := v_club.member_free_max_minutes;
  end if;
  if v_minutes > v_max then
    raise exception 'Maximale Buchungsdauer: % Minuten.', v_max;
  end if;

  perform 1 from opening_hours oh
    where oh.club_id = v_club.id
      and oh.weekday = extract(dow from (p_start at time zone v_club.timezone))::int
      and not oh.closed
      and (p_start at time zone v_club.timezone)::time >= oh.open_time
      and (p_end   at time zone v_club.timezone)::time <= oh.close_time;
  if not found then raise exception 'Außerhalb der Öffnungszeiten.'; end if;

  if v_is_member then
    v_kind := 'member';
    case v_club.member_pricing_mode
      when 'free'     then v_price := 0;
      when 'discount' then v_price := round(v_court.price_per_hour * v_minutes/60.0
                                            * (1 - v_club.member_discount_percent/100.0), 2);
      else                 v_price := round(v_court.price_per_hour * v_minutes/60.0, 2);
    end case;
  else
    v_kind := 'guest';
    v_price := round(v_court.price_per_hour * v_minutes/60.0, 2);
  end if;

  if v_price = 0 then
    v_status := 'confirmed'; v_payment := 'none';
  else
    v_status := 'pending';   v_payment := 'pending';
    v_hold := now() + interval '35 minutes';  -- Reservierung bis zur Zahlung (Fallback zur Stripe-Session)
  end if;

  insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                       member_id, guest_name, guest_email, price, payment_status, hold_expires_at)
    values (v_club.id, v_court.id, v_kind, v_status, p_start, p_end,
            case when v_is_member then v_member.id end,
            case when v_is_member then null else p_guest_name end,
            case when v_is_member then v_member.email else p_guest_email end,
            v_price, v_payment, v_hold)
    returning id into v_id;

  return json_build_object('id', v_id, 'price', v_price, 'status', v_status,
                           'is_member', v_is_member, 'kind', v_kind, 'currency', v_club.currency);
exception
  when exclusion_violation then raise exception 'Dieser Slot ist inzwischen belegt – bitte anderen wählen.';
end $$;

grant execute on function public.create_booking(text,uuid,timestamptz,timestamptz,text,text)
  to anon, authenticated;

notify pgrst, 'reload schema';
