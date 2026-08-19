-- ============================================================
-- Migration 25 – Jugend-/Altersrabatt (modular pro Club)
--
-- Pro Club einstellbar: Personen UNTER einem Alter (Default 18) zahlen
-- X % weniger (Default 0 = aus). Der Rabatt STAPELT auf den bestehenden
-- Preis (Gastpreis bzw. bereits reduzierter Mitgliederpreis).
-- Grundlage ist das Geburtsdatum: Mitglieder aus members.birthdate,
-- Gaeste aus dem beim Buchen angegebenen Geburtsdatum.
-- Bei Abos wird das Alter je Termin geprueft (falls jemand waehrend der
-- Laufzeit das Alter ueberschreitet).
-- ============================================================

-- 1) Club-Einstellungen ---------------------------------------
alter table public.clubs
  add column if not exists youth_discount_percent numeric(5,2) not null default 0
    check (youth_discount_percent >= 0 and youth_discount_percent <= 100);
alter table public.clubs
  add column if not exists youth_max_age int not null default 18
    check (youth_max_age between 1 and 120);

-- 2) Gast-Geburtsdatum am Abo (fuer Alterspruefung je Termin) --
alter table public.subscriptions add column if not exists guest_birthdate date;

-- 3) Rabatt-Faktor-Helfer -------------------------------------
-- Gibt den Multiplikator (<=1) zurueck: (100-pct)/100 wenn die Person am
-- Stichtag juenger als max_age ist, sonst 1. Ohne Geburtsdatum/Prozent = 1.
create or replace function public._youth_factor(p_pct numeric, p_max_age int, p_birth date, p_on date)
returns numeric language sql immutable set search_path = public as $$
  select case
    when p_birth is null or coalesce(p_pct,0) <= 0 then 1
    when date_part('year', age(coalesce(p_on, current_date), p_birth)) < coalesce(p_max_age,18)
      then (100 - p_pct)::numeric / 100
    else 1 end
$$;

-- 4) club_public: Jugendrabatt-Felder mitliefern --------------
create or replace view public.club_public
with (security_invoker = off) as
  select id, slug, name, active, timezone, currency, slot_minutes,
         logo_url, primary_color,
         member_pricing_mode, member_discount_percent, member_free_max_minutes,
         booking_open_days, min_lead_minutes, cancel_lead_minutes, stripe_enabled,
         member_pricing_mode_outdoor, member_pricing_mode_indoor,
         member_discount_percent_outdoor, member_discount_percent_indoor,
         member_free_max_minutes_outdoor, member_free_max_minutes_indoor,
         abo_payment_mode,
         youth_discount_percent, youth_max_age
  from public.clubs
  where active;
grant select on public.club_public to anon, authenticated;

-- 5) create_booking: Jugendrabatt auf den Bucher --------------
drop function if exists public.create_booking(text,uuid,timestamptz,timestamptz,text,text,jsonb,boolean);
create or replace function public.create_booking(
  p_club_slug text, p_court uuid, p_start timestamptz, p_end timestamptz,
  p_guest_name text default null, p_guest_email text default null,
  p_participants jsonb default '[]'::jsonb, p_use_credit boolean default false,
  p_guest_birthdate date default null
) returns json
language plpgsql security definer set search_path = public as $function$
declare
  v_club    clubs;
  v_court   courts;
  v_email   text := public.jwt_email();
  v_authed  boolean := (public.jwt_email() <> '');
  v_member  members;
  v_is_member boolean := false;
  v_minutes int; v_max int;
  v_kind text; v_payment text; v_status text; v_hold timestamptz := null;
  v_mode text; v_disc int; v_freemax int;
  v_local timestamptz; v_wd int; v_tod time;
  v_rate numeric(10,2); v_unit numeric(10,2);
  v_fac_member numeric; v_booker_fac numeric; v_sum_fac numeric;
  v_share numeric; v_price numeric(10,2);
  v_persons int := 1;
  v_resolved jsonb := '[]'::jsonb;
  v_pp jsonb; v_mid uuid; v_mrow members; v_gname text; v_fac numeric;
  v_pay_email text; v_id uuid;
  v_birth date; v_youth numeric;
