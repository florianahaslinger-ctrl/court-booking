-- ============================================================
-- Migration 19 – Aboplaner (Gäste/Mitglieder/Admins), Zahlstatus & Farben
--
-- subscriptions wird zum "Abo": auch fuer Gaeste (member_id optional),
-- mit Preis (Summe der Einzeltermine, Admin-Override moeglich), Zahlmodus
-- (ganze Serie ODER pro Woche, club-weit einstellbar) und Zahlstatus.
-- Generierte Buchungen (kind='subscription') erscheinen GELB (offen) und
-- werden GRUEN, sobald bezahlt/als bezahlt markiert.
-- ============================================================

-- --- Schema -------------------------------------------------
alter table public.clubs add column if not exists abo_payment_mode text not null default 'series'
  check (abo_payment_mode in ('series','weekly'));

alter table public.subscriptions alter column member_id drop not null;
alter table public.subscriptions
  add column if not exists guest_name    text,
  add column if not exists guest_email   text,
  add column if not exists price          numeric(10,2) not null default 0,
  add column if not exists price_override numeric(10,2),
  add column if not exists payment_mode   text not null default 'series' check (payment_mode in ('series','weekly')),
  add column if not exists payment_status text not null default 'unpaid' check (payment_status in ('unpaid','paid')),
  add column if not exists due_date       date,
  add column if not exists stripe_session_id text,
  add column if not exists created_by     text;

-- Gaeste duerfen ihr eigenes Abo lesen (per E-Mail) – zusaetzlich zu Managern/Mitgliedern.
drop policy if exists subs_read on public.subscriptions;
create policy subs_read on public.subscriptions for select
  using (manages_club(club_id)
      or lower(coalesce(guest_email,'')) = public.jwt_email()
      or exists (select 1 from members m where m.id = subscriptions.member_id and m.email = public.jwt_email()));

-- club_public: Zahlmodus mitliefern
create or replace view public.club_public
with (security_invoker = off) as
  select id, slug, name, active, timezone, currency, slot_minutes,
         logo_url, primary_color,
         member_pricing_mode, member_discount_percent, member_free_max_minutes,
         booking_open_days, min_lead_minutes, cancel_lead_minutes, stripe_enabled,
         member_pricing_mode_outdoor, member_pricing_mode_indoor,
         member_discount_percent_outdoor, member_discount_percent_indoor,
         member_free_max_minutes_outdoor, member_free_max_minutes_indoor,
         abo_payment_mode
  from public.clubs
  where active;
grant select on public.club_public to anon, authenticated;

-- --- Preis-Helfer ------------------------------------------
-- Platzpreis (ohne Faktor) fuer EINEN Slot: passendes Tarif-Fenster, sonst Platzpreis.
create or replace function public._slot_unit_price(p_club uuid, p_env text, p_court_price numeric,
  p_start timestamptz, p_tz text, p_minutes int)
returns numeric language sql stable security definer set search_path = public as $$
  select round(coalesce(
    (select pw.price_per_hour from price_windows pw
      where pw.club_id = p_club and pw.environment = p_env
        and extract(dow from (p_start at time zone p_tz))::int = any(pw.weekdays)
        and (p_start at time zone p_tz)::time >= pw.start_time
        and (p_start at time zone p_tz)::time <  pw.end_time
      order by (pw.end_time - pw.start_time) asc, pw.sort asc limit 1),
    p_court_price) * p_minutes / 60.0, 2)
$$;

-- --- Generator: erzeugt Abo-Buchungen mit Preis + Zahlstatus ---
create or replace function public.gen_subscription_bookings(p_club uuid default null, p_days int default 21)
returns int language plpgsql security definer set search_path = public as $$
declare
  s record; d date; d0 date := current_date; created int := 0;
  v_start timestamptz; v_end timestamptz;
  v_is_member boolean; v_factor numeric; v_unit numeric; v_price numeric; v_pay text;
begin
  for s in
    select sub.*, c.timezone as club_tz, co.environment as court_env, co.price_per_hour as court_price,
           case when co.environment='indoor' then c.member_pricing_mode_indoor    else c.member_pricing_mode_outdoor    end as mmode,
           case when co.environment='indoor' then c.member_discount_percent_indoor else c.member_discount_percent_outdoor end as mdisc
    from subscriptions sub
    join clubs c   on c.id  = sub.club_id
    join courts co on co.id = sub.court_id
    where sub.active and (p_club is null or sub.club_id = p_club)
  loop
    v_is_member := s.member_id is not null and exists (select 1 from members m where m.id = s.member_id and m.active);
    v_factor := case when not v_is_member then 1
                     else case s.mmode when 'free' then 0
                                       when 'discount' then (100 - coalesce(s.mdisc,0))::numeric / 100
                                       else 1 end end;
    d := greatest(d0, s.valid_from);
    while d <= least(s.valid_until, d0 + p_days) loop
      if extract(dow from d)::int = s.weekday then
        v_start := (d::text || ' ' || s.start_time::text)::timestamp at time zone s.club_tz;
        v_end   := v_start + make_interval(mins => s.duration_minutes);
        if not exists (select 1 from bookings b where b.subscription_id = s.id and b.start_at = v_start) then
          v_unit  := public._slot_unit_price(s.club_id, s.court_env, s.court_price, v_start, s.club_tz, s.duration_minutes);
          v_price := round(v_unit * v_factor, 2);
          v_pay := case when v_price <= 0 then 'paid'
                        when s.payment_mode = 'series' then (case when s.payment_status = 'paid' then 'paid' else 'pending' end)
                        else 'pending' end;
          begin
            insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                                 member_id, guest_name, guest_email, price, payment_status, subscription_id)
            values (s.club_id, s.court_id, 'subscription', 'confirmed', v_start, v_end,
                    s.member_id, s.guest_name, s.guest_email, v_price, v_pay, s.id);
            created := created + 1;
          exception when exclusion_violation then null;  -- Slot belegt -> ueberspringen
          end;
        end if;
      end if;
      d := d + 1;
    end loop;
  end loop;
  return created;
