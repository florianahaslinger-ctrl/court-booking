-- ============================================================
-- Migration 13 – Guthaben / Wallet (Phase A: Datenmodell + Kern-Funktionen)
--
-- Konto pro (Club, E-Mail): Mitglieder (per Login-Mail) UND Gäste (per Mail).
-- Geld rein: Aufladung via Stripe (Phase B) / Admin-Gutschrift / Storno-Gutschrift.
-- Geld raus: Buchung per Guthaben.
-- Alles läuft über wallet_ledger (Journal); wallet_accounts.balance ist der Saldo.
-- ============================================================

create table if not exists public.wallet_accounts (
  id         uuid primary key default gen_random_uuid(),
  club_id    uuid not null references public.clubs(id) on delete cascade,
  email      text not null,                         -- immer lowercase gespeichert
  balance    numeric(10,2) not null default 0 check (balance >= 0),
  created_at timestamptz not null default now(),
  unique (club_id, email)
);

create table if not exists public.wallet_ledger (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  account_id  uuid not null references public.wallet_accounts(id) on delete cascade,
  amount      numeric(10,2) not null,               -- + Gutschrift, - Abbuchung
  kind        text not null check (kind in ('deposit','booking','cancel_refund','admin_credit','admin_debit')),
  booking_id  uuid references public.bookings(id) on delete set null,
  stripe_session text,
  note        text,
  created_by  text,
  created_at  timestamptz not null default now()
);
create index if not exists wallet_ledger_acct_idx on public.wallet_ledger (account_id, created_at desc);
create unique index if not exists wallet_ledger_session_uidx on public.wallet_ledger (stripe_session) where stripe_session is not null;

alter table public.wallet_accounts enable row level security;
alter table public.wallet_ledger   enable row level security;

-- Lesen: Club-Verwaltung sieht alle; jede Person ihr eigenes Konto (per E-Mail).
drop policy if exists wa_read on public.wallet_accounts;
create policy wa_read on public.wallet_accounts for select
  using (manages_club(club_id) or email = public.jwt_email());
drop policy if exists wl_read on public.wallet_ledger;
create policy wl_read on public.wallet_ledger for select
  using (manages_club(club_id)
      or exists (select 1 from public.wallet_accounts a
                 where a.id = wallet_ledger.account_id and a.email = public.jwt_email()));
-- Schreiben passiert ausschließlich über SECURITY-DEFINER-Funktionen (kein direktes INSERT/UPDATE).
grant select on public.wallet_accounts, public.wallet_ledger to anon, authenticated;

-- ------------------------------------------------------------
-- Interner Kern: Guthaben anpassen (atomar, gegen Überziehung gesichert)
-- Nur von anderen Definer-Funktionen / service_role aufrufbar.
-- ------------------------------------------------------------
create or replace function public._wallet_apply(
  p_club uuid, p_email text, p_amount numeric, p_kind text,
  p_booking uuid default null, p_note text default null, p_session text default null
) returns numeric
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_bal numeric; v_email text := lower(trim(coalesce(p_email,'')));
begin
  if v_email = '' then raise exception 'E-Mail für Guthaben fehlt.'; end if;
  insert into wallet_accounts(club_id, email, balance)
    values (p_club, v_email, 0) on conflict (club_id, email) do nothing;
  update wallet_accounts set balance = balance + p_amount
    where club_id = p_club and email = v_email and (p_amount >= 0 or balance + p_amount >= 0)
    returning id, balance into v_id, v_bal;
  if v_id is null then raise exception 'Guthaben reicht nicht.'; end if;
  insert into wallet_ledger(club_id, account_id, amount, kind, booking_id, stripe_session, note, created_by)
    values (p_club, v_id, p_amount, p_kind, p_booking, p_session, p_note, nullif(public.jwt_email(),''));
  return v_bal;
end $$;
revoke all on function public._wallet_apply(uuid,text,numeric,text,uuid,text,text) from public;
grant execute on function public._wallet_apply(uuid,text,numeric,text,uuid,text,text) to service_role;

