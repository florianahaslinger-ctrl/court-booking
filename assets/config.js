// ============================================================
// COURT BOOKING – Zentrale Konfiguration
// Nach dem Anlegen des Supabase-Projekts hier eintragen:
//   Supabase → Project Settings → API → Project URL + anon public key
// ============================================================
window.CB_CONFIG = {
  SUPABASE_URL:  'https://aagzfijbxujkbjxccbno.supabase.co',
  SUPABASE_ANON: 'sb_publishable_JFelea80c4j9p3cVcFp0lg_T2eSPjFR',

  // Standard-Club, wenn keine ?club=slug in der URL steht
  DEFAULT_CLUB:  'tc-jeitschko',
};

// Supabase-Client (aus CDN geladen in der jeweiligen Seite)
window.cbClient = function () {
  const { SUPABASE_URL, SUPABASE_ANON } = window.CB_CONFIG;
  return window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON);
};

// ---- gemeinsame Helfer -------------------------------------
window.CB = {
  // Preisregeln je Platzart (Indoor/Outdoor) mit Fallback aufs club-weite Modell
  rules(club, env) {
    return {
      mode: club['member_pricing_mode_' + env] ?? club.member_pricing_mode,
      disc: club['member_discount_percent_' + env] ?? club.member_discount_percent,
      freemax: club['member_free_max_minutes_' + env] ?? club.member_free_max_minutes,
    };
  },
  // Stundenpreis für einen Slot: passendes Zeitfenster (nach Slot-START), sonst Platzpreis.
  // Bei Überlappung gewinnt das engste Fenster (kürzeste Dauer) – wie serverseitig.
  rateFor(court, windows, start) {
    const base = Number(court.price_per_hour || 0);
    if (!windows || !windows.length || !start) return base;
    const wd = start.getDay();                        // 0=So .. 6=Sa
    const tod = start.getHours() * 60 + start.getMinutes();
    let best = null, bestSpan = Infinity;
    for (const w of windows) {
      if (w.environment !== court.environment) continue;
      if (!(w.weekdays || []).includes(wd)) continue;
      const a = hm(w.start_time), b = hm(w.end_time);
      if (tod < a || tod >= b) continue;
      if (b - a < bestSpan) { bestSpan = b - a; best = w; }
    }
    return best ? Number(best.price_per_hour) : base;
  },
  // Preis einer Buchung berechnen (Client-Vorschau; Server bleibt Quelle der Wahrheit).
  // rate = Stundenpreis für diesen Slot (aus rateFor); ohne Angabe = Platzpreis.
  priceFor(court, club, minutes, isMember, rate) {
    const hours = minutes / 60;
    const perHour = (rate == null ? Number(court.price_per_hour || 0) : Number(rate));
    const base  = perHour * hours;
    if (!isMember) return round2(base);
    const r = this.rules(club, court.environment);
    switch (r.mode) {
      case 'free':     return 0;
      case 'discount': return round2(base * (1 - (r.disc || 0) / 100));
      default:         return round2(base); // 'full'
    }
  },
  // Preisfaktor für ein Mitglied auf dieser Platzart:
  // gratis=0, Rabatt=(100-d)/100, sonst voller Anteil=1. Muss zum Server
  // (create_booking) passen, der den Anteil ebenso berechnet.
  memberFactor(club, env) {
    const r = this.rules(club, env);
    if (r.mode === 'free') return 0;
    if (r.mode === 'discount') return round2(1 - (r.disc || 0) / 100);
    return 1;
  },
  // Jugend-/Altersrabatt-Faktor (<=1): (100-pct)/100, wenn die Person am
  // Stichtag jünger als youth_max_age ist, sonst 1. Stapelt auf den
  // Mitglieder-/Gastpreis. Muss zum Server (_youth_factor) passen.
  youthFactor(club, birthdate, onDate) {
    const pct = Number(club && club.youth_discount_percent || 0);
    if (!birthdate || pct <= 0) return 1;
    const maxAge = Number(club.youth_max_age || 18);
    const on = onDate ? new Date(onDate) : new Date();
    const b = new Date(birthdate);
    if (isNaN(b)) return 1;
    let age = on.getFullYear() - b.getFullYear();
    const m = on.getMonth() - b.getMonth();
    if (m < 0 || (m === 0 && on.getDate() < b.getDate())) age--;
    return age < maxAge ? round2(1 - pct / 100) : 1;
  },
  // maximal erlaubte Buchungsdauer (min) für diese Person auf diesem Platz
  maxMinutes(club, isMember, env) {
    const r = this.rules(club, env);
    if (isMember && r.mode === 'free') return r.freemax || 300;
    return 24 * 60;
  },
  money(v, cur = 'EUR') {
    return new Intl.NumberFormat('de-AT', { style: 'currency', currency: cur }).format(v || 0);
  },
  fmtTime(d) { return d.toLocaleTimeString('de-AT', { hour: '2-digit', minute: '2-digit' }); },
  fmtDate(d) { return d.toLocaleDateString('de-AT', { weekday: 'short', day: '2-digit', month: 'short' }); },
};
function round2(n) { return Math.round(n * 100) / 100; }
function hm(t) { if (!t) return 0; const p = String(t).split(':'); return (+p[0]) * 60 + (+p[1] || 0); }

