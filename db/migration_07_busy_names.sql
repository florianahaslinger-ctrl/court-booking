-- ============================================================
-- Migration 07 – Namen in belegten Zellen (nur für Mitglieder/Admins)
-- court_busy bekommt eine Spalte `label`. Sie ist NUR gefüllt, wenn der
-- Aufrufer ein aktives Mitglied ODER Verwalter dieses Clubs ist.
-- Anonyme/Gäste sehen `label = null` (Frontend zeigt weiter „belegt").
-- (Reine Lese-View, additiv – bestehende Spalten unverändert.)
-- ============================================================

create or replace view public.court_busy
with (security_invoker = off) as
  select
    b.court_id,
    b.club_id,
    b.start_at,
    b.end_at,
    case
      when public.manages_club(b.club_id)
        or exists (
          select 1 from public.members m
          where m.club_id = b.club_id
            and lower(m.email) = public.jwt_email()
            and m.active
        )
      then
        case b.kind
          when 'block'        then coalesce(nullif(b.note,''), 'Gesperrt')
          when 'subscription' then coalesce((select full_name from public.members m where m.id = b.member_id), b.note, 'Abo')
          when 'member'       then coalesce((select full_name from public.members m where m.id = b.member_id), b.guest_name, 'Mitglied')
          when 'free'         then coalesce(nullif(b.note,''), b.guest_name, 'Reserviert')
          else                     coalesce(b.guest_name, 'Gast')
        end
      else null
    end as label
  from public.bookings b
  where b.status <> 'cancelled'
    and not (b.payment_status = 'pending'
             and b.hold_expires_at is not null
             and b.hold_expires_at < now());

grant select on public.court_busy to anon, authenticated;

notify pgrst, 'reload schema';
