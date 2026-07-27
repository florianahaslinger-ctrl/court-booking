# Court Booking – Tennisplatz-Buchungssystem

Multi-Mandanten-Buchungssystem für Tennisplätze. Teil der **Core-Management**-Produktfamilie,
aber mit eigener Datenbank, eigenem Repo/Domain und **hellem Design**.

Verkaufsmodell: Ein System, viele Tennisplätze als zahlende Mandanten (Clubs).

## Rollen (zweistufiges Admin-Menü)

| Rolle | Wer | Kann |
|-------|-----|------|
| `head_admin` | **Du** (Betreiber) | Alle Clubs sehen/verwalten, Clubs anlegen, Plattform-Einstellungen |
| `club_admin` | Tennisplatz-Betreiber | Nur eigenen Club: Plätze, Öffnungszeiten, Slot-Länge, Preise, Mitglieder, Abos, Sperren, Gratis-Buchungen |
| `member` | Mitglied | Login (E-Mail+Passwort), gratis/vergünstigt buchen, eigene Buchungen & Abo sehen |
| `guest` | ohne Login | Indoor/Outdoor wählen, buchen, **online mit Stripe zahlen** |

## „Alles variabel" – pro Club konfigurierbar
- **Slot-Länge** (`clubs.slot_minutes`, 15–240 min)
- **Öffnungszeiten** je Wochentag (`opening_hours`)
- **Preise** pro Platz und Stunde (`courts.price_per_hour`), Indoor/Outdoor getrennt
- **Mitglieder-Modell** (`clubs.member_pricing_mode`): `free` (gratis, max. 5h) / `discount` (Rabatt %) / `full`
- **Gratis-Kappung** (`clubs.member_free_max_minutes`, Standard 300 = 5h)
- Vorausbuchbarkeit, Vorlauf, Stornofrist, Währung, Zeitzone, Markenfarbe

## Kernregeln
- **Keine Doppelbelegung:** DB-Exclusion-Constraint auf `bookings` (überlappende Zeiten pro Platz sind unmöglich).
- **Gratis-Mitglieder:** bei `member_pricing_mode='free'` gilt Kappung `member_free_max_minutes` (5h) pro Buchung.
- **Abo:** `subscriptions` = fixer Wochenslot; daraus werden `bookings(kind='subscription')` erzeugt und blockieren den Platz.
- **Admin-Sperre:** `bookings(kind='block')` – Wartung/Turnier. **Gratis-Eintrag:** `bookings(kind='free', price=0)`.

## Tech-Stack
Wie Core-Management, bewusst deploy-arm:
- **Frontend:** statisches HTML/CSS/JS (GitHub Pages) – helle Palette in `assets/theme.css`
- **Backend:** Supabase (Postgres + RLS + Auth E-Mail/Passwort + Edge Functions)
- **Zahlung:** Stripe Connect (Auszahlung je Club)

## Struktur
```
court-booking/
├─ db/schema.sql          ← Datenmodell + RLS + Seed (Head-Admin, Demo-Club)  ✅
├─ assets/theme.css       ← helles Design-System                              ✅
├─ index.html             ← öffentliche Buchungsseite (Club-Auswahl/Slots)    ⏳
├─ login.html             ← Mitglieder-Login (E-Mail+Passwort)                ⏳
├─ konto.html             ← Mitglied: eigene Buchungen + Abo                  ⏳
├─ admin.html             ← Club-Admin-Dashboard                              ⏳
├─ head.html              ← Head-Admin (alle Clubs)                           ⏳
└─ supabase/functions/    ← create-checkout, stripe-webhook, gen-subscriptions ⏳
```

## Setup (einmalig)
1. **Supabase-Projekt** neu anlegen → Projekt-URL + anon-Key notieren.
2. `db/schema.sql` im Supabase SQL-Editor ausführen (legt Tabellen, RLS, Head-Admin, Demo-Club an).
3. Supabase Auth: E-Mail/Passwort aktivieren.
4. anon-Key + URL in `assets/config.js` eintragen (kommt in Meilenstein 1).
5. Stripe später (Meilenstein 4).

## Meilensteine
1. ✅ **Fundament** – Schema, Design, öffentliche Buchungsseite (Slots, Indoor/Outdoor, Gast-Buchung). Getestet: Buchung, Doppelbelegungs-Sperre, Öffnungszeiten-Prüfung.
2. ✅ **Mitglieder** – Login/Registrierung (E-Mail+Passwort), Mitglieder-Preislogik (gratis/rabatt/5h-Kappung, serverseitig in `create_booking`), eigenes Konto (`konto.html`).
3. ✅ **Club-Admin** – `admin.html`: Plätze, Öffnungszeiten, Slot-Länge, Preise & Mitglieder-Regeln, Sperren & Gratis-Buchungen, Mitgliederverwaltung, Abos. Head-Admin kann Club wechseln.
4. ✅ **Zahlung** – Stripe-Checkout für Gäste (`create-checkout`) + `stripe-webhook` (bestätigt Buchung nach Zahlung). Zahlungs-Hold (35 Min) + Stripe-Session-Expiry (31 Min) verhindern blockierte Slots bei Abbruch. Live-Modus, Webhook per Stripe-API angelegt.
5. ✅ **Head-Admin & Multi-Club** – `admin.html` Head-only-Tab „Clubs" (alle Clubs anlegen/übersehen); `connect-onboard` Function + Tab „Zahlungen" für Stripe-Connect-Onboarding je Club (eigene Auszahlungen). Getestet: Status-Abruf, Club-Anlage via RLS.
6. ✅ **Abo-Automatik** – `gen_subscription_bookings()` erzeugt aus `subscriptions` die wiederkehrenden `bookings` (kind='subscription'); täglicher **pg_cron**-Job (03:15) füllt rollierend 21 Tage; Admin-Button `generate_my_subscriptions()` für sofort. Idempotent, überspringt Konflikte. Getestet.

**Status: funktional vollständig (M1–M6).** Offene Go-live-Schritte: Deploy aufs Hosting (GitHub Pages o. ä.), eigene Domain, `CB_SITE_URL`-Secret auf die Domain setzen, echte Clubs anlegen + Stripe-Connect je Fremd-Club.

### Zahlungsziel je Club
`create-checkout` leitet die Zahlung nur dann per Connect an ein Club-Konto weiter, wenn der Club
`stripe_enabled` hat. Deine eigenen Clubs ohne Connect kassieren direkt auf dein Plattform-Konto
(denselben Stripe-Account) – Fremd-Clubs richten Connect ein und erhalten ihre Auszahlungen selbst.

### Live-Schaltung (Domain)
`CB_SITE_URL`-Secret steht auf `http://localhost:8123`. Beim Deploy auf die echte Domain
dieses Secret auf die Live-URL setzen (Stripe success/cancel-Redirects nutzen es).

### Admin-Zugang (einmalig)
Das Dashboard ist über `admin.html` erreichbar. Um es zu nutzen, muss der Admin einmal ein
Login-Konto zu seiner in `app_admins` hinterlegten E-Mail anlegen (Registrieren in `login.html`,
E-Mail bestätigen). Für `florian.a.haslinger@gmail.com` ist die `head_admin`-Rolle bereits gesetzt.
