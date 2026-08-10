// COURT BOOKING – Rechnung für ein Abo per E-Mail (Brevo)
// Body: { sub_id, due_date? }. Nur Club-Verwaltung (per JWT geprüft).
// Setzt optional das Zahlungsziel und schickt dem Kunden eine Rechnung mit Zahllink.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const BREVO_KEY = Deno.env.get("BREVO_API_KEY")!;
const SENDER_EMAIL = Deno.env.get("SENDER_EMAIL") ?? "florian.a.haslinger@gmail.com";
const SENDER_NAME = Deno.env.get("SENDER_NAME") ?? "Court Booking";
const SITE_URL = (Deno.env.get("CB_SITE_URL") ?? "http://localhost:8123").replace(/\/+$/, "");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string));
const money = (v: number, cur: string) => new Intl.NumberFormat("de-AT", { style: "currency", currency: cur || "EUR" }).format(v || 0);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const { sub_id, due_date } = await req.json() as { sub_id?: string; due_date?: string };
    if (!sub_id) return json({ error: "sub_id nötig." }, 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: s } = await admin.from("subscriptions")
      .select("id,club_id,price,price_override,payment_status,guest_name,guest_email,weekday,start_time,duration_minutes,valid_from,valid_until, member:members(full_name,email), court:courts(name,environment), club:clubs(slug,name,currency)")
      .eq("id", sub_id).maybeSingle();
    if (!s) return json({ error: "Abo nicht gefunden." }, 200);

    // Berechtigung: Aufrufer muss diesen Club verwalten (per JWT)
    const auth = req.headers.get("Authorization") ?? "";
    const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } } });
    const { data: ok, error: permErr } = await asUser.rpc("manages_club", { p_club: s.club_id });
    if (permErr || ok !== true) return json({ error: "Keine Berechtigung." }, 200);

    if (s.payment_status === "paid") return json({ error: "Dieses Abo ist bereits bezahlt." }, 200);
    const price = s.price_override != null ? Number(s.price_override) : Number(s.price);
    if (!(price > 0)) return json({ error: "Für dieses Abo ist keine Zahlung nötig." }, 200);

    if (due_date) await admin.from("subscriptions").update({ due_date }).eq("id", sub_id);

    const club = s.club as any;
    const co = s.court as any;
    const mem = s.member as any;
    const email = (s.guest_email || mem?.email || "").toLowerCase();
    const name = s.guest_name || mem?.full_name || "";
    if (!email) return json({ error: "Keine Empfänger-E-Mail hinterlegt." }, 200);

    const WD = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"];
    const cur = club.currency || "EUR";
    const payUrl = `${SITE_URL}/pay.html?abo=${encodeURIComponent(sub_id)}&club=${encodeURIComponent(club.slug)}`;
    const dueTxt = due_date ? new Date(due_date).toLocaleDateString("de-AT") : null;
    const slot = `${WD[s.weekday]}s, ${String(s.start_time).slice(0, 5)} Uhr · ${co?.name ?? ""} (${co?.environment === "indoor" ? "Indoor" : "Outdoor"})`;
    const zeitraum = `${new Date(s.valid_from).toLocaleDateString("de-AT")} – ${new Date(s.valid_until).toLocaleDateString("de-AT")}`;
    const subject = `Rechnung: Abo bei ${club.name}`;

    const html =
`<!DOCTYPE html><html><body style="margin:0;background:#f6f8f7;font-family:'Segoe UI',Arial,Helvetica,sans-serif;color:#17211c;padding:28px">
  <div style="max-width:520px;margin:0 auto;background:#ffffff;border:1px solid #e2e8e5;border-radius:14px;padding:32px;box-shadow:0 12px 32px -18px rgba(16,32,24,.22)">
    <div style="display:flex;align-items:center;gap:9px;margin-bottom:18px">
      <span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:#2E8B57"></span>
      <span style="font-size:20px;font-weight:700;color:#17211c">${esc(club.name)}</span>
    </div>
    <p style="font-size:15px;line-height:1.6;margin:0 0 8px">Hallo ${esc(name) || "zusammen"},</p>
    <p style="font-size:15px;line-height:1.6;margin:0 0 18px">hier ist die Rechnung für dein Abo:</p>
    <table style="width:100%;border-collapse:collapse;font-size:14px;margin:0 0 20px">
      <tr><td style="padding:6px 0;color:#7c8a83">Slot</td><td style="padding:6px 0;text-align:right">${esc(slot)}</td></tr>
      <tr><td style="padding:6px 0;color:#7c8a83">Zeitraum</td><td style="padding:6px 0;text-align:right">${esc(zeitraum)}</td></tr>
      <tr><td style="padding:6px 0;color:#7c8a83;border-top:1px solid #eef2f0">Betrag</td><td style="padding:6px 0;text-align:right;border-top:1px solid #eef2f0;font-weight:700">${esc(money(price, cur))}</td></tr>
      ${dueTxt ? `<tr><td style="padding:6px 0;color:#7c8a83">Zahlbar bis</td><td style="padding:6px 0;text-align:right">${esc(dueTxt)}</td></tr>` : ""}
    </table>
    <div style="text-align:center;margin:0 0 20px">
      <a href="${esc(payUrl)}" style="display:inline-block;background:#2E8B57;color:#fff;text-decoration:none;font-weight:600;padding:13px 30px;border-radius:9px;font-size:15px">Jetzt sicher online bezahlen</a>
    </div>
    <p style="font-size:13px;color:#7c8a83;line-height:1.6;margin:0">Falls der Button nicht funktioniert, öffne diesen Link:<br>
      <a href="${esc(payUrl)}" style="color:#2E8B57;word-break:break-all">${esc(payUrl)}</a></p>
  </div>
</body></html>`;
    const text = `Rechnung für dein Abo bei ${club.name}\n${slot}\nZeitraum: ${zeitraum}\nBetrag: ${money(price, cur)}${dueTxt ? `\nZahlbar bis: ${dueTxt}` : ""}\n\nJetzt bezahlen: ${payUrl}`;

    const resp = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": BREVO_KEY, "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({ sender: { name: SENDER_NAME, email: SENDER_EMAIL }, to: [{ email, name }], subject, htmlContent: html, textContent: text }),
    });
    if (!resp.ok) {
      const t = await resp.text().catch(() => "");
      console.error("Brevo error", resp.status, t);
      return json({ error: "E-Mail-Versand fehlgeschlagen." }, 502);
    }
    return json({ ok: true, sent_to: email });
  } catch (e) {
    console.error(e);
    return json({ error: "Interner Fehler: " + (e as Error).message }, 500);
  }
});
