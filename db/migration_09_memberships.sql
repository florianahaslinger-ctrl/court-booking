-- ============================================================
-- Migration 09 – Online-Mitgliedschaft (modulare Tarife + Bezahlung)
-- Club-Admin legt Tarife an (Name, Preis, Dauer). Mitglieder zahlen online
-- (Stripe) -> Mitgliedschaft (members.valid_until) wird verlängert.
-- ============================================================

create table if not exists public.membership_plans (
  id            uuid primary key default gen_random_uuid(),
  club_id       uuid not null references public.clubs(id) on delete cascade,
  name          text not null,
  price         numeric(10,2) not null default 0 check (price >= 0),
  duration_days int  not null default 365 check (duration_days between 1 and 3660),
  active        boolean not null default true,
  sort          int not null default 0,
  created_at    timestamptz not null default now()
);

create table if not exists public.membership_payments (
  id                uuid primary key default gen_random_uuid(),
  club_id           uuid, email text, plan_id uuid, plan_name text,
  amount            numeric(10,2), valid_until date,
  stripe_session_id text unique,
  paid_at           timestamptz not null default now()
);

alter table public.membership_plans    enable row level security;
alter table public.membership_payments enable row level security;

drop policy if exists mp_read on public.membership_plans;
create policy mp_read on public.membership_plans for select using (active or manages_club(club_id));
drop policy if exists mp_write on public.membership_plans;
create policy mp_write on public.membership_plans for all using (manages_club(club_id)) with check (manages_club(club_id));

drop policy if exists mpay_read on public.membership_payments;
create policy mpay_read on public.membership_payments for select using (manages_club(club_id));

grant select on public.membership_plans to anon, authenticated;
grant select on public.membership_payments to authenticated;

-- Zahlung anwenden (idempotent per Stripe-Session): verlängert die Mitgliedschaft
create or replace function public.membership_pay_apply(p_plan uuid, p_email text, p_session text)
returns void language plpgsql security definer set search_path = public as $$
declare v_plan membership_plans; v_email text := lower(trim(p_email)); v_new date;
begin
  if exists (select 1 from membership_payments where stripe_session_id = p_session) then return; end if;
  select * into v_plan from membership_plans where id = p_plan;
  if not found then raise exception 'Tarif nicht gefunden.'; end if;

  update members m
    set active = true,
        valid_until = greatest(coalesce(m.valid_until, current_date), current_date) + v_plan.duration_days
    where m.club_id = v_plan.club_id and lower(m.email) = v_email
    returning m.valid_until into v_new;
  if not found then
    insert into members(club_id, email, active, valid_until)
      values (v_plan.club_id, v_email, true, current_date + v_plan.duration_days)
      returning valid_until into v_new;
  end if;

  insert into membership_payments(club_id, email, plan_id, plan_name, amount, valid_until, stripe_session_id)
    values (v_plan.club_id, v_email, v_plan.id, v_plan.name, v_plan.price, v_new, p_session)
    on conflict (stripe_session_id) do nothing;
end $$;

notify pgrst, 'reload schema';
