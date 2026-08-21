// COURT BOOKING – Stripe-Checkout zum Aufladen von Guthaben (Wallet)
// Body: { club_slug, email, amount }  (amount in EUR, z.B. 50)
// Läuft mit service_role; kein Login nötig (Einzahlen ist ungefährlich).
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
    const { club_slug, email, amount } = await req.json() as { club_slug?: string; email?: string; amount?: number };
    const mail = (email ?? "").trim().toLowerCase();
    const eur = Number(amount);
    if (!club_slug || !mail || !mail.includes("@")) return json({ error: "Club und gültige E-Mail nötig." }, 400);
    if (!(eur >= 5) || eur > 1000) return json({ error: "Betrag zwischen 5 und 1000 € angeben." }, 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: club } = await admin.from("clubs")
      .select("id,slug,name,currency,stripe_enabled,stripe_account_id,features").eq("slug", club_slug).maybeSingle();
    if (!club) return json({ error: "Club nicht gefunden." }, 404);
    if (!club.stripe_enabled || !club.stripe_account_id)
      return json({ error: "Dieser Club hat Online-Zahlungen noch nicht eingerichtet." }, 400);

    // Bonus-Aufladung: Wenn der gezahlte Betrag exakt einer konfigurierten Stufe entspricht,
    // wird ein höherer Guthaben-Betrag gutgeschrieben (z. B. 90 € zahlen → 100 € Guthaben).
    let creditEur = eur;
    const tiers = (club as { features?: { topup_bonus?: { tiers?: Array<{ pay: number; credit: number }> } } })
      .features?.topup_bonus?.tiers;
    if (Array.isArray(tiers)) {
      const t = tiers.find((x) => Number(x.pay) === eur);
      if (t && Number(t.credit) > 0) creditEur = Number(t.credit);
    }

    const cur = (club.currency || "EUR").toLowerCase();
    const cents = Math.round(eur * 100);
    const prodName = creditEur > eur
      ? `Guthaben-Aufladung ${club.name} – ${creditEur} € Guthaben (Bonus)`
      : `Guthaben-Aufladung ${club.name}`;
    let fee = Math.round(cents * (FEE_PERCENT / 100) + FEE_FIXED_CENTS);
    if (fee < 0) fee = 0;
    if (fee > cents - 1) fee = Math.max(0, cents - 1);

    const ret = `${SITE_URL}/konto.html?club=${encodeURIComponent(club.slug)}`;
    const body =
      `mode=payment` +
      `&metadata[type]=topup&metadata[club_id]=${club.id}&metadata[email]=${encodeURIComponent(mail)}&metadata[amount]=${eur}&metadata[credit]=${creditEur}` +
      `&customer_email=${encodeURIComponent(mail)}` +
      `&payment_intent_data[transfer_data][destination]=${club.stripe_account_id}` +
      `&payment_intent_data[on_behalf_of]=${club.stripe_account_id}` +
      `&payment_intent_data[application_fee_amount]=${fee}` +
      `&expires_at=${Math.floor(Date.now() / 1000) + 31 * 60}` +
      `&line_items[0][price_data][currency]=${cur}` +
      `&line_items[0][price_data][product_data][name]=${encodeURIComponent(prodName)}` +
      `&line_items[0][price_data][unit_amount]=${cents}` +
      `&line_items[0][quantity]=1` +
      `&success_url=${encodeURIComponent(ret + "&topup=1")}` +
      `&cancel_url=${encodeURIComponent(ret + "&topup_cancelled=1")}`;

    const resp = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: { Authorization: "Bearer " + STRIPE_KEY, "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    const session = await resp.json();
    if (!resp.ok) {
      console.error("Stripe error:", session);
      return json({ error: "Aufladung konnte nicht gestartet werden: " + (session?.error?.message ?? resp.status) }, 502);
    }
    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: "Interner Fehler: " + (e as Error).message }, 500);
  }
});
