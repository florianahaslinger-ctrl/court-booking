-- ============================================================
-- Migration 08 – Zeitabhängige Preise (Zeitfenster mit €/Stunde)
-- Pro Club & Platzart (Indoor/Outdoor) beliebige Zeitfenster:
--   Wochentage + von/bis + €/Stunde. Trifft der Slot-START in ein
--   Fenster, gilt dessen Stundenpreis statt courts.price_per_hour.
--   Kein Fenster => wie bisher der Platzpreis.
-- Bei Überlappung gewinnt das ENGSTE Fenster (kürzeste Dauer).
-- ============================================================

create table if not exists public.price_windows (
  id            uuid primary key default gen_random_uuid(),
  club_id       uuid not null references public.clubs(id) on delete cascade,
  environment   text not null check (environment in ('indoor','outdoor')),
  weekdays      int[] not null default '{0,1,2,3,4,5,6}',   -- 0=So .. 6=Sa
  start_time    time not null default '00:00',
  end_time      time not null default '24:00',
  price_per_hour numeric(10,2) not null check (price_per_hour >= 0),
  label         text,                                       -- z.B. "Abendtarif"
  sort          int not null default 0,
  created_at    timestamptz not null default now(),
  check (end_time > start_time)
);
create index if not exists price_windows_club_idx on public.price_windows (club_id, environment);

alter table public.price_windows enable row level security;
-- Preise sind öffentlich lesbar (Buchungsseite braucht die Vorschau); Schreiben nur Club-Verwaltung.
drop policy if exists pw_read on public.price_windows;
create policy pw_read on public.price_windows for select using (true);
drop policy if exists pw_write on public.price_windows;
create policy pw_write on public.price_windows for all
  using (manages_club(club_id)) with check (manages_club(club_id));

-- ------------------------------------------------------------
-- create_booking: Stundenpreis ggf. aus passendem Zeitfenster
-- ------------------------------------------------------------
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
  v_minutes int; v_max int; v_price numeric(10,2);
  v_kind text; v_payment text; v_status text; v_hold timestamptz := null;
  v_mode text; v_disc int; v_freemax int;
  v_local timestamptz; v_wd int; v_tod time;
  v_rate numeric(10,2);
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

  if v_email <> '' then
    select * into v_member from members
      where club_id = v_club.id and lower(email) = v_email and active
        and (valid_until is null or valid_until >= current_date);
    if found then v_is_member := true; end if;
  end if;

  -- Mitglieder-Regeln je Platzart wählen
  if v_court.environment = 'indoor' then
    v_mode := v_club.member_pricing_mode_indoor;
    v_disc := v_club.member_discount_percent_indoor;
    v_freemax := v_club.member_free_max_minutes_indoor;
  else
    v_mode := v_club.member_pricing_mode_outdoor;
    v_disc := v_club.member_discount_percent_outdoor;
    v_freemax := v_club.member_free_max_minutes_outdoor;
  end if;

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

  -- Stundenpreis: passendes Zeitfenster (nach Slot-START in Club-Zeitzone), sonst Platzpreis
  v_local := p_start at time zone v_club.timezone;
  v_wd  := extract(dow from v_local)::int;
  v_tod := v_local::time;
  select pw.price_per_hour into v_rate
    from price_windows pw
    where pw.club_id = v_club.id
      and pw.environment = v_court.environment
      and v_wd = any(pw.weekdays)
      and v_tod >= pw.start_time and v_tod < pw.end_time
    order by (pw.end_time - pw.start_time) asc, pw.sort asc
    limit 1;
  v_rate := coalesce(v_rate, v_court.price_per_hour);

  if v_is_member then
    v_kind := 'member';
    case v_mode
      when 'free'     then v_price := 0;
      when 'discount' then v_price := round(v_rate * v_minutes/60.0 * (1 - v_disc/100.0), 2);
      else                 v_price := round(v_rate * v_minutes/60.0, 2);
    end case;
  else
    v_kind := 'guest';
    v_price := round(v_rate * v_minutes/60.0, 2);
  end if;

  if v_price = 0 then v_status := 'confirmed'; v_payment := 'none';
  else v_status := 'pending'; v_payment := 'pending'; v_hold := now() + interval '35 minutes'; end if;

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
grant execute on function public.create_booking(text,uuid,timestamptz,timestamptz,text,text) to anon, authenticated;

notify pgrst, 'reload schema';
