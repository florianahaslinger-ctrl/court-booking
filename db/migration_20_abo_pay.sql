-- ============================================================
-- Migration 20 – Abo-Zahlung anwenden (vom Stripe-Webhook / service_role)
-- Serie komplett ODER einzelner Wochentermin -> payment_status='paid'
-- => zugehoerige Buchungen werden gruen. Idempotent.
-- ============================================================

create or replace function public.abo_pay_apply(p_sub uuid, p_session text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update subscriptions set payment_status = 'paid',
         stripe_session_id = coalesce(p_session, stripe_session_id)
    where id = p_sub;
  update bookings set payment_status = 'paid'
    where subscription_id = p_sub and kind = 'subscription' and payment_status <> 'paid';
end $$;
revoke all on function public.abo_pay_apply(uuid,text) from public;
grant execute on function public.abo_pay_apply(uuid,text) to service_role;

create or replace function public.abo_booking_pay_apply(p_booking uuid, p_session text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update bookings set payment_status = 'paid',
         stripe_session_id = coalesce(p_session, stripe_session_id)
    where id = p_booking and kind = 'subscription';
end $$;
revoke all on function public.abo_booking_pay_apply(uuid,text) from public;
grant execute on function public.abo_booking_pay_apply(uuid,text) to service_role;

notify pgrst, 'reload schema';