begin
  delete from bookings
    where status='pending' and payment_status='pending'
      and hold_expires_at is not null and hold_expires_at < now();

  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;

  if p_end <= p_start then raise exception 'Ungültiger Zeitraum.'; end if;
  if p_start < now() then raise exception 'Startzeit liegt in der Vergangenheit.'; end if;
  v_minutes := (extract(epoch from (p_end - p_start)) / 60)::int;

  if v_authed then
    select * into v_member from members
      where club_id = v_club.id and lower(email) = v_email and active
        and (valid_until is null or valid_until >= current_date);
    if found then v_is_member := true; end if;
  end if;

  if v_court.environment = 'indoor' then
    v_mode := v_club.member_pricing_mode_indoor; v_disc := v_club.member_discount_percent_indoor; v_freemax := v_club.member_free_max_minutes_indoor;
  else
    v_mode := v_club.member_pricing_mode_outdoor; v_disc := v_club.member_discount_percent_outdoor; v_freemax := v_club.member_free_max_minutes_outdoor;
  end if;
  v_fac_member := case v_mode
                    when 'free'     then 0
                    when 'discount' then (100 - coalesce(v_disc,0))::numeric / 100
                    else 1 end;

  v_max := 24 * 60;
  if v_is_member and v_mode = 'free' then v_max := v_freemax; end if;
  if v_minutes > v_max then raise exception 'Maximale Buchungsdauer: % Minuten.', v_max; end if;

  perform 1 from opening_hours oh
    where oh.club_id = v_club.id
      and oh.weekday = extract(dow from (p_start at time zone v_club.timezone))::int
      and not oh.closed
      and (p_start at time zone v_club.timezone)::time >= oh.open_time
      and (p_end   at time zone v_club.timezone)::time <= oh.close_time;
  if not found then raise exception 'Außerhalb der Öffnungszeiten.'; end if;

  v_local := p_start at time zone v_club.timezone;
  v_wd  := extract(dow from v_local)::int;
  v_tod := v_local::time;
  select pw.price_per_hour into v_rate
    from price_windows pw
    where pw.club_id = v_club.id and pw.environment = v_court.environment
      and v_wd = any(pw.weekdays) and v_tod >= pw.start_time and v_tod < pw.end_time
    order by (pw.end_time - pw.start_time) asc, pw.sort asc
    limit 1;
  v_rate := coalesce(v_rate, v_court.price_per_hour);
  v_unit := round(v_rate * v_minutes/60.0, 2);

  v_kind := case when v_is_member then 'member' else 'guest' end;

  -- Jugendrabatt fuer den Bucher (stapelt auf Mitglieder-/Gastpreis)
  v_birth := case when v_is_member then v_member.birthdate else p_guest_birthdate end;
  v_youth := public._youth_factor(v_club.youth_discount_percent, v_club.youth_max_age, v_birth, v_local::date);

  v_booker_fac := (case when v_is_member then v_fac_member else 1 end) * v_youth;
  v_sum_fac := v_booker_fac;

  if p_participants is not null and jsonb_typeof(p_participants) = 'array' then
    for v_pp in select * from jsonb_array_elements(p_participants) loop
      v_persons := v_persons + 1;
      if v_persons > 4 then raise exception 'Maximal 4 Personen pro Buchung.'; end if;
      v_mid := null;
      if v_authed and (v_pp ? 'member_id') and nullif(v_pp->>'member_id','') is not null then
        select * into v_mrow from members
          where id = (v_pp->>'member_id')::uuid and club_id = v_club.id and active
            and (valid_until is null or valid_until >= current_date);
        if found then v_mid := v_mrow.id; end if;
      end if;
      if v_mid is not null then
        v_fac := v_fac_member; v_gname := null;
      else
        v_fac := 1; v_gname := left(coalesce(nullif(v_pp->>'guest_name',''), 'Gast'), 120);
      end if;
      v_sum_fac := v_sum_fac + v_fac;
      v_resolved := v_resolved || jsonb_build_object('member_id', v_mid, 'guest_name', v_gname,
                                                     'is_member', (v_mid is not null), 'fac', v_fac);
    end loop;
  end if;

  v_share := v_unit / v_persons;
  v_price := round(v_unit * v_sum_fac / v_persons, 2);

  v_pay_email := case when v_is_member then lower(v_member.email) else lower(coalesce(p_guest_email,'')) end;
  if v_price = 0 then
    v_status := 'confirmed'; v_payment := 'none';
  elsif p_use_credit then
    if coalesce(v_pay_email,'') = '' then raise exception 'Für Guthaben-Zahlung ist eine E-Mail nötig.'; end if;
    v_status := 'confirmed'; v_payment := 'paid'; v_hold := null;
  else
    v_status := 'pending'; v_payment := 'pending'; v_hold := now() + interval '35 minutes';
  end if;

  insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                       member_id, guest_name, guest_email, price, payment_status, hold_expires_at, person_count)
    values (v_club.id, v_court.id, v_kind, v_status, p_start, p_end,
            case when v_is_member then v_member.id end,
            case when v_is_member then null else p_guest_name end,
            case when v_is_member then v_member.email else p_guest_email end,
            v_price, v_payment, v_hold, v_persons)
    returning id into v_id;

  if p_use_credit and v_price > 0 then
    perform _wallet_apply(v_club.id, v_pay_email, -v_price, 'booking', v_id, 'Buchung', null);
  end if;

  for v_pp in select * from jsonb_array_elements(v_resolved) loop
    insert into booking_participants(booking_id, club_id, member_id, guest_name, is_member, price)
      values (v_id, v_club.id, nullif(v_pp->>'member_id','')::uuid, v_pp->>'guest_name',
              (v_pp->>'is_member')::boolean, round(v_share * (v_pp->>'fac')::numeric, 2));
  end loop;

  return json_build_object('id', v_id, 'price', v_price, 'status', v_status,
                           'is_member', v_is_member, 'kind', v_kind, 'currency', v_club.currency,
                           'persons', v_persons, 'paid_with', case when p_use_credit and v_price>0 then 'credit' when v_price=0 then 'none' else 'card' end);
