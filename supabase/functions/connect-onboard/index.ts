// COURT BOOKING – Stripe Connect (Express) Onboarding je Club
// action "status": verbundenes Konto prüfen/aktualisieren (charges_enabled)
// action "link":   Konto anlegen (falls nötig) und Onboarding-Link zurückgeben
// Body: { action, club_id }
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const SITE_URL = (Deno.env.get("CB_SITE_URL") ?? "http://localhost:8123").replace(/\/+$/, "");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

async function stripe(path: string, method: string, body?: string) {
  const resp = await fetch("https://api.stripe.com/v1/" + path, {
    method,
    headers: { Authorization: "Bearer " + STRIPE_KEY, "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const data = await resp.json();
  if (!resp.ok) throw new Error(data?.error?.message ?? ("Stripe " + resp.status));
  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: userData, error: userErr } = await admin.auth.getUser(authHeader.replace(/^Bearer\s+/i, ""));
    if (userErr || !userData?.user?.email) return json({ error: "Bitte anmelden." }, 401);
    const email = userData.user.email.toLowerCase();

    const { action, club_id } = (await req.json().catch(() => ({}))) as { action?: string; club_id?: string };
    if (!club_id) return json({ error: "club_id fehlt." }, 400);

    // Berechtigung: head_admin ODER club_admin genau dieses Clubs
    const { data: me } = await admin.from("app_admins").select("role,club_id").eq("email", email).maybeSingle();
    const allowed = me && (me.role === "head_admin" || (me.role === "club_admin" && me.club_id === club_id));
    if (!allowed) return json({ error: "Keine Berechtigung für diesen Club." }, 403);

    const { data: club } = await admin.from("clubs").select("id,slug,name,stripe_account_id,stripe_enabled").eq("id", club_id).maybeSingle();
    if (!club) return json({ error: "Club nicht gefunden." }, 404);

    let acct = club.stripe_account_id as string | null;

    if (!acct && action === "link") {
      const created = await stripe("accounts", "POST",
        "type=express&country=AT&email=" + encodeURIComponent(email) +
        "&business_type=company" +
        "&capabilities[card_payments][requested]=true&capabilities[transfers][requested]=true" +
        "&metadata[club_id]=" + encodeURIComponent(club_id));
      acct = created.id;
      await admin.from("clubs").update({ stripe_account_id: acct }).eq("id", club_id);
    }

    let chargesEnabled = false;
    if (acct) {
      const a = await stripe("accounts/" + acct, "GET");
      chargesEnabled = !!a.charges_enabled;
      if (chargesEnabled !== club.stripe_enabled) {
        await admin.from("clubs").update({ stripe_enabled: chargesEnabled }).eq("id", club_id);
      }
    }

    if (action === "link") {
      const ret = `${SITE_URL}/admin.html?club=${encodeURIComponent(club.slug)}&stripe=return`;
      const link = await stripe("account_links", "POST",
        "account=" + acct + "&type=account_onboarding" +
        "&refresh_url=" + encodeURIComponent(ret) + "&return_url=" + encodeURIComponent(ret));
      return json({ url: link.url, hasAccount: !!acct, chargesEnabled });
    }

    return json({ hasAccount: !!acct, chargesEnabled });
  } catch (e) {
    const m = (e as Error).message || "";
    if (/platform.?profile|managing losses|responsibilities/i.test(m)) {
      return json({ error: "Die Stripe-Plattform ist noch nicht vollständig eingerichtet (Connect-Profil). Bitte im Stripe-Dashboard unter Connect abschließen." }, 503);
    }
    console.error(e);
    return json({ error: "Fehler bei der Stripe-Verbindung: " + m }, 500);
  }
});
