-- ============================================================
-- Migration 04 – Sicherheit: sensible Club-Felder nicht öffentlich
-- Anonyme/Mitglieder lesen Club-Infos nur noch über die View
-- club_public (ohne owner_email, stripe_account_id, settings).
-- Die clubs-Tabelle selbst ist nur für Verwalter lesbar.
-- ============================================================

create or replace view public.club_public
with (security_invoker = off) as
  select id, slug, name, active, timezone, currency, slot_minutes,
         logo_url, primary_color,
         member_pricing_mode, member_discount_percent, member_free_max_minutes,
         booking_open_days, min_lead_minutes, cancel_lead_minutes, stripe_enabled
  from public.clubs
  where active;
grant select on public.club_public to anon, authenticated;

-- clubs-Tabelle: Lesen nur noch für Verwalter (verbirgt owner_email/stripe_account_id/settings)
drop policy if exists clubs_read on public.clubs;
create policy clubs_read on public.clubs for select using (manages_club(id));

notify pgrst, 'reload schema';
