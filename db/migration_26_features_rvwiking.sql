-- ============================================================
-- Migration 26 – Feature-Flag-Fundament + Club RV Wiking Linz
--
-- 1) clubs.features (jsonb): pro Club aktivierbare Sonderfeatures + Config.
-- 2) clubs.news_text: frei editierbarer Hinweis über der Buchungsseite.
-- 3) club_public liefert features + news_text.
-- 4) court_busy liefert zusätzlich b.kind (für „Gast"-Label & Abo-Name im Raster).
-- 5) Club „RV Wiking Linz" als Grundgerüst anlegen, Features aktiviert.
--
-- Features-Schema (jsonb), Beispiel:
--   {
--     "bulk_abo_invoice": true,     -- Sammel-Button: alle offenen Abo-Rechnungen
--     "membership_reminder": true,  -- Beitrags-Hinweis im Konto
--     "guest_label": true,          -- Gast-Buchungen im Raster als „Gast"
--     "abo_names": true,            -- Abo-Buchungen mit Namen statt „Abo · offen"
--     "topup_bonus": { "tiers": [ {"pay":90,"credit":100}, {"pay":150,"credit":175} ] }
--   }
-- ============================================================

alter table public.clubs add column if not exists features  jsonb not null default '{}'::jsonb;
alter table public.clubs add column if not exists news_text  text;

-- club_public: features + news_text mitliefern
create or replace view public.club_public
with (security_invoker = off) as
  select id, slug, name, active, timezone, currency, slot_minutes,
         logo_url, primary_color,
         member_pricing_mode, member_discount_percent, member_free_max_minutes,
         booking_open_days, min_lead_minutes, cancel_lead_minutes, stripe_enabled,
         member_pricing_mode_outdoor, member_pricing_mode_indoor,
         member_discount_percent_outdoor, member_discount_percent_indoor,
         member_free_max_minutes_outdoor, member_free_max_minutes_indoor,
         abo_payment_mode,
         youth_discount_percent, youth_max_age,
         features, news_text
  from public.clubs
  where active;
grant select on public.club_public to anon, authenticated;

-- court_busy: kind mitliefern (Raster-Label je Buchungsart)
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
          when 'subscription' then coalesce((select full_name from public.members m where m.id = b.member_id), b.guest_name, b.note, 'Abo')
          when 'member'       then coalesce((select full_name from public.members m where m.id = b.member_id), b.guest_name, 'Mitglied')
          when 'free'         then coalesce(bt.name, nullif(b.note,''), b.guest_name, 'Reserviert')
          else                     coalesce(b.guest_name, 'Gast')
         end)
        || case when coalesce(b.person_count,1) > 1 then ' +' || (b.person_count - 1) else '' end
      else null
    end as label,
    case when b.kind = 'subscription'
         then (case when b.payment_status = 'paid' or coalesce(b.price,0) = 0 then 'Abo · bezahlt' else 'Abo · offen' end)
         else bt.name end as type_name,
    case when b.kind = 'subscription'
         then (case when b.payment_status = 'paid' or coalesce(b.price,0) = 0 then '#2E8B57' else '#EAB308' end)
         else bt.color end as type_color,
    b.kind
  from public.bookings b
  left join public.booking_types bt on bt.id = b.booking_type_id
  where b.status <> 'cancelled'
    and not (b.payment_status = 'pending' and b.hold_expires_at is not null and b.hold_expires_at < now());
grant select on public.court_busy to anon, authenticated;

-- Club RV Wiking Linz anlegen (Grundgerüst; Plätze/Preise/Admins folgen im Admin-Panel)
insert into public.clubs (slug, name, owner_email, active, timezone, currency, features)
values (
  'rv-wiking-linz', 'RV Wiking Linz', 'florian.a.haslinger@gmail.com', true, 'Europe/Vienna', 'EUR',
  '{"bulk_abo_invoice":true,"membership_reminder":true,"guest_label":true,"abo_names":true,"topup_bonus":{"tiers":[{"pay":90,"credit":100},{"pay":150,"credit":175}]}}'::jsonb
)
on conflict (slug) do update
  set name = excluded.name,
      active = true,
      features = excluded.features;

notify pgrst, 'reload schema';
