-- ============================================================
-- Migration 23 – Abo-Serie sofort vollständig erzeugen
--
-- Bisher erzeugte create_abo nur die naechsten 21 Tage an Buchungen und
-- verliess sich auf den taeglichen Cron-Job. Fuer ein bezahltes Abo
-- (z.B. 50-Stunden-Kontingent = 50 Wochentermine) muessen aber ALLE
-- Slots sofort reserviert sein, sonst kann jemand anders sie belegen.
--
-- Neue Helfer-Funktion gen_subscription_bookings_one erzeugt die
-- komplette Serie fuer EIN Abo (ohne Nebenwirkung auf andere Abos des
-- Clubs). create_abo ruft sie am Ende auf.
-- ============================================================

create or replace function public.gen_subscription_bookings_one(p_sub uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  s record; d date; d0 date := current_date; created int := 0;
  v_start timestamptz; v_end timestamptz;
  v_is_member boolean; v_factor numeric; v_unit numeric; v_price numeric; v_pay text;
begin
  select sub.*, c.timezone as club_tz, co.environment as court_env, co.price_per_hour as court_price,
         case when co.environment='indoor' then c.member_pricing_mode_indoor    else c.member_pricing_mode_outdoor    end as mmode,
         case when co.environment='indoor' then c.member_discount_percent_indoor else c.member_discount_percent_outdoor end as mdisc
    into s
    from subscriptions sub
    join clubs c   on c.id  = sub.club_id
    join courts co on co.id = sub.court_id
   where sub.id = p_sub and sub.active;
  if not found then return 0; end if;

  v_is_member := s.member_id is not null and exists (select 1 from members m where m.id = s.member_id and m.active);
  v_factor := case when not v_is_member then 1
                   else case s.mmode when 'free' then 0
                                     when 'discount' then (100 - coalesce(s.mdisc,0))::numeric / 100
                                     else 1 end end;
  d := greatest(d0, s.valid_from);
  while d <= s.valid_until loop          -- volle Laufzeit, kein 21-Tage-Deckel
    if extract(dow from d)::int = s.weekday then
      v_start := (d::text || ' ' || s.start_time::text)::timestamp at time zone s.club_tz;
      v_end   := v_start + make_interval(mins => s.duration_minutes);
      if not exists (select 1 from bookings b where b.subscription_id = s.id and b.start_at = v_start) then
        v_unit  := public._slot_unit_price(s.club_id, s.court_env, s.court_price, v_start, s.club_tz, s.duration_minutes);
        v_price := round(v_unit * v_factor, 2);
        v_pay := case when v_price <= 0 then 'paid'
                      when s.payment_mode = 'series' then (case when s.payment_status = 'paid' then 'paid' else 'pending' end)
                      else 'pending' end;
        begin
          insert into bookings(club_id, court_id, kind, status, start_at, end_at,
                               member_id, guest_name, guest_email, price, payment_status, subscription_id)
          values (s.club_id, s.court_id, 'subscription', 'confirmed', v_start, v_end,
                  s.member_id, s.guest_name, s.guest_email, v_price, v_pay, s.id);
          created := created + 1;
        exception when exclusion_violation then null;  -- Slot belegt -> ueberspringen
        end;
      end if;
    end if;
    d := d + 1;
  end loop;
  return created;
end $$;
revoke execute on function public.gen_subscription_bookings_one(uuid) from public;
grant execute on function public.gen_subscription_bookings_one(uuid) to service_role;

-- create_abo: komplette Serie sofort erzeugen (statt nur 21 Tage).
create or replace function public.create_abo(
  p_club_slug text, p_court uuid, p_weekday int, p_start_time time, p_duration_minutes int,
  p_valid_from date, p_valid_until date default null, p_guest_name text default null,
  p_guest_email text default null, p_total_hours numeric default null
) returns json language plpgsql security definer set search_path = public as $$
declare
  v_club clubs; v_court courts; v_email text := public.jwt_email(); v_authed boolean := (public.jwt_email() <> '');
  v_member members; v_is_member boolean := false; v_factor numeric; v_total numeric := 0;
  d date; v_from date; v_until date; v_sessions int; v_start timestamptz; v_mode text; v_status text; v_id uuid;
begin
  select * into v_club from clubs where slug = p_club_slug and active;
  if not found then raise exception 'Club nicht gefunden.'; end if;
  select * into v_court from courts where id = p_court and club_id = v_club.id and active;
  if not found then raise exception 'Platz nicht gefunden.'; end if;
  if p_weekday < 0 or p_weekday > 6 then raise exception 'Ungültiger Wochentag.'; end if;
  if p_duration_minutes <= 0 then raise exception 'Ungültige Dauer.'; end if;

  v_from := greatest(p_valid_from, current_date);

  if p_total_hours is not null and p_total_hours > 0 then
    v_sessions := ceil(p_total_hours * 60.0 / p_duration_minutes)::int;
    if v_sessions < 1 then v_sessions := 1; end if;
    if v_sessions > 520 then raise exception 'Maximal 520 Termine (~10 Jahre) pro Abo.'; end if;
    d := v_from;
    while extract(dow from d)::int <> p_weekday loop d := d + 1; end loop;
    v_from  := d;
    v_until := d + (7 * (v_sessions - 1));
  else
    if p_valid_until is null then raise exception 'Bitte Enddatum oder Stundenkontingent angeben.'; end if;
    if p_valid_until < p_valid_from then raise exception 'Enddatum vor Startdatum.'; end if;
    if p_valid_until < current_date then raise exception 'Zeitraum liegt in der Vergangenheit.'; end if;
    v_until := p_valid_until;
  end if;

  if v_authed then
    select * into v_member from members
      where club_id = v_club.id and lower(email) = v_email and active
        and (valid_until is null or valid_until >= current_date);
    if found then v_is_member := true; end if;
  end if;
  if not v_is_member then
    if coalesce(nullif(trim(p_guest_email),''),'') = '' or coalesce(nullif(trim(p_guest_name),''),'') = '' then
      raise exception 'Für Gast-Abos sind Name und E-Mail nötig.';
    end if;
  end if;

  v_factor := case when not v_is_member then 1
    else case (case when v_court.environment='indoor' then v_club.member_pricing_mode_indoor else v_club.member_pricing_mode_outdoor end)
      when 'free' then 0
      when 'discount' then (100 - coalesce(case when v_court.environment='indoor' then v_club.member_discount_percent_indoor else v_club.member_discount_percent_outdoor end,0))::numeric/100
      else 1 end end;

  d := v_from;
  while d <= v_until loop
    if extract(dow from d)::int = p_weekday then
      v_start := (d::text || ' ' || p_start_time::text)::timestamp at time zone v_club.timezone;
      v_total := v_total + public._slot_unit_price(v_club.id, v_court.environment, v_court.price_per_hour, v_start, v_club.timezone, p_duration_minutes) * v_factor;
    end if;
    d := d + 1;
  end loop;
  v_total := round(v_total, 2);

  v_mode := coalesce(v_club.abo_payment_mode, 'series');
  v_status := case when v_total <= 0 then 'paid' else 'unpaid' end;

  insert into subscriptions(club_id, member_id, court_id, weekday, start_time, duration_minutes,
        valid_from, valid_until, guest_name, guest_email, price, payment_mode, payment_status, created_by)
    values (v_club.id, case when v_is_member then v_member.id end, v_court.id, p_weekday, p_start_time, p_duration_minutes,
        v_from, v_until,
        case when v_is_member then null else p_guest_name end,
        case when v_is_member then lower(v_member.email) else lower(p_guest_email) end,
        v_total, v_mode, v_status, nullif(v_email,''))
    returning id into v_id;

  perform public.gen_subscription_bookings_one(v_id);   -- ALLE Termine sofort erzeugen

  return json_build_object('id', v_id, 'price', v_total, 'payment_mode', v_mode,
                           'payment_status', v_status, 'is_member', v_is_member, 'currency', v_club.currency);
end $$;
grant execute on function public.create_abo(text,uuid,int,time,int,date,date,text,text,numeric) to anon, authenticated;

notify pgrst, 'reload schema';
