// COURT BOOKING – Stripe-Webhook
// Verifiziert die Stripe-Signatur und bestätigt die Buchung nach erfolgreicher Zahlung.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

async function verifySignature(payload: string, header: string): Promise<boolean> {
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=") as [string, string]));
  const t = parts["t"], v1 = parts["v1"];
  if (!t || !v1) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${payload}`));
  const hex = Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, "0")).join("");
  if (hex.length !== v1.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ v1.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const payload = await req.text();
  const sig = req.headers.get("stripe-signature") ?? "";
  if (!(await verifySignature(payload, sig))) return new Response("Invalid signature", { status: 400 });

  const event = JSON.parse(payload);
  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  if (event.type === "checkout.session.completed") {
    const session = event.data.object;
    if (session.payment_status !== "paid")
      return new Response(JSON.stringify({ received: true, ignored: "not paid" }), { status: 200 });

    // Guthaben-Aufladung (Wallet) statt Buchung
    const md = session.metadata ?? {};
    if (md.type === "topup") {
      const { error } = await admin.rpc("wallet_topup_apply", {
        p_club: md.club_id, p_email: md.email, p_amount: Number(md.amount), p_session: session.id,
      });
      if (error) { console.error("topup apply error:", error); return new Response("topup error", { status: 500 }); }
      return new Response(JSON.stringify({ received: true, topup: md.email }), { status: 200 });
    }

    // Online-Mitgliedschaft
    if (md.type === "membership") {
      const { error } = await admin.rpc("membership_pay_apply", {
        p_plan: md.plan_id, p_email: md.email, p_session: session.id,
      });
      if (error) { console.error("membership apply error:", error); return new Response("membership error", { status: 500 }); }
      return new Response(JSON.stringify({ received: true, membership: md.email }), { status: 200 });
    }

    const bookingId = session.metadata?.booking_id ?? session.client_reference_id;
    if (!bookingId) return new Response("Missing booking id", { status: 400 });

    const { data: bk } = await admin.from("bookings").select("id,status,payment_status").eq("id", bookingId).maybeSingle();
    if (!bk) return new Response("Booking not found", { status: 404 });
    if (bk.payment_status === "paid")
      return new Response(JSON.stringify({ received: true, already: true }), { status: 200 });

    await admin.from("bookings").update({
      status: "confirmed", payment_status: "paid", hold_expires_at: null,
      stripe_session_id: session.id,
    }).eq("id", bookingId);
    return new Response(JSON.stringify({ received: true, booking: bookingId }), { status: 200 });
  }

  // Abgelaufene/abgebrochene Session -> Reservierung sofort freigeben
  if (event.type === "checkout.session.expired") {
    const bookingId = event.data.object?.metadata?.booking_id;
    if (bookingId) {
      await admin.from("bookings").delete()
        .eq("id", bookingId).eq("payment_status", "pending");
    }
    return new Response(JSON.stringify({ received: true, released: bookingId ?? null }), { status: 200 });
  }

  return new Response(JSON.stringify({ received: true }), { status: 200 });
});