-- ------------------------------------------------------------
-- Eigenes Guthaben abfragen (Buchungsseite/Konto)
-- ------------------------------------------------------------
create or replace function public.wallet_get(p_club_slug text)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_club uuid; v_email text := public.jwt_email(); v_bal numeric;
begin
  if v_email = '' then return 0; end if;
  select id into v_club from clubs where slug = p_club_slug and active;
  if v_club is null then return 0; end if;
  select balance into v_bal from wallet_accounts where club_id = v_club and email = v_email;
  return coalesce(v_bal, 0);
end $$;
grant execute on function public.wallet_get(text) to anon, authenticated;

-- ------------------------------------------------------------
-- Admin-Gutschrift/-Abbuchung (modular)
-- ------------------------------------------------------------
create or replace function public.admin_adjust_wallet(
  p_club uuid, p_email text, p_amount numeric, p_note text default null
) returns numeric language plpgsql security definer set search_path = public as $$
declare v_bal numeric;
begin
  if not manages_club(p_club) then raise exception 'Keine Berechtigung für diesen Club.'; end if;
  if p_amount = 0 then raise exception 'Betrag darf nicht 0 sein.'; end if;
  v_bal := _wallet_apply(p_club, p_email, p_amount,
                         case when p_amount >= 0 then 'admin_credit' else 'admin_debit' end,
                         null, coalesce(p_note, 'Admin-Buchung'), null);
  return v_bal;
end $$;
grant execute on function public.admin_adjust_wallet(uuid,text,numeric,text) to authenticated;

-- ------------------------------------------------------------
-- Aufladung anwenden (idempotent, vom Stripe-Webhook / service_role)
-- ------------------------------------------------------------
create or replace function public.wallet_topup_apply(
  p_club uuid, p_email text, p_amount numeric, p_session text
) returns numeric language plpgsql security definer set search_path = public as $$
declare v_bal numeric;
begin
  if p_session is not null and exists (select 1 from wallet_ledger where stripe_session = p_session) then
    return (select balance from wallet_accounts where club_id = p_club and email = lower(trim(p_email)));
  end if;
  v_bal := _wallet_apply(p_club, p_email, p_amount, 'deposit', null, 'Aufladung', p_session);
  return v_bal;
end $$;
revoke all on function public.wallet_topup_apply(uuid,text,numeric,text) from public;
grant execute on function public.wallet_topup_apply(uuid,text,numeric,text) to service_role;

-- ------------------------------------------------------------
-- Storno mit Guthaben-Gutschrift (immer voller Betrag)
--   erlaubt: Club-Verwaltung ODER das buchende Mitglied (nur Zukunft)
-- ------------------------------------------------------------
create or replace function public.cancel_booking(p_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_b bookings; v_email text; v_is_mgr boolean; v_is_owner boolean; v_refund numeric := 0;
begin
  select * into v_b from bookings where id = p_id;
  if not found then raise exception 'Buchung nicht gefunden.'; end if;
  if v_b.status = 'cancelled' then return json_build_object('ok', true, 'already', true); end if;

  v_is_mgr := manages_club(v_b.club_id);
  v_is_owner := v_b.member_id is not null and exists (
                  select 1 from members m where m.id = v_b.member_id and lower(m.email) = public.jwt_email());
  if not (v_is_mgr or v_is_owner) then raise exception 'Keine Berechtigung.'; end if;
  if (not v_is_mgr) and v_b.start_at <= now() then raise exception 'Nur zukünftige Buchungen stornierbar.'; end if;

  -- Gutschrift des bezahlten Betrags auf die E-Mail der Buchung
  v_email := coalesce((select lower(email) from members m where m.id = v_b.member_id), lower(v_b.guest_email));
  if v_b.price > 0 and v_b.payment_status = 'paid' and coalesce(v_email,'') <> '' then
    perform _wallet_apply(v_b.club_id, v_email, v_b.price, 'cancel_refund', v_b.id, 'Storno-Gutschrift', null);
    v_refund := v_b.price;
  end if;

  update bookings set status = 'cancelled' where id = p_id;
  return json_build_object('ok', true, 'refunded', v_refund, 'email', v_email);
end $$;
grant execute on function public.cancel_booking(uuid) to authenticated;

notify pgrst, 'reload schema';
