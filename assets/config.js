// ============================================================
// COURT BOOKING – Zentrale Konfiguration
// Nach dem Anlegen des Supabase-Projekts hier eintragen:
//   Supabase → Project Settings → API → Project URL + anon public key
// ============================================================
window.CB_CONFIG = {
  SUPABASE_URL:  'https://aagzfijbxujkbjxccbno.supabase.co',
  SUPABASE_ANON: 'sb_publishable_JFelea80c4j9p3cVcFp0lg_T2eSPjFR',

  // Standard-Club, wenn keine ?club=slug in der URL steht
  DEFAULT_CLUB:  'demo-tennis',
};

// Supabase-Client (aus CDN geladen in der jeweiligen Seite)
window.cbClient = function () {
  const { SUPABASE_URL, SUPABASE_ANON } = window.CB_CONFIG;
  return window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON);
};

// ---- gemeinsame Helfer -------------------------------------
window.CB = {
  // Preis einer Buchung berechnen (Client-Vorschau; Server bleibt Quelle der Wahrheit)
  priceFor(court, club, minutes, isMember) {
    const hours = minutes / 60;
    const base  = Number(court.price_per_hour || 0) * hours;
    if (!isMember) return round2(base);
    switch (club.member_pricing_mode) {
      case 'free':     return 0;
      case 'discount': return round2(base * (1 - (club.member_discount_percent || 0) / 100));
      default:         return round2(base); // 'full'
    }
  },
  // maximal erlaubte Buchungsdauer (min) für diese Person
  maxMinutes(club, isMember) {
    if (isMember && club.member_pricing_mode === 'free') return club.member_free_max_minutes || 300;
    return 24 * 60;
  },
  money(v, cur = 'EUR') {
    return new Intl.NumberFormat('de-AT', { style: 'currency', currency: cur }).format(v || 0);
  },
  fmtTime(d) { return d.toLocaleTimeString('de-AT', { hour: '2-digit', minute: '2-digit' }); },
  fmtDate(d) { return d.toLocaleDateString('de-AT', { weekday: 'short', day: '2-digit', month: 'short' }); },
};
function round2(n) { return Math.round(n * 100) / 100; }