exception
  when exclusion_violation then raise exception 'Dieser Slot ist inzwischen belegt – bitte anderen wählen.';
end $function$;
grant execute on function public.create_booking(text,uuid,timestamptz,timestamptz,text,text,jsonb,boolean,date) to anon, authenticated;

-- 6) Generatoren: Jugendrabatt je Termin ----------------------
create or replace function public.gen_subscription_bookings(p_club uuid default null, p_days int default 21)
returns int language plpgsql security definer set search_path = public as $$
declare
  s record; d date; d0 date := current_date; created int := 0;
  v_start timestamptz; v_end timestamptz;
  v_is_member boolean; v_factor numeric; v_unit numeric; v_price numeric; v_pay text;
  v_birth date; v_yf numeric;
begin
  for s in
    select sub.*, c.timezone as club_tz, co.environment as court_env, co.price_per_hour as court_price,
           c.youth_discount_percent as ypct, c.youth_max_age as ymax, mb.birthdate as member_birth,
           case when co.environment='indoor' then c.member_pricing_mode_indoor    else c.member_pricing_mode_outdoor    end as mmode,
           case when co.environment='indoor' then c.member_discount_percent_indoor else c.member_discount_percent_outdoor end as mdisc
    from subscriptions sub
    join clubs c   on c.id  = sub.club_id
    join courts co on co.id = sub.court_id
    left join members mb on mb.id = sub.member_id
    where sub.active and (p_club is null or sub.club_id = p_club)
  loop
    v_is_member := s.member_id is not null and exists (select 1 from members m where m.id = s.member_id and m.active);
    v_factor := case when not v_is_member then 1
                     else case s.mmode when 'free' then 0
                                       when 'discount' then (100 - coalesce(s.mdisc,0))::numeric / 100
                                       else 1 end end;
    v_birth := case when v_is_member then s.member_birth else s.guest_birthdate end;
    d := greatest(d0, s.valid_from);
    while d <= least(s.valid_until, d0 + p_days) loop
      if extract(dow from d)::int = s.weekday then
        if not exists (select 1 from bookings b where b.subscription_id = s.id
                         and b.start_at = (d::text || ' ' || s.start_time::text)::timestamp at time zone s.club_tz) then
          v_start := (d::text || ' ' || s.start_time::text)::timestamp at time zone s.club_tz;
          v_end   := v_start + make_interval(mins => s.duration_minutes);
          v_unit  := public._slot_unit_price(s.club_id, s.court_env, s.court_price, v_start, s.club_tz, s.duration_minutes);
          v_yf    := public._youth_factor(s.ypct, s.ymax, v_birth, d);
          v_price := round(v_unit * v_factor * v_yf, 2);
          v_pay := case when v_price <= 0 then 'paid'
                        when s.payment_mode = 'series' then (case when s.payment_status = 'paid' then 'paid' else 'pending' end)
                        else 'pending' end;
          begin
            insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                                 member_id, guest_name, guest_email, price, payment_status, subscription_id)
            values (s.club_id, s.court_id, 'subscription', 'confirmed', v_start, v_end,
                    s.member_id, s.guest_name, s.guest_email, v_price, v_pay, s.id);
            created := created + 1;
          exception when exclusion_violation then null;
          end;
        end if;
      end if;
      d := d + 1;
    end loop;
  end loop;
  return created;
