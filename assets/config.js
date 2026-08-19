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

// Aktuellen ?club=-Parameter erhalten: an interne Nav-Links (index/konto/login) anhängen,
// damit man beim Wechsel nicht auf den Default-Club zurückfällt.
window.CB.clubQuery = function () {
  const c = new URLSearchParams(location.search).get('club');
  return c ? ('?club=' + encodeURIComponent(c)) : '';
};
window.CB.wireClubNav = function () {
  const q = window.CB.clubQuery();
  if (!q) return;
  document.querySelectorAll('a[href]').forEach(a => {
    const h = a.getAttribute('href');
    if (/^(index|konto|login)\.html$/.test(h)) a.setAttribute('href', h + q);
  });
};
