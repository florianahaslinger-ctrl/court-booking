// COURT BOOKING – Supabase "Send Email Hook"
// Supabase ruft diese Funktion für jede Auth-E-Mail auf (Registrierung
// bestätigen, Passwort zurücksetzen, Magic-Link). Wir verschicken sie über
// die Brevo-API (HTTPS) mit hellem Design – umgeht das Rate-Limit des
// eingebauten Supabase-Mailversands. Signaturprüfung nach Standard-Webhooks.
//
// Benötigte Env-Variablen (Supabase → Edge Functions → Secrets):
//   SEND_EMAIL_HOOK_SECRET  = der beim Aktivieren des Hooks erzeugte Secret (v1,whsec_...)
//   BREVO_API_KEY           = dein Brevo API-Key (kann derselbe wie bei Core sein)
//   SENDER_EMAIL            = verifizierter Brevo-Absender (z.B. office@core-management.at)
//   SENDER_NAME             = Anzeigename (z.B. "Court Booking")

const HOOK_SECRET = Deno.env.get("SEND_EMAIL_HOOK_SECRET")!;
const BREVO_KEY = Deno.env.get("BREVO_API_KEY")!;
// Muss ein in Brevo VALIDIERTER Absender sein (Brevo → Senders), sonst lehnt Brevo den Versand ab.
const SENDER_EMAIL = Deno.env.get("SENDER_EMAIL") ?? "florian.a.haslinger@gmail.com";
const SENDER_NAME = Deno.env.get("SENDER_NAME") ?? "Court Booking";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function bytesToB64(bytes: ArrayBuffer): string {
  const b = new Uint8Array(bytes);
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s);
}
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verify(body: string, headers: Headers): Promise<boolean> {
  const id = headers.get("webhook-id");
  const ts = headers.get("webhook-timestamp");
  const sigHeader = headers.get("webhook-signature");
  if (!id || !ts || !sigHeader) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  const secretB64 = HOOK_SECRET.replace(/^v1,whsec_/, "").replace(/^whsec_/, "");
  const key = await crypto.subtle.importKey(
    "raw", b64ToBytes(secretB64), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${body}`));
  const expected = bytesToB64(mac);
  for (const part of sigHeader.split(" ")) {
    const sig = part.includes(",") ? part.split(",")[1] : part;
    if (timingSafeEqual(sig, expected)) return true;
  }
  return false;
}

function esc(s: string): string {
  return String(s ?? "").replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string));
}

function buildEmail(email: string, d: Record<string, string>) {
  const token = d.token ?? "";
  const type = d.email_action_type ?? "signup";
  const redirect = d.redirect_to ?? d.site_url ?? "http://localhost:8123/konto.html";
  const verifyUrl = `${SUPABASE_URL}/auth/v1/verify?token=${encodeURIComponent(d.token_hash)}` +
    `&type=${encodeURIComponent(type)}&redirect_to=${encodeURIComponent(redirect)}`;

  let subject: string, intro: string, cta: string;
  if (type === "recovery") {
    subject = "Passwort zurücksetzen – Court Booking";
    intro = "Hier ist dein Code, um dein Passwort zurückzusetzen:";
    cta = "Passwort jetzt zurücksetzen";
  } else if (type === "signup" || type === "email" || type === "email_change") {
    subject = "Bestätige deine E-Mail – Court Booking";
    intro = "Willkommen! Bestätige deine E-Mail-Adresse, um mit dem Buchen zu starten:";
    cta = "E-Mail bestätigen &amp; loslegen";
  } else {
    subject = "Dein Anmelde-Code – Court Booking";
    intro = "Hier ist dein Anmelde-Code:";
    cta = "Direkt anmelden";
  }

  const html =
`<!DOCTYPE html><html><body style="margin:0;background:#f6f8f7;font-family:'Segoe UI',Arial,Helvetica,sans-serif;color:#17211c;padding:28px">
  <div style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #e2e8e5;border-radius:14px;padding:32px;box-shadow:0 12px 32px -18px rgba(16,32,24,.22)">
    <div style="display:flex;align-items:center;gap:9px;margin-bottom:18px">
      <span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:#2E8B57"></span>
      <span style="font-size:20px;font-weight:700;color:#17211c">Court Booking</span>
    </div>
    <p style="font-size:15px;line-height:1.6;margin:0 0 22px">${esc(intro)}</p>
    <div style="text-align:center;margin:0 0 22px">
      <a href="${esc(verifyUrl)}" style="display:inline-block;background:#2E8B57;color:#fff;text-decoration:none;
         font-weight:600;padding:13px 28px;border-radius:9px;font-size:15px">${cta}</a>
    </div>
    <p style="font-size:13px;color:#7c8a83;line-height:1.6;margin:0">Falls der Button nicht funktioniert, öffne diesen Link:<br>
      <a href="${esc(verifyUrl)}" style="color:#2E8B57;word-break:break-all">${esc(verifyUrl)}</a></p>
    <p style="font-size:12px;color:#9aa8a1;line-height:1.6;margin:14px 0 0">Wenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.</p>
  </div>
</body></html>`;

  const text = `${intro}\n\nHier bestätigen: ${verifyUrl}\n\n` +
    `Wenn du das nicht angefordert hast, ignoriere diese E-Mail.`;
  return { subject, html, text };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const body = await req.text();
  if (!(await verify(body, req.headers))) {
    return new Response(JSON.stringify({ error: "Invalid signature" }), {
      status: 401, headers: { "Content-Type": "application/json" },
    });
  }
  let payload: { user: { email: string }; email_data: Record<string, string> };
  try { payload = JSON.parse(body); } catch { return new Response("Bad payload", { status: 400 }); }

  const email = payload.user?.email;
  if (!email) return new Response("No recipient", { status: 400 });
  const { subject, html, text } = buildEmail(email, payload.email_data || {});

  const resp = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": BREVO_KEY, "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({
      sender: { name: SENDER_NAME, email: SENDER_EMAIL },
      to: [{ email }],
      subject, htmlContent: html, textContent: text,
    }),
  });
  if (!resp.ok) {
    const errTxt = await resp.text().catch(() => "");
    console.error("Brevo error", resp.status, errTxt);
    return new Response(JSON.stringify({ error: { http_code: resp.status, message: "E-Mail-Versand fehlgeschlagen" } }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
  return new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } });
});
