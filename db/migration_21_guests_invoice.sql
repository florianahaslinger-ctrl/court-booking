-- ============================================================
-- Migration 21 – Gäste-Kontakte, Gäste-Übersicht, Rechnungs-Zeitstempel
-- ============================================================

-- Zeitpunkt des Rechnungsversands (für "wartet auf Zahlung"-Anzeige)
alter table public.subscriptions add column if not exists invoiced_at timestamptz;

-- Kontaktdaten von Gästen (pro Club + E-Mail)
create table if not exists public.guest_contacts (
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references public.clubs(id) on delete cascade,
  email      text not null,
  name       text,
  phone      text,
  birthdate  date,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  unique (club_id, email)
);
alter table public.guest_contacts enable row level security;
drop policy if exists gc_read on public.guest_contacts;
create policy gc_read on public.guest_contacts for select using (manages_club(club_id));
grant select on public.guest_contacts to authenticated;

-- Kontakt eines Gastes festhalten/aktualisieren (vom Client nach dem Buchen)
create or replace function public.record_guest_contact(
  p_club_slug text, p_email text, p_name text default null,
  p_phone text default null, p_birthdate date default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_email text := lower(trim(coalesce(p_email,'')));
begin
  if v_email = '' then return; end if;
  select id into v_club from clubs where slug = p_club_slug and active;
  if v_club is null then return; end if;
  insert into guest_contacts(club_id, email, name, phone, birthdate)
    values (v_club, v_email, nullif(p_name,''), nullif(p_phone,''), p_birthdate)
  on conflict (club_id, email) do update set
    name      = coalesce(nullif(excluded.name,''),  guest_contacts.name),
    phone     = coalesce(nullif(excluded.phone,''), guest_contacts.phone),
    birthdate = coalesce(excluded.birthdate,        guest_contacts.birthdate),
    last_seen = now();
end $$;
grant execute on function public.record_guest_contact(text,text,text,text,date) to anon, authenticated;

-- Backfill aus bestehenden Gast-Buchungen (ohne Telefon/Geb, die gab es noch nicht)
insert into public.guest_contacts(club_id, email, name, first_seen, last_seen)
select b.club_id, lower(b.guest_email), max(b.guest_name), min(b.created_at), max(b.created_at)
from public.bookings b
where b.guest_email is not null and trim(b.guest_email) <> ''
group by b.club_id, lower(b.guest_email)
on conflict (club_id, email) do nothing;

-- Aggregierte Gäste-Liste für Admins
create or replace function public.guest_list(p_club uuid)
returns table(email text, name text, phone text, birthdate date, bookings bigint, last_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not manages_club(p_club) then raise exception 'Keine Berechtigung.'; end if;
  return query
  with be as (
    select lower(guest_email) e, guest_name n, start_at ts
    from bookings where club_id = p_club and guest_email is not null and status <> 'cancelled'
  ), se as (
    select lower(guest_email) e, guest_name n
    from subscriptions where club_id = p_club and guest_email is not null
  ), alle as (
    select e, n from be union all select e, n from se
  )
  select al.e as email,
         coalesce(gc.name, (array_agg(al.n) filter (where al.n is not null))[1]) as name,
         gc.phone, gc.birthdate,
         (select count(*) from be where be.e = al.e) as bookings,
         (select max(ts) from be where be.e = al.e) as last_at
  from alle al
  left join guest_contacts gc on gc.club_id = p_club and lower(gc.email) = al.e
  group by al.e, gc.name, gc.phone, gc.birthdate
  order by (select max(ts) from be where be.e = al.e) desc nulls last;
end $$;
grant execute on function public.guest_list(uuid) to authenticated;

notify pgrst, 'reload schema';
