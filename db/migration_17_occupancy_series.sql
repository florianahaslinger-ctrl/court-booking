-- ============================================================
-- Migration 17 – Wiederkehrende Belegungen (Sperren/Gratis/Modus)
--
-- Admin legt eine Serie an (Platz, Art, Wochentag, Uhrzeit, Zeitraum) und
-- das System erzeugt daraus wiederkehrende Buchungen – analog zu Abos,
-- aber OHNE Mitglied (fuer Training/Turnier/Wartung usw.).
-- Rollierend per pg_cron erzeugt; erscheint automatisch im Buchungsraster.
-- ============================================================

-- Herkunft-Verweis auf die Serie (wie subscription_id fuer Abos)
alter table public.bookings add column if not exists occupancy_id uuid;

create table if not exists public.occupancy_series (
  id            uuid primary key default gen_random_uuid(),
  club_id       uuid not null references public.clubs(id) on delete cascade,
  court_id      uuid not null references public.courts(id) on delete cascade,
  kind          text not null default 'block' check (kind in ('block','free')),
  booking_type_id uuid references public.booking_types(id) on delete set null,
  weekday       int  not null check (weekday between 0 and 6),
  start_time    time not null,
  duration_minutes int not null default 60 check (duration_minutes > 0),
  valid_from    date not null,
  valid_until   date not null,
  note          text,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  check (valid_until >= valid_from)
);

alter table public.bookings drop constraint if exists bookings_occupancy_fk;
alter table public.bookings add constraint bookings_occupancy_fk
  foreign key (occupancy_id) references public.occupancy_series(id) on delete set null;

-- RLS: nur die Club-Verwaltung sieht/aendert ihre Serien.
alter table public.occupancy_series enable row level security;
drop policy if exists occ_all on public.occupancy_series;
create policy occ_all on public.occupancy_series for all
  using (manages_club(club_id)) with check (manages_club(club_id));
grant select, insert, update, delete on public.occupancy_series to authenticated;

-- Kern-Generator: fehlende Belegungs-Buchungen fuer die naechsten p_days Tage.
create or replace function public.gen_occupancy_bookings(p_club uuid default null, p_days int default 21)
returns int language plpgsql security definer set search_path = public as $$
declare
  s record; d date; d0 date := current_date; created int := 0;
  v_start timestamptz; v_end timestamptz;
begin
  for s in
    select occ.*, c.timezone as club_tz
    from occupancy_series occ join clubs c on c.id = occ.club_id
    where occ.active and (p_club is null or occ.club_id = p_club)
  loop
    d := greatest(d0, s.valid_from);
    while d <= least(s.valid_until, d0 + p_days) loop
      if extract(dow from d)::int = s.weekday then
        v_start := (d::text || ' ' || s.start_time::text)::timestamp at time zone s.club_tz;
        v_end   := v_start + make_interval(mins => s.duration_minutes);
        if not exists (select 1 from bookings b where b.occupancy_id = s.id and b.start_at = v_start) then
          begin
            insert into bookings(club_id, court_id, kind, booking_type_id, status, start_at, end_at,
                                 price, payment_status, note, occupancy_id)
            values (s.club_id, s.court_id, s.kind, s.booking_type_id, 'confirmed', v_start, v_end,
                    0, 'none', s.note, s.id);
            created := created + 1;
          exception when exclusion_violation then
            null; -- Slot bereits belegt -> ueberspringen
          end;
        end if;
      end if;
      d := d + 1;
    end loop;
  end loop;
  return created;
end $$;
revoke execute on function public.gen_occupancy_bookings(uuid,int) from public;

-- Oeffentlicher Wrapper: Admin erzeugt fuer den eigenen Club sofort.
create or replace function public.generate_my_occupancies(p_club uuid)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not manages_club(p_club) then raise exception 'Keine Berechtigung fuer diesen Club.'; end if;
  return gen_occupancy_bookings(p_club, 21);
end $$;
grant execute on function public.generate_my_occupancies(uuid) to authenticated;

-- Taeglicher Cron-Job (03:20) – rollierend die naechsten 21 Tage.
do $$ begin perform cron.unschedule('gen-occupancies-daily'); exception when others then null; end $$;
select cron.schedule('gen-occupancies-daily', '20 3 * * *',
  $j$ select public.gen_occupancy_bookings(null, 21); $j$);

notify pgrst, 'reload schema';
