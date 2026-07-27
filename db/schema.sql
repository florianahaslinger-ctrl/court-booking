-- ============================================================
-- COURT BOOKING – Tennisplatz-Buchungssystem (Multi-Mandant)
-- Teil der Core-Management-Produktfamilie, eigene Datenbank.
--
-- Rollen:
--   head_admin  – Betreiber (du), sieht & verwaltet ALLE Clubs
--   club_admin  – Tennisplatz-Betreiber, verwaltet NUR seinen Club
--   member      – Mitglied eines Clubs (Login via Supabase Auth)
--   guest       – ohne Login, bucht & zahlt online (Stripe)
--
-- Grundprinzip "alles variabel": Slot-Länge, Öffnungszeiten,
-- Preise, Mitglieder-Modell etc. liegen pro Club konfigurierbar.
-- ============================================================

create extension if not exists pgcrypto;
create extension if not exists btree_gist;   -- für Überschneidungs-Sperre

-- ------------------------------------------------------------
-- CLUBS (Mandanten = einzelne Tennisplätze)
-- ------------------------------------------------------------
create table if not exists public.clubs (
  id            uuid primary key default gen_random_uuid(),
  slug          text unique not null,                 -- z.B. "tc-wien" -> URL
  name          text not null,
  owner_email   text not null,                        -- Login-Mail des Club-Admins
  active        boolean not null default true,

  -- Betrieb / Darstellung
  timezone      text    not null default 'Europe/Vienna',
  currency      text    not null default 'EUR',
  slot_minutes  int     not null default 60 check (slot_minutes between 15 and 240),
  logo_url      text,
  primary_color text    default '#2E8B57',            -- helle Palette, pro Club anpassbar

  -- Mitglieder-Preismodell (variabel!)
  --   'free'     = Mitglieder spielen gratis (dann max. member_free_max_minutes)
  --   'discount' = Mitglieder zahlen weniger (member_discount_percent)
  --   'full'     = Mitglieder zahlen den vollen Preis
  member_pricing_mode     text not null default 'discount'
                          check (member_pricing_mode in ('free','discount','full')),
  member_discount_percent int  not null default 50 check (member_discount_percent between 0 and 100),
  member_free_max_minutes int  not null default 300, -- 5h Kappung bei Gratis-Modell

  -- Buchungsregeln
  booking_open_days   int not null default 14,   -- wie weit im Voraus buchbar
  min_lead_minutes    int not null default 0,    -- Vorlauf vor Startzeit
  cancel_lead_minutes int not null default 1440, -- Stornofrist (24h)

  -- Stripe (Connect – jeder Club bekommt Auszahlungen selbst)
  stripe_account_id   text,
  stripe_enabled      boolean not null default false,

  settings   jsonb not null default '{}',  -- Raum für weitere variable Optionen
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- ADMINS – zweistufiges Menü (head_admin / club_admin)
-- ------------------------------------------------------------
create table if not exists public.app_admins (
  email    text primary key,
  role     text not null default 'club_admin' check (role in ('head_admin','club_admin')),
  club_id  uuid references public.clubs(id) on delete cascade, -- null nur beim head_admin
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- MEMBERS – Mitglieder je Club (Login via Supabase Auth / E-Mail+Passwort)
-- ------------------------------------------------------------
create table if not exists public.members (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  auth_uid    uuid,                              -- = auth.users.id nach Registrierung
  email       text not null,
  full_name   text,
  phone       text,
  active      boolean not null default true,     -- Mitgliedschaft aktiv?
  valid_until date,                              -- optionale Ablaufgrenze
  created_at  timestamptz not null default now(),
  unique (club_id, email)
);

-- ------------------------------------------------------------
-- COURTS – einzelne Plätze; Indoor/Outdoor & eigener Preis
-- ------------------------------------------------------------
create table if not exists public.courts (
  id            uuid primary key default gen_random_uuid(),
  club_id       uuid not null references public.clubs(id) on delete cascade,
  name          text not null,                   -- "Platz 1", "Halle A"
  environment   text not null default 'outdoor'  -- Gast wählt Indoor/Outdoor
                check (environment in ('indoor','outdoor')),
  surface       text default 'clay',             -- clay/hard/grass/carpet (nur Info)
  price_per_hour numeric(10,2) not null default 0 check (price_per_hour >= 0),
  active        boolean not null default true,
  sort          int not null default 0
);

-- ------------------------------------------------------------
-- OPENING HOURS – Öffnungszeiten je Club & Wochentag (variabel)
--   weekday: 0=So .. 6=Sa   (Postgres extract(dow))
-- ------------------------------------------------------------
create table if not exists public.opening_hours (
  id        uuid primary key default gen_random_uuid(),
  club_id   uuid not null references public.clubs(id) on delete cascade,
  weekday   int  not null check (weekday between 0 and 6),
  open_time  time not null default '08:00',
  close_time time not null default '22:00',
  closed    boolean not null default false,
  unique (club_id, weekday)
);

-- ------------------------------------------------------------
-- BOOKINGS – die zentrale Buchungstabelle
--   kind:  'guest'        Gast, online bezahlt
--          'member'       Mitglied (gratis/vergünstigt)
--          'free'         vom Admin eingetragene Gratis-Buchung
--          'block'        Admin sperrt Platz (Wartung/Turnier)
--          'subscription' aus einem Abo generiert (fixer Slot)
-- ------------------------------------------------------------
create table if not exists public.bookings (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null references public.clubs(id) on delete cascade,
  court_id     uuid not null references public.courts(id) on delete cascade,
  kind         text not null default 'guest'
               check (kind in ('guest','member','free','block','subscription')),
  status       text not null default 'confirmed'
               check (status in ('pending','confirmed','cancelled')),

  start_at     timestamptz not null,
  end_at       timestamptz not null,

  -- Wer bucht
  member_id    uuid references public.members(id) on delete set null,
  guest_name   text,
  guest_email  text,
  note         text,                              -- z.B. Grund der Sperre

  -- Preis / Zahlung
  price        numeric(10,2) not null default 0,
  payment_status text not null default 'none'
                 check (payment_status in ('none','pending','paid','refunded')),
  stripe_session_id text,

  subscription_id uuid,                           -- Herkunft, falls aus Abo
  created_at   timestamptz not null default now(),

  check (end_at > start_at)
);

-- Kein Doppelbelegen desselben Platzes (außer stornierte Buchungen):
alter table public.bookings drop constraint if exists bookings_no_overlap;
alter table public.bookings add constraint bookings_no_overlap
  exclude using gist (
    court_id with =,
    tstzrange(start_at, end_at) with &&
  ) where (status <> 'cancelled');

create index if not exists bookings_club_time_idx on public.bookings (club_id, start_at);
create index if not exists bookings_court_time_idx on public.bookings (court_id, start_at);

-- ------------------------------------------------------------
-- SUBSCRIPTIONS – Abos: Mitglied hat automatisch fixen Slot
--   z.B. jeden Dienstag 18:00–19:00 auf Platz 2 von X bis Y
-- ------------------------------------------------------------
create table if not exists public.subscriptions (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  member_id   uuid not null references public.members(id) on delete cascade,
  court_id    uuid not null references public.courts(id) on delete cascade,
  weekday     int  not null check (weekday between 0 and 6),
  start_time  time not null,
  duration_minutes int not null default 60,
  valid_from  date not null,
  valid_until date not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  check (valid_until >= valid_from)
);

alter table public.bookings drop constraint if exists bookings_subscription_fk;
alter table public.bookings add constraint bookings_subscription_fk
  foreign key (subscription_id) references public.subscriptions(id) on delete set null;

-- ============================================================
-- HILFSFUNKTIONEN für RLS (Rollen-Prüfung)
-- ============================================================
create or replace function public.jwt_email() returns text
language sql stable as
$$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function public.is_head_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from app_admins
                  where email = public.jwt_email() and role = 'head_admin') $$;

-- Verwaltet der aktuelle Nutzer diesen Club? (head_admin ODER dessen club_admin)
create or replace function public.manages_club(p_club uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select public.is_head_admin()
       or exists (select 1 from app_admins
                  where email = public.jwt_email()
                    and role = 'club_admin' and club_id = p_club) $$;

grant execute on function public.jwt_email(), public.is_head_admin(), public.manages_club(uuid)
  to anon, authenticated;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table public.clubs         enable row level security;
alter table public.app_admins    enable row level security;
alter table public.members       enable row level security;
alter table public.courts        enable row level security;
alter table public.opening_hours enable row level security;
alter table public.bookings      enable row level security;
alter table public.subscriptions enable row level security;

-- Clubs: aktive öffentlich lesbar (für Buchungsseite), Verwaltung nur durch Admins
drop policy if exists clubs_read on public.clubs;
create policy clubs_read on public.clubs for select
  using (active or manages_club(id));
drop policy if exists clubs_write on public.clubs;
create policy clubs_write on public.clubs for all
  using (manages_club(id)) with check (manages_club(id));

-- Admins: head_admin sieht alles; jeder sieht seinen eigenen Eintrag
drop policy if exists admins_read on public.app_admins;
create policy admins_read on public.app_admins for select
  using (is_head_admin() or email = public.jwt_email());
drop policy if exists admins_write on public.app_admins;
create policy admins_write on public.app_admins for all
  using (is_head_admin()) with check (is_head_admin());

-- Courts & Öffnungszeiten: öffentlich lesbar (Buchungsseite), Schreiben nur Club-Verwaltung
drop policy if exists courts_read on public.courts;
create policy courts_read on public.courts for select using (true);
drop policy if exists courts_write on public.courts;
create policy courts_write on public.courts for all
  using (manages_club(club_id)) with check (manages_club(club_id));

drop policy if exists hours_read on public.opening_hours;
create policy hours_read on public.opening_hours for select using (true);
drop policy if exists hours_write on public.opening_hours;
create policy hours_write on public.opening_hours for all
  using (manages_club(club_id)) with check (manages_club(club_id));

-- Members: Club-Verwaltung sieht alle; Mitglied sieht sich selbst
drop policy if exists members_read on public.members;
create policy members_read on public.members for select
  using (manages_club(club_id) or email = public.jwt_email());
drop policy if exists members_write on public.members;
create policy members_write on public.members for all
  using (manages_club(club_id)) with check (manages_club(club_id));

-- Bookings: Club-Verwaltung alles; Mitglied seine eigenen. (Freie Slots via View unten.)
drop policy if exists bookings_read on public.bookings;
create policy bookings_read on public.bookings for select
  using (manages_club(club_id)
      or (member_id is not null
          and exists (select 1 from members m
                      where m.id = bookings.member_id and m.email = public.jwt_email())));
drop policy if exists bookings_admin on public.bookings;
create policy bookings_admin on public.bookings for all
  using (manages_club(club_id)) with check (manages_club(club_id));

-- Subscriptions: Club-Verwaltung; Mitglied liest seine eigenen
drop policy if exists subs_read on public.subscriptions;
create policy subs_read on public.subscriptions for select
  using (manages_club(club_id)
      or exists (select 1 from members m
                 where m.id = subscriptions.member_id and m.email = public.jwt_email()));
drop policy if exists subs_write on public.subscriptions;
create policy subs_write on public.subscriptions for all
  using (manages_club(club_id)) with check (manages_club(club_id));

-- ============================================================
-- ÖFFENTLICHE BELEGUNG (ohne Kundendaten preiszugeben)
-- Buchungsseite fragt nur ab: welcher Platz ist wann belegt.
-- ============================================================
create or replace view public.court_busy
with (security_invoker = off) as
  select court_id, club_id, start_at, end_at
  from public.bookings
  where status <> 'cancelled';
grant select on public.court_busy to anon, authenticated;

-- ============================================================
-- SEED: Head-Admin (du) + Demo-Club
-- ============================================================
insert into public.app_admins (email, role)
values ('florian.a.haslinger@gmail.com', 'head_admin')
on conflict (email) do update set role = 'head_admin';

do $$
declare cid uuid; wd int;
begin
  if not exists (select 1 from clubs) then
    insert into clubs (slug, name, owner_email, slot_minutes, member_pricing_mode)
      values ('demo-tennis', 'Demo Tennisclub', 'florian.a.haslinger@gmail.com', 60, 'discount')
      returning id into cid;

    insert into courts (club_id, name, environment, surface, price_per_hour, sort) values
      (cid, 'Platz 1', 'outdoor', 'clay', 16, 1),
      (cid, 'Platz 2', 'outdoor', 'clay', 16, 2),
      (cid, 'Halle A', 'indoor', 'carpet', 28, 3);

    for wd in 0..6 loop
      insert into opening_hours (club_id, weekday, open_time, close_time, closed)
        values (cid, wd, '08:00', '22:00', false);
    end loop;
  end if;
end $$;

-- ============================================================
-- BUCHEN (RPC) – serverseitig validiert, funktioniert für Gäste & Mitglieder
-- Gäste (anon) dürfen nicht direkt in bookings schreiben (RLS); diese
-- security-definer-Funktion prüft Öffnungszeiten, Max-Dauer, Mitglieder-
-- Preis und verhindert Doppelbelegung.
-- ============================================================
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
  v_id      uuid;
begin
  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;

  if p_end <= p_start then raise exception 'Ungültiger Zeitraum.'; end if;
  if p_start < now() then raise exception 'Startzeit liegt in der Vergangenheit.'; end if;

  v_minutes := (extract(epoch from (p_end - p_start)) / 60)::int;

  -- Mitglied? (eingeloggt + aktives Mitglied dieses Clubs)
  if v_email <> '' then
    select * into v_member from members
      where club_id = v_club.id and lower(email) = v_email and active
        and (valid_until is null or valid_until >= current_date);
    if found then v_is_member := true; end if;
  end if;

  -- Max-Dauer (Gratis-Mitglieder: Kappung, sonst offen)
  v_max := 24 * 60;
  if v_is_member and v_club.member_pricing_mode = 'free' then
    v_max := v_club.member_free_max_minutes;
  end if;
  if v_minutes > v_max then
    raise exception 'Maximale Buchungsdauer: % Minuten.', v_max;
  end if;

  -- Öffnungszeiten (in Club-Zeitzone)
  perform 1 from opening_hours oh
    where oh.club_id = v_club.id
      and oh.weekday = extract(dow from (p_start at time zone v_club.timezone))::int
      and not oh.closed
      and (p_start at time zone v_club.timezone)::time >= oh.open_time
      and (p_end   at time zone v_club.timezone)::time <= oh.close_time;
  if not found then raise exception 'Außerhalb der Öffnungszeiten.'; end if;

  -- Preis nach Mitglieder-Modell
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

  -- Preis 0 -> sofort bestätigt; sonst offen bis zur Zahlung (Stripe, Meilenstein 4)
  if v_price = 0 then v_status := 'confirmed'; v_payment := 'none';
  else                v_status := 'pending';   v_payment := 'pending'; end if;

  insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                       member_id, guest_name, guest_email, price, payment_status)
    values (v_club.id, v_court.id, v_kind, v_status, p_start, p_end,
            case when v_is_member then v_member.id end,
            case when v_is_member then null else p_guest_name end,
            case when v_is_member then v_member.email else p_guest_email end,
            v_price, v_payment)
    returning id into v_id;

  return json_build_object('id', v_id, 'price', v_price, 'status', v_status,
                           'is_member', v_is_member, 'kind', v_kind, 'currency', v_club.currency);
exception
  when exclusion_violation then raise exception 'Dieser Slot ist inzwischen belegt – bitte anderen wählen.';
end $$;

grant execute on function public.create_booking(text,uuid,timestamptz,timestamptz,text,text)
  to anon, authenticated;

notify pgrst, 'reload schema';
