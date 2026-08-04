-- ============================================================
-- Migration 10 – Mitgliedschaft direkt vergeben (ohne Online-Zahlung)
-- Admin weist einem Mitglied einen Tarif zu; valid_until wird korrekt
-- ab heute (bzw. ab bestehendem Ablauf, falls in Zukunft) verlängert.
-- ============================================================
create or replace function public.grant_membership(p_member uuid, p_plan uuid)
returns date language plpgsql security definer set search_path = public as $$
declare v_m members; v_plan membership_plans; v_new date;
begin
  select * into v_m from members where id = p_member;
  if not found then raise exception 'Mitglied nicht gefunden.'; end if;
  if not public.manages_club(v_m.club_id) then raise exception 'Keine Berechtigung.'; end if;
  select * into v_plan from membership_plans where id = p_plan and club_id = v_m.club_id;
  if not found then raise exception 'Tarif nicht gefunden.'; end if;

  update members
    set active = true,
        valid_until = greatest(coalesce(valid_until, current_date), current_date) + v_plan.duration_days
    where id = p_member
    returning valid_until into v_new;
  return v_new;
end $$;
grant execute on function public.grant_membership(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
