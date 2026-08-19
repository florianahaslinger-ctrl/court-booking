-- ============================================================
-- Migration 24 – Tarif-Fenster dürfen sich nicht überschneiden
--
-- Bisher waren Überlappungen erlaubt ("engstes Fenster gewinnt").
-- Jetzt wird pro Club + Platzart (Indoor/Outdoor) verhindert, dass sich
-- zwei Zeitfenster überschneiden: gemeinsamer Wochentag UND sich
-- überlappende Uhrzeit-Spanne. Durchgesetzt per BEFORE-Trigger, damit es
-- unabhängig vom Client (Admin-UI, direkte Inserts) immer gilt.
-- ============================================================

create or replace function public.price_windows_no_overlap()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_c record; v_desc text;
begin
  select pw.start_time, pw.end_time, pw.label into v_c
    from price_windows pw
   where pw.club_id = new.club_id
     and pw.environment = new.environment
     and pw.id <> new.id
     and pw.weekdays && new.weekdays              -- mind. ein gemeinsamer Wochentag
     and new.start_time < pw.end_time             -- Uhrzeit-Spannen überlappen
     and new.end_time   > pw.start_time
   order by pw.start_time
   limit 1;

  if found then
    v_desc := to_char(v_c.start_time,'HH24:MI') || '–' || to_char(v_c.end_time,'HH24:MI') || ' Uhr'
              || case when coalesce(v_c.label,'') <> '' then ' (' || v_c.label || ')' else '' end;
    raise exception 'Zeitfenster überschneidet sich mit bestehendem Tarif %. Überschneidungen sind nicht erlaubt.', v_desc
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists trg_price_windows_no_overlap on public.price_windows;
create trigger trg_price_windows_no_overlap
  before insert or update on public.price_windows
  for each row execute function public.price_windows_no_overlap();

notify pgrst, 'reload schema';