end $$;
revoke execute on function public.gen_subscription_bookings(uuid,int) from public;

create or replace function public.gen_subscription_bookings_one(p_sub uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  s record; d date; d0 date := current_date; created int := 0;
  v_start timestamptz; v_end timestamptz;
  v_is_member boolean; v_factor numeric; v_unit numeric; v_price numeric; v_pay text;
  v_birth date; v_yf numeric;
begin
  select sub.*, c.timezone as club_tz, co.environment as court_env, co.price_per_hour as court_price,
         c.youth_discount_percent as ypct, c.youth_max_age as ymax, mb.birthdate as member_birth,
         case when co.environment='indoor' then c.member_pricing_mode_indoor    else c.member_pricing_mode_outdoor    end as mmode,
         case when co.environment='indoor' then c.member_discount_percent_indoor else c.member_discount_percent_outdoor end as mdisc
    into s
    from subscriptions sub
    join clubs c   on c.id  = sub.club_id
    join courts co on co.id = sub.court_id
    left join members mb on mb.id = sub.member_id
   where sub.id = p_sub and sub.active;
  if not found then return 0; end if;

  v_is_member := s.member_id is not null and exists (select 1 from members m where m.id = s.member_id and m.active);
  v_factor := case when not v_is_member then 1
                   else case s.mmode when 'free' then 0
                                     when 'discount' then (100 - coalesce(s.mdisc,0))::numeric / 100
                                     else 1 end end;
  v_birth := case when v_is_member then s.member_birth else s.guest_birthdate end;
  d := greatest(d0, s.valid_from);
  while d <= s.valid_until loop
    if extract(dow from d)::int = s.weekday then
      v_start := (d::text || ' ' || s.start_time::text)::timestamp at time zone s.club_tz;
      v_end   := v_start + make_interval(mins => s.duration_minutes);
      if not exists (select 1 from bookings b where b.subscription_id = s.id and b.start_at = v_start) then
        v_unit  := public._slot_unit_price(s.club_id, s.court_env, s.court_price, v_start, s.club_tz, s.duration_minutes);
        v_yf    := public._youth_factor(s.ypct, s.ymax, v_birth, d);
        v_price := round(v_unit * v_factor * v_yf, 2);
        v_pay := case when v_price <= 0 then 'paid'
                      when s.payment_mode = 'series' then (case when s.payment_status = 'paid' then 'paid' else 'pending' end)
                      else 'pending' end;
        begin
          insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                               member_id, guest_name, guest_email, price, payment_status, subscription_id)
          values (s.club_id, s.court_id, 'subscription', 'confirmed', v_start, v_end,
                  s.member_id, s.guest_name, s.guest_email, v_price, v_pay, s.id);
          created := created + 1;
        exception when exclusion_violation then null;
        end;
      end if;
    end if;
    d := d + 1;
  end loop;
  return created;
