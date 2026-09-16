-- ============================================================
-- Migration 28 – Turniersystem (Clubmeisterschaft) + Club UTC Pischelsdorf
--
-- Generisches, feature-geflaggtes K.-o.-Turnier ("Tunierbaum"):
--   clubs.features.tournament = true  -> Turnier-Button oben rechts (index.html),
--   Admin-Tab "Turnier" (admin.html).
--
-- Ablauf:
--   1) Admin legt Turnier an (Status 'registration') + optional Anmeldefrist.
--   2) Mitglieder (Frauen & Männer gemeinsam) melden sich selbst an (bis Frist).
--   3) Admin reiht alle Teilnehmer (bester=Seed 1 … schlechtester=Seed n).
--   4) Admin lost aus -> gesetzter K.-o.-Baum (Freilose für Topgesetzte).
--   5) Admin ODER Mitglieder tragen Ergebnisse im Tennis-Stil ein (z. B. 6-1;3-6;6-4).
--      Sieger wird aus den Sätzen abgeleitet und automatisch weiter in die
--      nächste Runde gesetzt. Alle Mitglieder sehen Baum + Ergebnisse.
-- ============================================================

-- ---------- Tabellen ----------
create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  name text not null,
  status text not null default 'registration'
    check (status in ('registration','seeding','running','done')),
  registration_deadline timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.tournament_participants (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  club_id uuid not null references public.clubs(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  seed int,                                   -- 1 = bester (vom Admin gereiht)
  created_at timestamptz not null default now(),
  unique (tournament_id, member_id)
);

create table if not exists public.tournament_matches (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  club_id uuid not null references public.clubs(id) on delete cascade,
  round int not null,                         -- 1 = erste Runde, steigend bis Finale
  slot int not null,                          -- Position in der Runde (0-basiert)
  p1_member_id uuid references public.members(id) on delete set null,
  p2_member_id uuid references public.members(id) on delete set null,
  winner_member_id uuid references public.members(id) on delete set null,
  score text,                                 -- z. B. "6-1;3-6;6-4"
  next_match_id uuid references public.tournament_matches(id) on delete set null,
  next_slot int,                              -- 1 -> Sieger wird p1 des Folgespiels, 2 -> p2
  updated_at timestamptz not null default now(),
  unique (tournament_id, round, slot)
);

create index if not exists idx_tour_part_tid  on public.tournament_participants(tournament_id);
create index if not exists idx_tour_match_tid on public.tournament_matches(tournament_id);
create index if not exists idx_tournaments_club on public.tournaments(club_id);

-- ---------- Hilfsfunktion: aktives Mitglied dieses Clubs? ----------
create or replace function public.is_member_of(p_club uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members m
                 where m.club_id = p_club
                   and lower(m.email) = public.jwt_email()
                   and m.active)
$$;
grant execute on function public.is_member_of(uuid) to anon, authenticated;

-- ---------- RLS ----------
alter table public.tournaments             enable row level security;
alter table public.tournament_participants enable row level security;
alter table public.tournament_matches      enable row level security;

-- Lesen: Admin des Clubs ODER aktives Mitglied. Schreiben direkt: nur Admin.
-- (Mitglieder-Aktionen laufen über SECURITY-DEFINER-RPCs unten.)
drop policy if exists tour_read  on public.tournaments;
create policy tour_read  on public.tournaments for select
  using (manages_club(club_id) or is_member_of(club_id));
drop policy if exists tour_write on public.tournaments;
create policy tour_write on public.tournaments for all
  using (manages_club(club_id)) with check (manages_club(club_id));

drop policy if exists tpart_read  on public.tournament_participants;
create policy tpart_read  on public.tournament_participants for select
  using (manages_club(club_id) or is_member_of(club_id));
drop policy if exists tpart_write on public.tournament_participants;
create policy tpart_write on public.tournament_participants for all
  using (manages_club(club_id)) with check (manages_club(club_id));

drop policy if exists tmatch_read  on public.tournament_matches;
create policy tmatch_read  on public.tournament_matches for select
  using (manages_club(club_id) or is_member_of(club_id));
drop policy if exists tmatch_write on public.tournament_matches;
create policy tmatch_write on public.tournament_matches for all
  using (manages_club(club_id)) with check (manages_club(club_id));

grant select, insert, update, delete
  on public.tournaments, public.tournament_participants, public.tournament_matches
  to authenticated;
grant select on public.tournaments, public.tournament_participants, public.tournament_matches to anon;

-- ============================================================
-- RPCs – Mitglieder-Aktionen (SECURITY DEFINER, eigene Prüfung)
-- ============================================================

-- Mitglied meldet sich selbst an
create or replace function public.tournament_register(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_status text; v_deadline timestamptz; v_member uuid;
begin
  select club_id, status, registration_deadline
    into v_club, v_status, v_deadline
    from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if v_status <> 'registration' then raise exception 'Die Anmeldung ist geschlossen.'; end if;
  if v_deadline is not null and now() > v_deadline then raise exception 'Die Anmeldefrist ist abgelaufen.'; end if;
  select id into v_member from members
    where club_id = v_club and lower(email) = jwt_email() and active;
  if v_member is null then raise exception 'Nur aktive Mitglieder können sich anmelden.'; end if;
  insert into tournament_participants(tournament_id, club_id, member_id)
    values (p_tournament_id, v_club, v_member)
    on conflict (tournament_id, member_id) do nothing;
end $$;

-- Mitglied meldet sich wieder ab (nur während der Anmeldephase)
create or replace function public.tournament_unregister(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_status text; v_member uuid;
begin
  select club_id, status into v_club, v_status from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if v_status <> 'registration' then raise exception 'Abmeldung ist nicht mehr möglich.'; end if;
  select id into v_member from members
    where club_id = v_club and lower(email) = jwt_email() and active;
  delete from tournament_participants where tournament_id = p_tournament_id and member_id = v_member;
end $$;

-- ============================================================
-- RPCs – Admin-Aktionen
-- ============================================================

create or replace function public.tournament_create(p_club_slug text, p_name text, p_deadline timestamptz default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_id uuid;
begin
  select id into v_club from clubs where slug = p_club_slug;
  if v_club is null then raise exception 'Club nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  insert into tournaments(club_id, name, registration_deadline)
    values (v_club, coalesce(nullif(trim(p_name),''), 'Clubmeisterschaft'), p_deadline)
    returning id into v_id;
  return v_id;
end $$;

create or replace function public.tournament_set_status(p_tournament_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid;
begin
  select club_id into v_club from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  if p_status not in ('registration','seeding','running','done') then
    raise exception 'Ungültiger Status.'; end if;
  update tournaments set status = p_status where id = p_tournament_id;
end $$;

create or replace function public.tournament_set_deadline(p_tournament_id uuid, p_deadline timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid;
begin
  select club_id into v_club from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  update tournaments set registration_deadline = p_deadline where id = p_tournament_id;
end $$;

-- Admin reiht Teilnehmer: p_member_ids in Reihenfolge best -> schlechtest (Seed 1..n)
create or replace function public.tournament_set_seeds(p_tournament_id uuid, p_member_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid; i int;
begin
  select club_id into v_club from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  update tournament_participants set seed = null where tournament_id = p_tournament_id;
  for i in 1 .. coalesce(array_length(p_member_ids,1),0) loop
    update tournament_participants set seed = i
      where tournament_id = p_tournament_id and member_id = p_member_ids[i];
  end loop;
  update tournaments set status = 'seeding' where id = p_tournament_id and status = 'registration';
end $$;

-- Auslosen: gesetzter K.-o.-Baum aus den Seeds (Freilose für Topgesetzte)
create or replace function public.tournament_draw(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_club uuid; v_n int; v_size int; v_rounds int;
  v_slots int[]; v_tmp int[]; v_ids uuid[];
  v_r int; v_s int; v_cnt int; v_sum int; v_p int;
  v_seedA int; v_seedB int; v_idA uuid; v_idB uuid;
  rec record;
begin
  select club_id into v_club from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;

  -- Teilnehmer nach Seed (ungereihte ans Ende, dann Anmeldezeit)
  select array_agg(member_id order by seed nulls last, created_at)
    into v_ids from tournament_participants where tournament_id = p_tournament_id;
  v_n := coalesce(array_length(v_ids,1),0);
  if v_n < 2 then raise exception 'Mindestens 2 Teilnehmer nötig.'; end if;

  -- Bracketgröße = nächste 2er-Potenz >= n; Rundenzahl
  v_size := 2; while v_size < v_n loop v_size := v_size * 2; end loop;
  v_rounds := 0; v_cnt := v_size; while v_cnt > 1 loop v_rounds := v_rounds + 1; v_cnt := v_cnt / 2; end loop;

  -- Effektive Seeds 1..n sicherstellen (auch wenn Admin nicht/teilweise gereiht hat)
  update tournament_participants p set seed = x.rn
    from (select member_id, row_number() over (order by seed nulls last, created_at) rn
          from tournament_participants where tournament_id = p_tournament_id) x
   where p.tournament_id = p_tournament_id and p.member_id = x.member_id;

  -- Standard-Setzreihenfolge der Slots aufbauen: [1,2] -> [1,4,3,2] -> [1,8,5,4,3,6,7,2] ...
  v_slots := array[1,2];
  v_r := 1;
  while v_r < v_rounds loop
    v_tmp := '{}'::int[];
    v_sum := array_length(v_slots,1) * 2 + 1;
    foreach v_p in array v_slots loop
      v_tmp := v_tmp || v_p || (v_sum - v_p);
    end loop;
    v_slots := v_tmp;
    v_r := v_r + 1;
  end loop;

  -- Alte Matches weg, neue leere Matches je Runde anlegen
  delete from tournament_matches where tournament_id = p_tournament_id;
  v_r := 1; v_cnt := v_size / 2;
  while v_r <= v_rounds loop
    for v_s in 0 .. (v_cnt - 1) loop
      insert into tournament_matches(tournament_id, club_id, round, slot)
        values (p_tournament_id, v_club, v_r, v_s);
    end loop;
    v_cnt := v_cnt / 2; v_r := v_r + 1;
  end loop;

  -- Verkettung: Sieger von (r,slot) -> (r+1, slot/2), p1 wenn slot gerade sonst p2
  update tournament_matches child
    set next_match_id = parent.id, next_slot = (child.slot % 2) + 1
    from tournament_matches parent
    where child.tournament_id = p_tournament_id
      and parent.tournament_id = p_tournament_id
      and parent.round = child.round + 1
      and parent.slot = child.slot / 2;

  -- Runde 1 mit Spielern aus der Setzreihenfolge füllen
  for v_s in 0 .. (v_size / 2 - 1) loop
    v_seedA := v_slots[2 * v_s + 1];
    v_seedB := v_slots[2 * v_s + 2];
    v_idA := case when v_seedA <= v_n then v_ids[v_seedA] else null end;
    v_idB := case when v_seedB <= v_n then v_ids[v_seedB] else null end;
    update tournament_matches set p1_member_id = v_idA, p2_member_id = v_idB
      where tournament_id = p_tournament_id and round = 1 and slot = v_s;
  end loop;

  -- Freilose (nur Runde 1): einziger Spieler steigt automatisch auf
  for rec in
    select * from tournament_matches
     where tournament_id = p_tournament_id and round = 1
       and ((p1_member_id is null) <> (p2_member_id is null))
  loop
    update tournament_matches set winner_member_id = coalesce(rec.p1_member_id, rec.p2_member_id)
      where id = rec.id;
    if rec.next_match_id is not null then
      if rec.next_slot = 1 then
        update tournament_matches set p1_member_id = coalesce(rec.p1_member_id, rec.p2_member_id)
          where id = rec.next_match_id;
      else
        update tournament_matches set p2_member_id = coalesce(rec.p1_member_id, rec.p2_member_id)
          where id = rec.next_match_id;
      end if;
    end if;
  end loop;

  update tournaments set status = 'running' where id = p_tournament_id;
end $$;

-- Ergebnis eintragen (Admin ODER aktives Mitglied). Tennis-Sätze, Sieger abgeleitet.
create or replace function public.tournament_set_result(p_match_id uuid, p_score text, p_winner uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_club uuid; v_tid uuid; v_p1 uuid; v_p2 uuid; v_status text;
  v_next uuid; v_nslot int; v_prev_winner uuid;
  v_sets text[]; v_set text; a int; b int; v_w1 int := 0; v_w2 int := 0; v_winner uuid;
begin
  select m.club_id, m.tournament_id, m.p1_member_id, m.p2_member_id, m.next_match_id, m.next_slot, m.winner_member_id,
         t.status
    into v_club, v_tid, v_p1, v_p2, v_next, v_nslot, v_prev_winner, v_status
    from tournament_matches m join tournaments t on t.id = m.tournament_id
   where m.id = p_match_id;
  if v_club is null then raise exception 'Spiel nicht gefunden.'; end if;
  if not (manages_club(v_club) or is_member_of(v_club)) then
    raise exception 'Nur Mitglieder oder Admins können Ergebnisse eintragen.'; end if;
  if v_status <> 'running' then raise exception 'Für dieses Turnier können keine Ergebnisse eingetragen werden.'; end if;
  if v_p1 is null or v_p2 is null then raise exception 'Für dieses Spiel stehen noch nicht beide Spieler fest.'; end if;

  -- Sätze parsen: Trenner ; , oder Leerzeichen; Satz "n-m" / "n:m"
  v_sets := regexp_split_to_array(trim(p_score), '[;,[:space:]]+');
  foreach v_set in array v_sets loop
    if v_set is null or v_set = '' then continue; end if;
    if v_set !~ '^[0-9]{1,2}[:\-][0-9]{1,2}$' then
      raise exception 'Ungültiger Satz "%". Format z. B. 6-1;3-6;6-4', v_set; end if;
    a := split_part(regexp_replace(v_set,'[:\-]','-'), '-', 1)::int;
    b := split_part(regexp_replace(v_set,'[:\-]','-'), '-', 2)::int;
    if a > b then v_w1 := v_w1 + 1;
    elsif b > a then v_w2 := v_w2 + 1;
    else raise exception 'Ein Satz kann nicht unentschieden sein ("%").', v_set; end if;
  end loop;
  if v_w1 = 0 and v_w2 = 0 then raise exception 'Bitte mindestens einen Satz eingeben (z. B. 6-1;3-6;6-4).'; end if;

  -- Sieger bestimmen
  if p_winner is not null then
    if p_winner not in (v_p1, v_p2) then raise exception 'Ungültiger Sieger.'; end if;
    v_winner := p_winner;
  elsif v_w1 > v_w2 then v_winner := v_p1;
  elsif v_w2 > v_w1 then v_winner := v_p2;
  else raise exception 'Kein eindeutiger Sieger aus dem Ergebnis – bitte Sieger angeben.';
  end if;

  update tournament_matches
    set score = trim(p_score), winner_member_id = v_winner, updated_at = now()
    where id = p_match_id;

  -- Sieger ins Folgespiel setzen; bei Änderung Folgespiel zurücksetzen
  if v_next is not null then
    if v_nslot = 1 then
      update tournament_matches set p1_member_id = v_winner,
             winner_member_id = case when winner_member_id is not null and p1_member_id is distinct from v_winner then null else winner_member_id end,
             score = case when winner_member_id is not null and p1_member_id is distinct from v_winner then null else score end
        where id = v_next;
    else
      update tournament_matches set p2_member_id = v_winner,
             winner_member_id = case when winner_member_id is not null and p2_member_id is distinct from v_winner then null else winner_member_id end,
             score = case when winner_member_id is not null and p2_member_id is distinct from v_winner then null else score end
        where id = v_next;
    end if;
  end if;
end $$;

create or replace function public.tournament_delete(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_club uuid;
begin
  select club_id into v_club from tournaments where id = p_tournament_id;
  if v_club is null then return; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;
  delete from tournaments where id = p_tournament_id;   -- cascade räumt participants/matches
end $$;

grant execute on function
  public.tournament_register(uuid), public.tournament_unregister(uuid),
  public.tournament_create(text,text,timestamptz), public.tournament_set_status(uuid,text),
  public.tournament_set_deadline(uuid,timestamptz), public.tournament_set_seeds(uuid,uuid[]),
  public.tournament_draw(uuid), public.tournament_set_result(uuid,text,uuid),
  public.tournament_delete(uuid)
  to authenticated;

-- ============================================================
-- Club UTC Pischelsdorf anlegen (Standard-Buchung + Turnier-Feature)
-- ============================================================
insert into public.clubs (slug, name, owner_email, active, timezone, currency, features)
values ('utc-pischelsdorf', 'UTC Pischelsdorf', 'florian.a.haslinger@gmail.com', true, 'Europe/Vienna', 'EUR',
        '{"tournament":true}'::jsonb)
on conflict (slug) do update
  set name = excluded.name,
      active = true,
      features = public.clubs.features || '{"tournament":true}'::jsonb;

-- Default-Öffnungszeiten (Mo–So 08:00–22:00), falls noch keine
insert into public.opening_hours (club_id, weekday, open_time, close_time, closed)
select c.id, g.wd, time '08:00', time '22:00', false
from public.clubs c cross join generate_series(0,6) as g(wd)
where c.slug = 'utc-pischelsdorf'
  and not exists (select 1 from public.opening_hours o where o.club_id = c.id);

notify pgrst, 'reload schema';
