-- ============================================================
-- Migration 32 – Auslosung wie bei großen Tennisturnieren (gesetzt + gelost)
--
-- Bisher: rein deterministische Setzung (jeder Rang immer an dieselbe Stelle).
-- Jetzt: echte Tennis-Auslosung:
--   * Gesetzte Spieler werden geschützt: Nr. 1 ganz oben, Nr. 2 ganz unten,
--     3/4 in getrennte Viertel, 5–8 in getrennte Achtel usw. (Standard-Positionen).
--   * Innerhalb jedes Setz-Tiers ({3,4}, {5–8}, …) wird die Zuordnung ausgelost.
--   * Alle Ungesetzten werden komplett zufällig auf die restlichen Plätze gelost.
--   * Freilose gehen immer an die Topgesetzten (deren Erstrunden-Gegner fehlt).
-- Gesetzt werden die oberen bracketSize/2 der (vom Admin gereihten) Teilnehmer,
-- wodurch garantiert alle Freilose an gesetzte Topspieler fallen.
-- ============================================================

create or replace function public.tournament_draw(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_club uuid; v_n int; v_size int; v_rounds int;
  v_slots int[]; v_tmp int[]; v_ids uuid[];
  v_seedpos int[]; v_place uuid[]; v_shuf uuid[];
  v_seeds int; v_lo int; v_hi int; v_idx int;
  v_r int; v_s int; v_cnt int; v_sum int; v_p int; k int;
  rec record;
begin
  select club_id into v_club from tournaments where id = p_tournament_id;
  if v_club is null then raise exception 'Turnier nicht gefunden.'; end if;
  if not manages_club(v_club) then raise exception 'Keine Berechtigung.'; end if;

  -- Teilnehmer nach Reihung (ungereihte ans Ende)
  select array_agg(member_id order by seed nulls last, created_at)
    into v_ids from tournament_participants where tournament_id = p_tournament_id;
  v_n := coalesce(array_length(v_ids,1),0);
  if v_n < 2 then raise exception 'Mindestens 2 Teilnehmer nötig.'; end if;

  -- Bracketgröße / Runden
  v_size := 2; while v_size < v_n loop v_size := v_size * 2; end loop;
  v_rounds := 0; v_cnt := v_size; while v_cnt > 1 loop v_rounds := v_rounds + 1; v_cnt := v_cnt / 2; end loop;

  -- Effektive Seeds 1..n sicherstellen (auch bei fehlender/teilweiser Reihung)
  update tournament_participants p set seed = x.rn
    from (select member_id, row_number() over (order by seed nulls last, created_at) rn
          from tournament_participants where tournament_id = p_tournament_id) x
   where p.tournament_id = p_tournament_id and p.member_id = x.member_id;

  -- Standard-Setzpositionen (Position -> Seed): [1,2] -> [1,4,2,3] -> [1,8,4,5,2,7,3,6] ...
  v_slots := array[1,2];
  v_r := 1;
  while v_r < v_rounds loop
    v_tmp := '{}'::int[];
    v_sum := array_length(v_slots,1) * 2 + 1;
    foreach v_p in array v_slots loop v_tmp := v_tmp || v_p || (v_sum - v_p); end loop;
    v_slots := v_tmp;
    v_r := v_r + 1;
  end loop;

  -- Umkehrung: Seed -> Position
  v_seedpos := array_fill(0, array[v_size]);
  for k in 1 .. v_size loop v_seedpos[ v_slots[k] ] := k; end loop;

  -- Platzierung (Position -> Spieler); leere Positionen = Freilos
  v_place := array_fill(null::uuid, array[v_size]);

  -- Gesetzte = obere Hälfte der Bracketgröße (so fallen alle Freilose an Topgesetzte)
   v_seeds := v_size / 2; if  v_seeds < 1 then  v_seeds := 1; end if;

  -- Gesetzte je Tier auslosen: {1},{2},{3,4},{5-8},{9-16},...
  v_lo := 1;
  while v_lo <=  v_seeds loop
    if v_lo = 1 then v_hi := 1; else v_hi := v_lo * 2 - 2; end if;
    if v_hi >  v_seeds then v_hi := v_seeds; end if;
    select array_agg(v_ids[s] order by random()) into v_shuf from generate_series(v_lo, v_hi) s;
    v_idx := 1;
    for k in v_lo .. v_hi loop v_place[ v_seedpos[k] ] := v_shuf[v_idx]; v_idx := v_idx + 1; end loop;
    v_lo := v_hi + 1;
  end loop;

  -- Ungesetzte komplett zufällig auf die restlichen Positionen losen
  if v_n >  v_seeds then
    select array_agg(v_ids[s] order by random()) into v_shuf from generate_series( v_seeds + 1, v_n) s;
    v_idx := 1;
    for k in  v_seeds + 1 .. v_n loop v_place[ v_seedpos[k] ] := v_shuf[v_idx]; v_idx := v_idx + 1; end loop;
  end if;
  -- Positionen v_seedpos[v_n+1 .. v_size] bleiben leer = Freilose (Gegner der Topgesetzten)

  -- Matches (alle Runden) neu anlegen
  delete from tournament_matches where tournament_id = p_tournament_id;
  v_r := 1; v_cnt := v_size / 2;
  while v_r <= v_rounds loop
    for v_s in 0 .. (v_cnt - 1) loop
      insert into tournament_matches(tournament_id, club_id, round, slot)
        values (p_tournament_id, v_club, v_r, v_s);
    end loop;
    v_cnt := v_cnt / 2; v_r := v_r + 1;
  end loop;

  -- Verkettung Sieger -> Folgespiel
  update tournament_matches child
    set next_match_id = parent.id, next_slot = (child.slot % 2) + 1
    from tournament_matches parent
    where child.tournament_id = p_tournament_id and parent.tournament_id = p_tournament_id
      and parent.round = child.round + 1 and parent.slot = child.slot / 2;

  -- Runde 1 aus der Platzierung füllen
  for v_s in 0 .. (v_size / 2 - 1) loop
    update tournament_matches
      set p1_member_id = v_place[2 * v_s + 1], p2_member_id = v_place[2 * v_s + 2]
      where tournament_id = p_tournament_id and round = 1 and slot = v_s;
  end loop;

  -- Freilose (Runde 1): einziger Spieler steigt auf
  for rec in
    select * from tournament_matches
     where tournament_id = p_tournament_id and round = 1
       and ((p1_member_id is null) <> (p2_member_id is null))
  loop
    update tournament_matches set winner_member_id = coalesce(rec.p1_member_id, rec.p2_member_id) where id = rec.id;
    if rec.next_match_id is not null then
      if rec.next_slot = 1 then
        update tournament_matches set p1_member_id = coalesce(rec.p1_member_id, rec.p2_member_id) where id = rec.next_match_id;
      else
        update tournament_matches set p2_member_id = coalesce(rec.p1_member_id, rec.p2_member_id) where id = rec.next_match_id;
      end if;
    end if;
  end loop;

  update tournaments set status = 'running' where id = p_tournament_id;
end $$;

notify pgrst, 'reload schema';
