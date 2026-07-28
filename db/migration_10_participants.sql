-- ============================================================
-- Migration 10 – Mitspieler / Preis pro Person
-- Bei einer Buchung können bis zu 3 Zusatzpersonen dazugebucht werden
-- (max. 4 Spieler). Jede Person entweder Club-Mitglied (Mitgliederpreis)
-- oder Gast (voller Preis). Gesamtpreis = Summe der Einzelpreise.
-- Mitglieder-Mitspieler werden nur bei EINGELOGGTEM Bucher anerkannt.
-- ============================================================

-- Personenzahl direkt an der Buchung (für Anzeige / Label "+N")
alter table public.bookings add column if not exists person_count int not null default 1;

create table if not exists public.booking_participants (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.bookings(id) on delete cascade,
  club_id     uuid not null references public.clubs(id) on delete cascade,
  member_id   uuid references public.members(id) on delete set null,
  guest_name  text,
  is_member   boolean not null default false,
  price       numeric(10,2) not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists booking_participants_booking_idx on public.booking_participants (booking_id);

alter table public.booking_participants enable row level security;
-- Zusatzpersonen sieht nur die Club-Verwaltung (enthält evtl. Namen).
drop policy if exists bp_read on public.booking_participants;
create policy bp_read on public.booking_participants for select using (manages_club(club_id));
drop policy if exists bp_write on public.booking_participants;
create policy bp_write on public.booking_participants for all
  using (manages_club(club_id)) with check (manages_club(club_id));

-- ------------------------------------------------------------
-- Mitglieder-Auswahl für den Mitspieler-Picker:
-- gibt id+Name aktiver Mitglieder zurück – NUR wenn der Aufrufer selbst
-- aktives Mitglied oder Verwalter dieses Clubs ist (Roster bleibt privat).
-- ------------------------------------------------------------
create or replace function public.club_member_options(p_club_slug text)
returns table(id uuid, full_name text)
language plpgsql security definer set search_path = public as $$
declare v_club clubs; v_email text := public.jwt_email();
begin
  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then return; end if;
  if not (public.manages_club(v_club.id)
          or exists (select 1 from members m where m.club_id=v_club.id and lower(m.email)=v_email and m.active)) then
    return;  -- kein Zugriff -> leere Liste (Gäste/anonym)
  end if;
  return query
    select m.id, coalesce(nullif(m.full_name,''), m.email)
    from members m
    where m.club_id = v_club.id and m.active
      and (m.valid_until is null or m.valid_until >= current_date)
    order by 2;
end $$;
grant execute on function public.club_member_options(text) to anon, authenticated;

-- ------------------------------------------------------------
-- create_booking mit Mitspielern (p_participants) – additiv:
-- der 6-Argument-Aufruf funktioniert weiter (p_participants default []).
-- p_participants: jsonb-Array, je Eintrag {"member_id":"uuid"} ODER {"guest_name":"..."}
-- ------------------------------------------------------------
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
  v_fac_member numeric; v_price numeric(10,2); v_booker_price numeric(10,2);
  v_persons int := 1;
  v_resolved jsonb := '[]'::jsonb;
  v_pp jsonb; v_mid uuid; v_mrow members; v_pprice numeric(10,2); v_gname text;
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

  -- Mitglieder-Regeln je Platzart
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

  -- Stundenpreis (Zeitfenster, sonst Platzpreis)
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
  v_unit := round(v_rate * v_minutes/60.0, 2);              -- voller Preis pro Person

  -- Bucher (Person 1)
  v_kind := case when v_is_member then 'member' else 'guest' end;
  v_booker_price := round(v_unit * (case when v_is_member then v_fac_member else 1 end), 2);
  v_price := v_booker_price;

  -- Zusatzpersonen
  if p_participants is not null and jsonb_typeof(p_participants) = 'array' then
    for v_pp in select * from jsonb_array_elements(p_participants) loop
      v_persons := v_persons + 1;
      if v_persons > 4 then raise exception 'Maximal 4 Personen pro Buchung.'; end if;
      v_mid := null; v_gname := null;
      -- Mitglieds-Mitspieler nur bei eingeloggtem Bucher anerkennen
      if v_authed and (v_pp ? 'member_id') and nullif(v_pp->>'member_id','') is not null then
        select * into v_mrow from members
          where id = (v_pp->>'member_id')::uuid and club_id = v_club.id and active
            and (valid_until is null or valid_until >= current_date);
        if found then v_mid := v_mrow.id; end if;
      end if;
      if v_mid is not null then
        v_pprice := round(v_unit * v_fac_member, 2);
        v_resolved := v_resolved || jsonb_build_object('member_id', v_mid, 'guest_name', null, 'is_member', true, 'price', v_pprice);
      else
        v_gname := left(coalesce(nullif(v_pp->>'guest_name',''), 'Gast'), 120);
        v_pprice := v_unit;   -- Gast: voller Preis
        v_resolved := v_resolved || jsonb_build_object('member_id', null, 'guest_name', v_gname, 'is_member', false, 'price', v_pprice);
      end if;
      v_price := v_price + v_pprice;
    end loop;
  end if;

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

  -- Zusatzpersonen speichern
  for v_pp in select * from jsonb_array_elements(v_resolved) loop
    insert into booking_participants(booking_id, club_id, member_id, guest_name, is_member, price)
      values (v_id, v_club.id,
              nullif(v_pp->>'member_id','')::uuid,
              v_pp->>'guest_name',
              (v_pp->>'is_member')::boolean,
              (v_pp->>'price')::numeric);
  end loop;

  return json_build_object('id', v_id, 'price', v_price, 'status', v_status,
                           'is_member', v_is_member, 'kind', v_kind, 'currency', v_club.currency,
                           'persons', v_persons);
exception
  when exclusion_violation then raise exception 'Dieser Slot ist inzwischen belegt – bitte anderen wählen.';
end $$;
grant execute on function public.create_booking(text,uuid,timestamptz,timestamptz,text,text,jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- court_busy: Label um "+N" (Zusatzpersonen) ergänzen – bleibt mitglieder-only
-- ------------------------------------------------------------
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
          when 'subscription' then coalesce((select full_name from public.members m where m.id = b.member_id), b.note, 'Abo')
          when 'member'       then coalesce((select full_name from public.members m where m.id = b.member_id), b.guest_name, 'Mitglied')
          when 'free'         then coalesce(bt.name, nullif(b.note,''), b.guest_name, 'Reserviert')
          else                     coalesce(b.guest_name, 'Gast')
         end)
        || case when coalesce(b.person_count,1) > 1 then ' +' || (b.person_count - 1) else '' end
      else null
    end as label,
    bt.name  as type_name,
    bt.color as type_color
  from public.bookings b
  left join public.booking_types bt on bt.id = b.booking_type_id
  where b.status <> 'cancelled'
    and not (b.payment_status = 'pending' and b.hold_expires_at is not null and b.hold_expires_at < now());
grant select on public.court_busy to anon, authenticated;

notify pgrst, 'reload schema';