// Supabase-Auth-Fehlermeldungen ins Deutsche übersetzen (Login/Registrierung).
window.CB.authErr = function (err) {
  if (!err) return 'Unbekannter Fehler. Bitte versuche es erneut.';
  const code = String(err.code || err.error_code || '').toLowerCase();
  const raw  = String(err.message || err.msg || err.error_description || err);
  const m = raw.toLowerCase();
  const has = s => m.indexOf(s) !== -1;

  // Netzwerk / Server nicht erreichbar
  if (err.name === 'AuthRetryableFetchError' || has('failed to fetch') || has('networkerror') || has('load failed'))
    return 'Verbindung zum Server fehlgeschlagen. Bitte prüfe deine Internetverbindung und versuche es erneut.';

  // Rate-Limit mit Sekundenangabe
  const sec = raw.match(/after (\d+) second/i);
  if (sec) return 'Aus Sicherheitsgründen bitte in ' + sec[1] + ' Sekunden erneut versuchen.';

  const map = [
    [['invalid_credentials', 'invalid login credentials', 'invalid_grant'], 'E-Mail oder Passwort ist falsch.'],
    [['email_not_confirmed', 'email not confirmed', 'not confirmed'], 'Bitte bestätige zuerst deine E-Mail-Adresse (Link in der Bestätigungs-Mail).'],
    [['user_already_exists', 'already registered', 'already been registered'], 'Diese E-Mail ist bereits registriert. Bitte melde dich an.'],
    [['weak_password', 'password should be at least', 'password is too short'], 'Das Passwort ist zu kurz (mindestens 6 Zeichen).'],
    [['same_password', 'should be different'], 'Das neue Passwort muss sich vom alten unterscheiden.'],
    [['invalid_email', 'unable to validate email', 'invalid format'], 'Die E-Mail-Adresse ist ungültig.'],
    [['over_email_send_rate_limit', 'email rate limit', 'over_request_rate_limit', 'rate limit', 'too many requests'], 'Zu viele Versuche. Bitte warte einen Moment und versuche es erneut.'],
    [['user_not_found', 'user not found'], 'Kein Konto mit dieser E-Mail gefunden.'],
    [['signups not allowed', 'signup_disabled', 'signups_disabled'], 'Registrierung ist derzeit nicht möglich.'],
    [['otp_expired', 'token has expired', 'is invalid', 'expired'], 'Der Link ist abgelaufen oder ungültig. Bitte fordere einen neuen an.'],
    [['provide your email', 'missing email', 'validation_failed'], 'Bitte gib eine gültige E-Mail-Adresse ein.'],
  ];
  for (let i = 0; i < map.length; i++) {
    const keys = map[i][0];
    if (keys.some(k => code === k || has(k))) return map[i][1];
  }
  return 'Anmeldung fehlgeschlagen. Bitte prüfe deine Eingaben und versuche es erneut.';
};

// Zuletzt gewählten Club merken: expliziter ?club= gewinnt und wird gespeichert;
// fehlt er (nackte Domain, Login-Rücksprung, Marketing-Seite), wird der gemerkte
// Club verwendet, damit man nicht auf den Default-Club zurückgeworfen wird.
window.CB.currentClub = function () {
  let c = new URLSearchParams(location.search).get('club');
  try {
    if (c) localStorage.setItem('cb_club', c);
    else   c = localStorage.getItem('cb_club');
  } catch (e) { /* localStorage evtl. blockiert */ }
  return c || null;
};
// Aufzulösender Club für die Seite (mit Default als letzter Rückfall).
window.CB.resolveClub = function () {
  return window.CB.currentClub() || window.CB_CONFIG.DEFAULT_CLUB;
};
window.CB.clubQuery = function () {
  const c = window.CB.currentClub();
  return c ? ('?club=' + encodeURIComponent(c)) : '';
};
// ?club= an interne Nav-Links (index/konto/login) anhängen.
window.CB.wireClubNav = function () {
  const q = window.CB.clubQuery();
  if (!q) return;
  document.querySelectorAll('a[href]').forEach(a => {
    const h = a.getAttribute('href');
    if (/^(index|konto|login)\.html$/.test(h)) a.setAttribute('href', h + q);
  });
};