end $$;
revoke execute on function public.gen_subscription_bookings(uuid,int) from public;

-- --- Abo anlegen (Gast/Mitglied/Admin) ---------------------
create or replace function public.create_abo(
  p_club_slug text, p_court uuid, p_weekday int, p_start_time time, p_duration_minutes int,
  p_valid_from date, p_valid_until date, p_guest_name text default null, p_guest_email text default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_club clubs; v_court courts; v_email text := public.jwt_email(); v_authed boolean := (public.jwt_email() <> '');
  v_member members; v_is_member boolean := false; v_factor numeric; v_total numeric := 0;
  d date; v_from date; v_start timestamptz; v_mode text; v_status text; v_id uuid;
begin
  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;
  if p_weekday < 0 or p_weekday > 6 then raise exception 'Ungültiger Wochentag.'; end if;
  if p_duration_minutes <= 0 then raise exception 'Ungültige Dauer.'; end if;
  if p_valid_until < p_valid_from then raise exception 'Enddatum vor Startdatum.'; end if;
  if p_valid_until < current_date then raise exception 'Zeitraum liegt in der Vergangenheit.'; end if;

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

  v_from := greatest(p_valid_from, current_date);
  d := v_from;
  while d <= p_valid_until loop
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
        v_from, p_valid_until,
        case when v_is_member then null else p_guest_name end,
        case when v_is_member then lower(v_member.email) else lower(p_guest_email) end,
        v_total, v_mode, v_status, nullif(v_email,''))
    returning id into v_id;

  perform public.gen_subscription_bookings(v_club.id, 21);

  return json_build_object('id', v_id, 'price', v_total, 'payment_mode', v_mode,
                           'payment_status', v_status, 'is_member', v_is_member, 'currency', v_club.currency);
end $$;
grant execute on function public.create_abo(text,uuid,int,time,int,date,date,text,text) to anon, authenticated;

-- --- Als bezahlt markieren (Admin) -------------------------
create or replace function public.abo_mark_paid(p_sub uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid;
begin
  select club_id into v_club from subscriptions where id = p_sub;
  if v_club is null then raise exception 'Abo nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  update subscriptions set payment_status = 'paid' where id = p_sub;
  update bookings set payment_status = 'paid'
    where subscription_id = p_sub and kind = 'subscription' and payment_status <> 'paid';
end $$;
grant execute on function public.abo_mark_paid(uuid) to authenticated;

-- Einzelnen Wochentermin als bezahlt markieren (Zahlmodus 'weekly')
create or replace function public.abo_booking_mark_paid(p_booking uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid;
begin
  select club_id into v_club from bookings where id = p_booking and kind = 'subscription';
  if v_club is null then raise exception 'Buchung nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  update bookings set payment_status = 'paid' where id = p_booking;
end $$;
grant execute on function public.abo_booking_mark_paid(uuid) to authenticated;

-- --- Belegungs-View: Abo-Farben (gelb offen / gruen bezahlt) ---
create or replace view public.court_busy
with (security_invoker = off) as
  select
    b.court_id, b.club_id, b.start_at, b.end_at,
    case
      when public.manages_club(b.club_id)
        or exists (select 1 from public.members m
                   where m.club_id = b.club_id and lower(m.email) = public.jwt_email() and m.active)
      then
        (case b.kind
          when 'block'        then coalesce(bt.name, nullif(b.note,''), 'Gesperrt')
          when 'subscription' then coalesce((select full_name from public.members m where m.id = b.member_id), b.guest_name, b.note, 'Abo')
          when 'member'       then coalesce((select full_name from public.members m where m.id = b.member_id), b.guest_name, 'Mitglied')
          when 'free'         then coalesce(bt.name, nullif(b.note,''), b.guest_name, 'Reserviert')
          else                     coalesce(b.guest_name, 'Gast')
         end)
        || case when coalesce(b.person_count,1) > 1 then ' +' || (b.person_count - 1) else '' end
      else null
    end as label,
    case when b.kind = 'subscription'
         then (case when b.payment_status = 'paid' or coalesce(b.price,0) = 0 then 'Abo · bezahlt' else 'Abo · offen' end)
         else bt.name end as type_name,
    case when b.kind = 'subscription'
         then (case when b.payment_status = 'paid' or coalesce(b.price,0) = 0 then '#2E8B57' else '#EAB308' end)
         else bt.color end as type_color
  from public.bookings b
  left join public.booking_types bt on bt.id = b.booking_type_id
  where b.status <> 'cancelled'
    and not (b.payment_status = 'pending' and b.hold_expires_at is not null and b.hold_expires_at < now());
grant select on public.court_busy to anon, authenticated;

notify pgrst, 'reload schema';