end $$;
revoke execute on function public.gen_subscription_bookings_one(uuid) from public;
grant execute on function public.gen_subscription_bookings_one(uuid) to service_role;

-- 7) create_abo: + Gast-Geburtsdatum, Jugendrabatt je Termin --
drop function if exists public.create_abo(text,uuid,int,time,int,date,date,text,text,numeric);
create or replace function public.create_abo(
  p_club_slug text, p_court uuid, p_weekday int, p_start_time time, p_duration_minutes int,
  p_valid_from date, p_valid_until date default null, p_guest_name text default null,
  p_guest_email text default null, p_total_hours numeric default null, p_guest_birthdate date default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_club clubs; v_court courts; v_email text := public.jwt_email(); v_authed boolean := (public.jwt_email() <> '');
  v_member members; v_is_member boolean := false; v_factor numeric; v_total numeric := 0;
  d date; v_from date; v_until date; v_sessions int; v_start timestamptz; v_mode text; v_status text; v_id uuid;
  v_birth date; v_yf numeric;
begin
  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;
  if p_weekday < 0 or p_weekday > 6 then raise exception 'Ungültiger Wochentag.'; end if;
  if p_duration_minutes <= 0 then raise exception 'Ungültige Dauer.'; end if;

  v_from := greatest(p_valid_from, current_date);

  if p_total_hours is not null and p_total_hours > 0 then
    v_sessions := ceil(p_total_hours * 60.0 / p_duration_minutes)::int;
    if v_sessions < 1 then v_sessions := 1; end if;
    if v_sessions > 520 then raise exception 'Maximal 520 Termine (~10 Jahre) pro Abo.'; end if;
    d := v_from;
    while extract(dow from d)::int <> p_weekday loop d := d + 1; end loop;
    v_from  := d;
    v_until := d + (7 * (v_sessions - 1));
  else
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

  v_birth := case when v_is_member then v_member.birthdate else p_guest_birthdate end;

  d := v_from;
  while d <= v_until loop
    if extract(dow from d)::int = p_weekday then
      v_start := (d::text || ' ' || p_start_time::text)::timestamp at time zone v_club.timezone;
      v_yf := public._youth_factor(v_club.youth_discount_percent, v_club.youth_max_age, v_birth, d);
      v_total := v_total + public._slot_unit_price(v_club.id, v_court.environment, v_court.price_per_hour, v_start, v_club.timezone, p_duration_minutes) * v_factor * v_yf;
    end if;
    d := d + 1;
  end loop;
  v_total := round(v_total, 2);

  v_mode := coalesce(v_club.abo_payment_mode, 'series');
  v_status := case when v_total <= 0 then 'paid' else 'unpaid' end;

  insert into subscriptions(club_id, member_id, court_id, weekday, start_time, duration_minutes,
        valid_from, valid_until, guest_name, guest_email, guest_birthdate, price, payment_mode, payment_status, created_by)
    values (v_club.id, case when v_is_member then v_member.id end, v_court.id, p_weekday, p_start_time, p_duration_minutes,
        v_from, v_until,
        case when v_is_member then null else p_guest_name end,
        case when v_is_member then lower(v_member.email) else lower(p_guest_email) end,
        case when v_is_member then null else p_guest_birthdate end,
        v_total, v_mode, v_status, nullif(v_email,''))
    returning id into v_id;

  perform public.gen_subscription_bookings_one(v_id);

  return json_build_object('id', v_id, 'price', v_total, 'payment_mode', v_mode,
                           'payment_status', v_status, 'is_member', v_is_member, 'currency', v_club.currency);
end $$;
grant execute on function public.create_abo(text,uuid,int,time,int,date,date,text,text,numeric,date) to anon, authenticated;

notify pgrst, 'reload schema';
