-- ============================================================
-- Migration 05 – Unbezahlte Reservierung freigeben
-- Wenn ein Gast zur Stripe-Seite geht, aber nicht zahlt und zurückkommt,
-- soll der reservierte Slot sofort wieder frei werden (nicht erst nach Ablauf).
-- ============================================================
create or replace function public.release_pending_booking(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from bookings
   where id = p_id and status = 'pending' and payment_status = 'pending';
end $$;
grant execute on function public.release_pending_booking(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
