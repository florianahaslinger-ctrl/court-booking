-- ============================================================
-- Migration 03 – Abo-Automatik
-- Erzeugt aus subscriptions die wiederkehrenden Buchungen
-- (kind='subscription'). Läuft täglich per pg_cron + auf Knopfdruck.
-- ============================================================

-- Kern-Generator: erzeugt fehlende Abo-Buchungen für die nächsten p_days Tage.
--   p_club = null  -> alle Clubs (für den Cron-Job)
--   p_club = uuid  -> nur dieser Club
create or replace function public.gen_subscription_bookings(p_club uuid default null, p_days int default 21)
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
          exception when exclusion_violation then
            null; -- Slot bereits belegt -> Termin überspringen
          end;
        end if;
      end if;
      d := d + 1;
    end loop;
  end loop;
  return created;
end $$;

-- Kern-Funktion NICHT öffentlich aufrufbar (nur Cron/Service)
revoke execute on function public.gen_subscription_bookings(uuid,int) from public;

-- Öffentlicher Wrapper für Admins: nur für den eigenen Club
create or replace function public.generate_my_subscriptions(p_club uuid)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not manages_club(p_club) then raise exception 'Keine Berechtigung für diesen Club.'; end if;
  return gen_subscription_bookings(p_club, 21);
end $$;
grant execute on function public.generate_my_subscriptions(uuid) to authenticated;

-- Täglicher Cron-Job (03:15) – füllt rollierend die nächsten 21 Tage
create extension if not exists pg_cron;
do $$ begin perform cron.unschedule('gen-subscriptions-daily'); exception when others then null; end $$;
select cron.schedule('gen-subscriptions-daily', '15 3 * * *',
  $j$ select public.gen_subscription_bookings(null, 21); $j$);

notify pgrst, 'reload schema';
