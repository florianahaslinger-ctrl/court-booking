// COURT BOOKING – Stripe-Checkout für eine Gäste-Buchung
// Wird nach create_booking (Status 'pending', Preis > 0) aufgerufen und gibt
// die Stripe-Bezahl-URL zurück. Läuft mit service_role; kein Login nötig.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const SITE_URL = (Deno.env.get("CB_SITE_URL") ?? "http://localhost:8123").replace(/\/+$/, "");
// Plattform-Servicegebühr (wird dem Club vom Auszahlungsbetrag abgezogen):
const FEE_PERCENT = Number(Deno.env.get("PLATFORM_FEE_PERCENT") ?? "3.5");
const FEE_FIXED_CENTS = Number(Deno.env.get("PLATFORM_FEE_FIXED_CENTS") ?? "25");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const { booking_id } = await req.json() as { booking_id?: string };
    if (!booking_id) return json({ error: "booking_id fehlt." }, 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: b } = await admin.from("bookings")
      .select("id,price,status,payment_status,start_at,end_at,guest_email,guest_name,hold_expires_at, court:courts(name,environment), club:clubs(slug,name,currency,stripe_enabled,stripe_account_id)")
      .eq("id", booking_id).maybeSingle();

    if (!b) return json({ error: "Buchung nicht gefunden." }, 404);
    if (b.payment_status === "paid" || b.status === "confirmed")
      return json({ error: "Buchung ist bereits bezahlt." }, 409);
    if (b.payment_status !== "pending" || Number(b.price) <= 0)
      return json({ error: "Für diese Buchung ist keine Zahlung nötig." }, 400);
    if (b.hold_expires_at && new Date(b.hold_expires_at) < new Date())
      return json({ error: "Die Reservierung ist abgelaufen. Bitte erneut buchen." }, 410);

    const court = b.court as unknown as { name: string; environment: string };
    const club = b.club as unknown as {
      slug: string; name: string; currency: string; stripe_enabled: boolean; stripe_account_id: string | null;
    };
    const cur = (club.currency || "EUR").toLowerCase();
    const cents = Math.round(Number(b.price) * 100);
    const start = new Date(b.start_at);
    const when = start.toLocaleString("de-AT", { dateStyle: "medium", timeStyle: "short", timeZone: "Europe/Vienna" });
    const title = `${court.name} (${court.environment === "indoor" ? "Indoor" : "Outdoor"}) – ${when}`;

    // Stripe Connect: an das Club-Konto auszahlen, falls eingerichtet.
    // Gebührenmodell "Club trägt": unsere application fee geht ans Plattform-Konto,
    // on_behalf_of=Club macht den Club zum Settlement-Merchant (Club trägt auch die Stripe-Gebühr).
    let connect = "";
    if (club.stripe_enabled && club.stripe_account_id) {
      let fee = Math.round(cents * (FEE_PERCENT / 100) + FEE_FIXED_CENTS);
      if (fee < 0) fee = 0;
      if (fee > cents - 1) fee = Math.max(0, cents - 1); // application fee muss < Gesamtbetrag sein
      connect =
        `&payment_intent_data[transfer_data][destination]=${club.stripe_account_id}` +
        `&payment_intent_data[on_behalf_of]=${club.stripe_account_id}` +
        `&payment_intent_data[application_fee_amount]=${fee}`;
    }

    const ret = `${SITE_URL}/index.html?club=${encodeURIComponent(club.slug)}`;
    const body =
      `mode=payment&client_reference_id=${b.id}` +
      `&metadata[booking_id]=${b.id}` +
      (b.guest_email ? `&customer_email=${encodeURIComponent(b.guest_email)}` : "") +
      connect +
      `&expires_at=${Math.floor(Date.now() / 1000) + 31 * 60}` +
      `&line_items[0][price_data][currency]=${cur}` +
      `&line_items[0][price_data][product_data][name]=${encodeURIComponent(`${club.name}: ${title}`)}` +
      `&line_items[0][price_data][unit_amount]=${cents}` +
      `&line_items[0][quantity]=1` +
      `&success_url=${encodeURIComponent(ret + "&paid=1")}` +
      `&cancel_url=${encodeURIComponent(ret + "&cancelled=1")}`;

    const resp = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: { Authorization: "Bearer " + STRIPE_KEY, "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    const session = await resp.json();
    if (!resp.ok) {
      console.error("Stripe error:", session);
      return json({ error: "Zahlung konnte nicht gestartet werden: " + (session?.error?.message ?? resp.status) }, 502);
    }
    await admin.from("bookings").update({ stripe_session_id: session.id }).eq("id", b.id);
    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: "Interner Fehler: " + (e as Error).message }, 500);
  }
});
