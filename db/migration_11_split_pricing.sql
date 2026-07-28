-- ============================================================
-- Migration 11 – Preis geteilt statt pro Person + Tarif-Farben + Abo-Horizont
--
-- 1) PREISLOGIK korrigiert: der Platzpreis ist FIX und wird durch die
--    Spielerzahl geteilt. Jede Person zahlt ihren Anteil nach Status
--    (Gast = voll, Mitglied gratis = 0, Rabatt = anteilig). Beispiel:
--    1 Mitglied (gratis) + 3 Gäste -> 3/4 des Platzpreises.
--    => Gesamt = Platzpreis * (Summe der Faktoren) / Personenzahl.
-- 2) price_windows.color: Farbe je Tarif-Zeitfenster (Grid + Legende).
-- 3) Abo-Buchungen weiter als 3 Wochen im Voraus (Horizont 366 Tage,
--    begrenzt durch valid_until des Abos).
-- ============================================================

-- (2) Tarif-Farbe
alter table public.price_windows add column if not exists color text;

-- (1) create_booking: Platzpreis geteilt durch Spielerzahl, Anteil je Faktor
create or replace function public.create_booking(
  p_club_slug   text,
  p_court       uuid,
  p_start       timestamptz,
  p_end         timestamptz,
  p_guest_name  text default null,
  p_guest_email text default null,
  p_participants jsonb default '[]'::jsonb
) returns json
language plpgsql security definer set search_path = public as $$
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
  v_id uuid;
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
  v_fac_member := case v_mode when 'free' then 0 when 'discount' then (1 - v_disc/100.0) else 1 end;

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

  -- Voller Platzpreis für den Slot (Zeitfenster, sonst Platzpreis)
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
  v_unit := round(v_rate * v_minutes/60.0, 2);           -- voller Platzpreis für den Zeitraum

  -- Faktoren sammeln (Bucher = Person 1)
  v_kind := case when v_is_member then 'member' else 'guest' end;
  v_booker_fac := case when v_is_member then v_fac_member else 1 end;
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

  -- Platzpreis geteilt: Anteil pro Person = voller Preis / Personenzahl
  v_share := v_unit / v_persons;
  v_price := round(v_unit * v_sum_fac / v_persons, 2);   -- Gesamt = Preis * Summe(Faktoren)/N

  if v_price = 0 then v_status := 'confirmed'; v_payment := 'none';
  else v_status := 'pending'; v_payment := 'pending'; v_hold := now() + interval '35 minutes'; end if;

  insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                       member_id, guest_name, guest_email, price, payment_status, hold_expires_at, person_count)
    values (v_club.id, v_court.id, v_kind, v_status, p_start, p_end,
            case when v_is_member then v_member.id end,
            case when v_is_member then null else p_guest_name end,
            case when v_is_member then v_member.email else p_guest_email end,
            v_price, v_payment, v_hold, v_persons)
    returning id into v_id;

  for v_pp in select * from jsonb_array_elements(v_resolved) loop
    insert into booking_participants(booking_id, club_id, member_id, guest_name, is_member, price)
      values (v_id, v_club.id,
              nullif(v_pp->>'member_id','')::uuid,
              v_pp->>'guest_name',
              (v_pp->>'is_member')::boolean,
              round(v_share * (v_pp->>'fac')::numeric, 2));
  end loop;

  return json_build_object('id', v_id, 'price', v_price, 'status', v_status,
                           'is_member', v_is_member, 'kind', v_kind, 'currency', v_club.currency,
                           'persons', v_persons);
exception
  when exclusion_violation then raise exception 'Dieser Slot ist inzwischen belegt – bitte anderen wählen.';
end $$;
grant execute on function public.create_booking(text,uuid,timestamptz,timestamptz,text,text,jsonb) to anon, authenticated;

-- (3) Abo-Horizont: bis 366 Tage im Voraus (begrenzt durch valid_until)
create or replace function public.gen_subscription_bookings(p_club uuid default null, p_days int default 366)
returns int language plpgsql security definer set search_path = public as $$
declare
  s record; d date; d0 date := current_date; created int := 0;
  v_start timestamptz; v_end timestamptz;
begin
  for s in
    select sub.*, c.timezone as club_tz
    from subscriptions sub join clubs c on c.id = sub.club_id
    where sub.active and (p_club is null or sub.club_id = p_club)
  loop
    d := greatest(d0, s.valid_from);
    while d <= least(s.valid_until, d0 + p_days) loop
      if extract(dow from d)::int = s.weekday then
        v_start := (d::text || ' ' || s.start_time::text)::timestamp at time zone s.club_tz;
        v_end   := v_start + make_interval(mins => s.duration_minutes);
        if not exists (select 1 from bookings b where b.subscription_id = s.id and b.start_at = v_start) then
          begin
            insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                                 member_id, price, payment_status, subscription_id)
            values (s.club_id, s.court_id, 'subscription', 'confirmed', v_start, v_end,
                    s.member_id, 0, 'none', s.id);
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

create or replace function public.generate_my_subscriptions(p_club uuid)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not manages_club(p_club) then raise exception 'Keine Berechtigung für diesen Club.'; end if;
  return gen_subscription_bookings(p_club, 366);
end $$;
grant execute on function public.generate_my_subscriptions(uuid) to authenticated;

do $$ begin perform cron.unschedule('gen-subscriptions-daily'); exception when others then null; end $$;
select cron.schedule('gen-subscriptions-daily', '15 3 * * *',
  $j$ select public.gen_subscription_bookings(null, 366); $j$);

notify pgrst, 'reload schema';
