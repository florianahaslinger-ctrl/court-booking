-- ============================================================
-- Migration 09 – Buchungs-Modi (Farben + Legende), club-eigen
-- Jeder Club legt selbst Modi an (z.B. "Training", "Turnier") mit
-- Name + Farbe. Admin-Buchungen können einen Modus tragen; das Raster
-- färbt die Zelle, eine Legende unter dem Raster erklärt die Farben.
-- Kategorie-Infos (Name/Farbe) sind öffentlich; Personennamen bleiben
-- weiter nur für Mitglieder/Admins sichtbar (siehe Migration 07).
-- ============================================================

create table if not exists public.booking_types (
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references public.clubs(id) on delete cascade,
  name       text not null,
  color      text not null default '#3B7DD8',
  sort       int  not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists booking_types_club_idx on public.booking_types (club_id);

alter table public.bookings
  add column if not exists booking_type_id uuid references public.booking_types(id) on delete set null;

alter table public.booking_types enable row level security;
-- Modi sind öffentlich lesbar (Legende/Farben auf der Buchungsseite); Schreiben nur Club-Verwaltung.
drop policy if exists bt_read on public.booking_types;
create policy bt_read on public.booking_types for select using (true);
drop policy if exists bt_write on public.booking_types;
create policy bt_write on public.booking_types for all
  using (manages_club(club_id)) with check (manages_club(club_id));

-- ------------------------------------------------------------
-- court_busy: Modus-Name/-Farbe (öffentlich) ergänzen, Label (Personen) bleibt mitglieder-only
-- ------------------------------------------------------------
create or replace view public.court_busy
with (security_invoker = off) as
  select
    b.court_id,
    b.club_id,
    b.start_at,
    b.end_at,
    case
      when public.manages_club(b.club_id)
        or exists (
          select 1 from public.members m
          where m.club_id = b.club_id
            and lower(m.email) = public.jwt_email()
            and m.active
        )
      then
        case b.kind
          when 'block'        then coalesce(bt.name, nullif(b.note,''), 'Gesperrt')
          when 'subscription' then coalesce((select full_name from public.members m where m.id = b.member_id), b.note, 'Abo')
          when 'member'       then coalesce((select full_name from public.members m where m.id = b.member_id), b.guest_name, 'Mitglied')
          when 'free'         then coalesce(bt.name, nullif(b.note,''), b.guest_name, 'Reserviert')
          else                     coalesce(b.guest_name, 'Gast')
        end
      else null
    end as label,
    bt.name  as type_name,
    bt.color as type_color
  from public.bookings b
  left join public.booking_types bt on bt.id = b.booking_type_id
  where b.status <> 'cancelled'
    and not (b.payment_status = 'pending'
             and b.hold_expires_at is not null
             and b.hold_expires_at < now());

grant select on public.court_busy to anon, authenticated;

notify pgrst, 'reload schema';
