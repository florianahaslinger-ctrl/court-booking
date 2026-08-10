// COURT BOOKING – Stripe-Checkout für ein Abo
// Body: { sub_id }  -> ganze Serie (Zahlmodus 'series')
//       { abo_booking_id } -> einzelner Wochentermin (Zahlmodus 'weekly')
// Läuft mit service_role; kein Login nötig (Gäste zahlen per Link).
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const SITE_URL = (Deno.env.get("CB_SITE_URL") ?? "http://localhost:8123").replace(/\/+$/, "");
const FEE_PERCENT = Number(Deno.env.get("PLATFORM_FEE_PERCENT") ?? "3.5");
const FEE_FIXED_CENTS = Number(Deno.env.get("PLATFORM_FEE_FIXED_CENTS") ?? "25");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

function connectParams(club: { stripe_enabled: boolean; stripe_account_id: string | null }, cents: number) {
  if (!(club.stripe_enabled && club.stripe_account_id)) return "";
  let fee = Math.round(cents * (FEE_PERCENT / 100) + FEE_FIXED_CENTS);
  if (fee < 0) fee = 0;
  if (fee > cents - 1) fee = Math.max(0, cents - 1);
  return `&payment_intent_data[transfer_data][destination]=${club.stripe_account_id}` +
    `&payment_intent_data[on_behalf_of]=${club.stripe_account_id}` +
    `&payment_intent_data[application_fee_amount]=${fee}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const { sub_id, abo_booking_id } = await req.json() as { sub_id?: string; abo_booking_id?: string };
    if (!sub_id && !abo_booking_id) return json({ error: "sub_id oder abo_booking_id nötig." }, 400);
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    let cents = 0, email = "", metaExtra = "", title = "", club: any = null, cur = "eur";

    if (sub_id) {
      const { data: s } = await admin.from("subscriptions")
        .select("id,club_id,price,price_override,payment_status,guest_email,weekday,start_time, member:members(email), court:courts(name,environment), club:clubs(slug,name,currency,stripe_enabled,stripe_account_id)")
        .eq("id", sub_id).maybeSingle();
      if (!s) return json({ error: "Abo nicht gefunden." }, 404);
      if (s.payment_status === "paid") return json({ error: "Dieses Abo ist bereits bezahlt." }, 409);
      const price = s.price_override != null ? Number(s.price_override) : Number(s.price);
      if (!(price > 0)) return json({ error: "Für dieses Abo ist keine Zahlung nötig." }, 400);
      club = s.club;
      cur = (club.currency || "EUR").toLowerCase();
      cents = Math.round(price * 100);
      email = (s.guest_email || (s.member as any)?.email || "").toLowerCase();
      const co = s.court as any;
      title = `Abo: ${co?.name ?? "Platz"} (${co?.environment === "indoor" ? "Indoor" : "Outdoor"})`;
      metaExtra = `&metadata[type]=abo&metadata[sub_id]=${s.id}&metadata[club_id]=${s.club_id}`;
    } else {
      const { data: b } = await admin.from("bookings")
        .select("id,price,payment_status,kind,start_at,guest_email, member:members(email), court:courts(name,environment), club:clubs(slug,name,currency,stripe_enabled,stripe_account_id)")
        .eq("id", abo_booking_id).eq("kind", "subscription").maybeSingle();
      if (!b) return json({ error: "Termin nicht gefunden." }, 404);
      if (b.payment_status === "paid") return json({ error: "Dieser Termin ist bereits bezahlt." }, 409);
      const price = Number(b.price);
      if (!(price > 0)) return json({ error: "Für diesen Termin ist keine Zahlung nötig." }, 400);
      club = b.club;
      cur = (club.currency || "EUR").toLowerCase();
      cents = Math.round(price * 100);
      email = (b.guest_email || (b.member as any)?.email || "").toLowerCase();
      const co = b.court as any;
      const when = new Date(b.start_at).toLocaleString("de-AT", { dateStyle: "medium", timeStyle: "short", timeZone: "Europe/Vienna" });
      title = `Abo-Termin: ${co?.name ?? "Platz"} – ${when}`;
      metaExtra = `&metadata[type]=abo_week&metadata[abo_booking_id]=${b.id}`;
    }

    const ret = `${SITE_URL}/index.html?club=${encodeURIComponent(club.slug)}`;
    const body =
      `mode=payment` +
      metaExtra +
      (email ? `&customer_email=${encodeURIComponent(email)}` : "") +
      connectParams(club, cents) +
      `&expires_at=${Math.floor(Date.now() / 1000) + 31 * 60}` +
      `&line_items[0][price_data][currency]=${cur}` +
      `&line_items[0][price_data][product_data][name]=${encodeURIComponent(`${club.name}: ${title}`)}` +
      `&line_items[0][price_data][unit_amount]=${cents}` +
      `&line_items[0][quantity]=1` +
      `&success_url=${encodeURIComponent(ret + "&abopaid=1")}` +
      `&cancel_url=${encodeURIComponent(ret + "&abocancelled=1")}`;

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
    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: "Interner Fehler: " + (e as Error).message }, 500);
  }
});
