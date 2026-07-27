# E-Mail-Versand einrichten (Brevo + Supabase Send Email Hook)

Damit Bestätigungs-/Passwort-Mails **zuverlässig ohne Rate-Limit** verschickt werden,
übernimmt eine Edge Function den Versand über **Brevo** — genau wie beim Core-Ticketshop.
Du kannst deinen **bestehenden Brevo-Account** und den **verifizierten Absender**
`office@core-management.at` wiederverwenden.

Alles unten passiert im Supabase-Dashboard deines neuen Projekts — **kein Terminal nötig**.

---

## 1. Edge Function anlegen
1. Supabase → **Edge Functions** → **Create a function** (oder „Deploy a new function").
2. Name exakt: `send-auth-email`
3. Den kompletten Inhalt von `supabase/functions/send-auth-email/index.ts` in den Editor einfügen.
4. **Wichtig:** „**Verify JWT**" für diese Funktion **ausschalten** (Supabase ruft sie als Webhook auf, ohne User-Token).
5. **Deploy**.

## 2. Secrets setzen
Supabase → **Edge Functions** → **Secrets** (bzw. Project Settings → Edge Functions) → folgende hinzufügen:

| Name | Wert |
|------|------|
| `BREVO_API_KEY` | dein Brevo API-Key (Brevo → SMTP & API → API Keys; der von Core geht auch) |
| `SENDER_EMAIL` | `office@core-management.at` (oder ein anderer in Brevo verifizierter Absender) |
| `SENDER_NAME` | `Court Booking` |

`SUPABASE_URL` ist automatisch vorhanden — nicht selbst setzen.
`SEND_EMAIL_HOOK_SECRET` kommt in Schritt 3.

## 3. Send Email Hook aktivieren
1. Supabase → **Authentication** → **Hooks** (bzw. **Emails → Hook**).
2. **Send Email Hook** → **Enable**.
3. Typ: **HTTPS / Edge Function**, URI:
   `https://aagzfijbxujkbjxccbno.supabase.co/functions/v1/send-auth-email`
4. Supabase zeigt dir ein **Signing Secret** (Format `v1,whsec_...`) → **kopieren**.
5. Zurück zu **Edge Functions → Secrets**: neuen Secret anlegen
   `SEND_EMAIL_HOOK_SECRET` = das kopierte Secret.

## 4. E-Mail-Bestätigung wieder einschalten
Supabase → **Authentication** → **Providers** → **Email** → **Confirm email** wieder **AN**.

## Fertig – Test
- `login.html` → Registrieren mit deiner Mail → es kommt eine **helle Court-Booking-Mail** von Brevo.
- Link/Code bestätigt die Adresse → einloggen → fertig.

> Hinweis: Solange Schritt 1–3 nicht aktiv sind, nutzt Supabase seinen eigenen (limitierten)
> Mailversand. Sobald der Hook aktiv ist, läuft **alles über Brevo** und das Rate-Limit ist weg.

---

## Alternative: Ich deploye es für dich (CLI)
Wenn du mir einen **Supabase Access-Token** (Account → Access Tokens) gibst, erledige ich
Schritt 1–2 per CLI:
```
npx supabase functions deploy send-auth-email --project-ref aagzfijbxujkbjxccbno --no-verify-jwt
npx supabase secrets set BREVO_API_KEY=... SENDER_EMAIL=office@core-management.at SENDER_NAME="Court Booking"
```
Schritt 3 (Hook aktivieren) bleibt ein Dashboard-Klick, weil Supabase dort das Signing-Secret erzeugt.
