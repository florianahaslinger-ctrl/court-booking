// COURT BOOKING – Stripe-Checkout für eine Mitgliedschaft
// Body: { club_slug, email, plan_id }. Läuft mit service_role; kein Login nötig.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const { club_slug, email, plan_id } = await req.json() as { club_slug?: string; email?: string; plan_id?: string };
    if (!club_slug || !email || !plan_id) return json({ error: "club_slug, email und plan_id nötig." }, 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: club } = await admin.from("clubs")
      .select("id,slug,name,currency,stripe_enabled,stripe_account_id").eq("slug", club_slug).eq("active", true).maybeSingle();
    if (!club) return json({ error: "Club nicht gefunden." }, 404);
    const { data: plan } = await admin.from("membership_plans")
      .select("id,name,price,duration_days,active,club_id").eq("id", plan_id).maybeSingle();
    if (!plan || !plan.active || plan.club_id !== club.id) return json({ error: "Tarif nicht verfügbar." }, 404);
    if (Number(plan.price) <= 0) return json({ error: "Dieser Tarif ist kostenlos – keine Zahlung nötig." }, 400);

    const cur = (club.currency || "EUR").toLowerCase();
    const cents = Math.round(Number(plan.price) * 100);

    let connect = "";
    if (club.stripe_enabled && club.stripe_account_id) {
      let fee = Math.round(cents * (FEE_PERCENT / 100) + FEE_FIXED_CENTS);
      if (fee < 0) fee = 0;
      if (fee > cents - 1) fee = Math.max(0, cents - 1);
      connect =
        `&payment_intent_data[transfer_data][destination]=${club.stripe_account_id}` +
        `&payment_intent_data[on_behalf_of]=${club.stripe_account_id}` +
        `&payment_intent_data[application_fee_amount]=${fee}`;
    }

    const ret = `${SITE_URL}/konto.html?club=${encodeURIComponent(club.slug)}`;
    const body =
      `mode=payment` +
      `&metadata[type]=membership&metadata[plan_id]=${plan.id}&metadata[club_id]=${club.id}` +
      `&metadata[email]=${encodeURIComponent(email.toLowerCase())}` +
      `&customer_email=${encodeURIComponent(email)}` +
      connect +
      `&expires_at=${Math.floor(Date.now() / 1000) + 31 * 60}` +
      `&line_items[0][price_data][currency]=${cur}` +
      `&line_items[0][price_data][product_data][name]=${encodeURIComponent(`${club.name}: Mitgliedschaft ${plan.name}`)}` +
      `&line_items[0][price_data][unit_amount]=${cents}` +
      `&line_items[0][quantity]=1` +
      `&success_url=${encodeURIComponent(ret + "&mpaid=1")}` +
      `&cancel_url=${encodeURIComponent(ret + "&mcancelled=1")}`;

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
