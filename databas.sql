-- =====================================================================
--  Abbe Khalili – databas för bokningssidan
--  Kör hela filen en gång i Supabase: SQL Editor → New query → klistra in → Run.
--
--  INNAN DU KÖR: ändra de två e-postadresserna längst ner under
--  "Vem är administratör" till Abbes och din egen adress.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tabeller ----------

create table if not exists public.admins (
  email text primary key
);

create table if not exists public.blocked (
  contact text primary key,          -- e-post eller telefonnummer som inte får boka
  note text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('ind','duo','grp')),
  starts_at timestamptz not null,
  max int not null check (max between 1 and 12),
  place text not null default '',
  focus text not null default '',
  audience text not null default '',
  equipment text not null default '',
  status text not null default 'open' check (status in ('open','cancelled')),
  checked text,
  cancel_reason text,
  cancel_msg text,
  cancelled_at timestamptz,
  test boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.families (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  phone text not null default '',
  email text not null default '',
  role text not null default 'vh' check (role in ('spelare','vh')),
  consent_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.families(user_id) on delete cascade,
  name text not null,
  birth_year int not null,
  self boolean not null default false,
  club text not null default '',
  exp text not null default '',
  level text not null default '',
  goals text[] not null default '{}',
  notes text not null default '',
  removed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.families(user_id) on delete cascade,
  session_id uuid not null references public.sessions(id) on delete restrict,
  type text not null,
  players uuid[] not null,
  n int not null,
  price int not null,
  total int not null,
  status text not null check (status in ('reserved','pending_review','approved','confirmed','cancelled','declined','session_cancelled')),
  wish jsonb not null default '{}'::jsonb,
  hold_until timestamptz,
  pay_by timestamptz,
  pay_status text not null default 'unpaid' check (pay_status in ('unpaid','waiting','verified')),
  pay_amount int not null default 0,
  paid_at timestamptz,
  late_cancel boolean not null default false,
  decision_msg text not null default '',
  attended jsonb not null default '{}'::jsonb,
  moved_from uuid,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
create index if not exists bookings_session_idx on public.bookings(session_id);
create index if not exists bookings_user_idx on public.bookings(user_id);

create table if not exists public.refunds (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  user_id uuid not null references public.families(user_id) on delete cascade,
  amount int not null,
  status text not null default 'pending' check (status in ('pending','verified')),
  reason text not null default '',
  created_at timestamptz not null default now(),
  verified_at timestamptz
);
create index if not exists refunds_booking_idx on public.refunds(booking_id);

-- ---------- Hjälpfunktioner ----------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins a where lower(a.email) = lower(coalesce(auth.jwt()->>'email', '')));
$$;

create or replace function public.price_of(t text) returns int
language sql immutable as $$
  select case t when 'ind' then 599 when 'duo' then 349 else 200 end;
$$;

create or replace function public.min_of(t text) returns int
language sql immutable as $$
  select case t when 'grp' then 6 when 'duo' then 2 else 1 end;
$$;

-- Räknas bokningen som en tagen plats just nu?
create or replace function public.counts_row(b public.bookings) returns boolean
language sql stable as $$
  select case b.status
    when 'reserved' then coalesce(b.hold_until, '-infinity'::timestamptz) > now()
    when 'approved' then (b.pay_by is null or b.pay_by >= now())
    when 'pending_review' then true
    when 'confirmed' then true
    else false end;
$$;

-- Bokningens status som kunden ser den
create or replace function public.eff_status(b public.bookings) returns text
language sql stable as $$
  select case
    when (select s.status from public.sessions s where s.id = b.session_id) = 'cancelled'
         and b.status in ('reserved','pending_review','approved','confirmed') then 'session_cancelled'
    when b.status = 'reserved' and coalesce(b.hold_until, '-infinity'::timestamptz) <= now() then 'expired'
    when b.status = 'approved' and b.pay_by is not null and b.pay_by < now() then 'payexpired'
    else b.status end;
$$;

create or replace function public.used_seats(p_session uuid, p_exclude uuid default null) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(b.n), 0)::int from public.bookings b
  where b.session_id = p_session and (p_exclude is null or b.id <> p_exclude) and public.counts_row(b);
$$;

-- Lediga platser per pass – får läsas av alla (inga namn, bara antal)
create or replace function public.session_counts() returns table(session_id uuid, used int, confirmed int, pending int)
language sql stable security definer set search_path = public as $$
  select b.session_id,
         coalesce(sum(b.n) filter (where public.counts_row(b)), 0)::int,
         coalesce(sum(b.n) filter (where b.status = 'confirmed'), 0)::int,
         coalesce(sum(b.n) filter (where b.status = 'pending_review'), 0)::int
  from public.bookings b
  group by b.session_id;
$$;

create or replace function public._my_booking(p_booking uuid, p_allow_admin boolean default false) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Bokningen finns inte.'; end if;
  if b.user_id is distinct from auth.uid() and not (p_allow_admin and public.is_admin()) then
    raise exception 'Du har inte behörighet till bokningen.';
  end if;
  return b;
end $$;

create or replace function public._require_admin() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Bara Abbe kan göra det här.'; end if;
end $$;

-- ---------- Kundens funktioner ----------

create or replace function public.book(p_session uuid, p_players uuid[], p_wish jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  s public.sessions; fam public.families;
  v_n int; v_used int; v_mine int; v_bad int; v_status text; v_hold timestamptz; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Bekräfta med koden först.'; end if;
  select * into fam from public.families where user_id = auth.uid();
  if not found then raise exception 'Fyll i dina uppgifter först.'; end if;
  if exists (select 1 from public.blocked bl where lower(bl.contact) in (lower(fam.email), lower(fam.phone))) then
    raise exception 'Bokningen kunde inte genomföras. Kontakta Abbe.';
  end if;

  select * into s from public.sessions where id = p_session for update;   -- låser passet så två inte kan ta sista platsen
  if not found or s.status <> 'open' or s.starts_at - interval '1 hour' <= now() then
    raise exception 'Passet går inte att boka längre.';
  end if;

  v_n := coalesce(array_length(p_players, 1), 0);
  if v_n = 0 then raise exception 'Välj minst en spelare.'; end if;
  if s.type = 'ind' and v_n > 1 then raise exception 'Individuell träning gäller en spelare.'; end if;

  select count(*) into v_bad from unnest(p_players) pid
  where not exists (select 1 from public.players p where p.id = pid and p.user_id = auth.uid() and not p.removed);
  if v_bad > 0 then raise exception 'Någon av spelarna finns inte.'; end if;

  if exists (select 1 from public.bookings b where b.session_id = p_session and b.user_id = auth.uid()
             and public.counts_row(b) and b.players && p_players) then
    raise exception 'Någon av spelarna är redan bokad på passet.';
  end if;

  select coalesce(sum(b.n), 0) into v_mine from public.bookings b
  where b.session_id = p_session and b.user_id = auth.uid() and public.counts_row(b);
  if v_mine + v_n > 3 then raise exception 'Du kan boka högst 3 platser per pass.'; end if;

  v_used := public.used_seats(p_session);
  if v_used + v_n > s.max then
    if s.max - v_used > 0 then raise exception 'Det finns bara % lediga platser kvar.', s.max - v_used;
    else raise exception 'Passet hann bli fullbokat.'; end if;
  end if;

  if s.type = 'grp' then v_status := 'pending_review'; v_hold := null;
  else v_status := 'reserved'; v_hold := now() + interval '10 minutes'; end if;

  insert into public.bookings(user_id, session_id, type, players, n, price, total, status, wish, hold_until)
  values (auth.uid(), p_session, s.type, p_players, v_n, public.price_of(s.type), v_n * public.price_of(s.type),
          v_status, coalesce(p_wish, '{}'::jsonb), v_hold)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.rebook(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings; s public.sessions;
begin
  b := public._my_booking(p_booking);
  if public.eff_status(b) <> 'expired' then raise exception 'Bokningen kan inte reserveras igen.'; end if;
  select * into s from public.sessions where id = b.session_id for update;
  if s.status <> 'open' or s.starts_at - interval '1 hour' <= now() then raise exception 'Passet går inte att boka längre.'; end if;
  if public.used_seats(b.session_id, b.id) + b.n > s.max then raise exception 'Det finns inte längre plats för % spelare.', b.n; end if;
  update public.bookings set status = 'reserved', hold_until = now() + interval '10 minutes', pay_status = 'unpaid', pay_amount = 0 where id = b.id;
end $$;

create or replace function public.start_pay(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings; e text;
begin
  b := public._my_booking(p_booking); e := public.eff_status(b);
  if e not in ('reserved','approved') then raise exception 'Bokningen kan inte betalas just nu.'; end if;
  update public.bookings set pay_status = 'waiting', pay_amount = b.total,
    hold_until = case when e = 'reserved' then now() + interval '10 minutes' else hold_until end
  where id = b.id;
end $$;

-- TESTLÄGE: ersätts av riktig Swish-verifiering när Swish kopplas in
create or replace function public.simulate_paid(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings; e text;
begin
  b := public._my_booking(p_booking, true); e := public.eff_status(b);
  if e not in ('reserved','approved') then raise exception 'Tiden för betalningen har gått ut.'; end if;
  update public.bookings set pay_status = 'verified', pay_amount = b.total, paid_at = now(),
    status = 'confirmed', hold_until = null, pay_by = null
  where id = b.id;
end $$;

-- TESTLÄGE: ersätts av riktig verifiering från Swish
create or replace function public.verify_refunds(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  b := public._my_booking(p_booking, true);
  update public.refunds set status = 'verified', verified_at = now() where booking_id = b.id and status <> 'verified';
end $$;

create or replace function public.cancel_booking(p_booking uuid, p_players uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare
  b public.bookings; s public.sessions; e text; v_keep uuid[]; v_left int; v_rm int;
  v_in_time boolean; v_paid int; v_ref int; v_refund int := 0;
begin
  b := public._my_booking(p_booking); e := public.eff_status(b);
  select * into s from public.sessions where id = b.session_id;
  if e not in ('reserved','pending_review','approved','confirmed') or now() >= s.starts_at then
    raise exception 'Bokningen kan inte avbokas.';
  end if;
  select coalesce(array_agg(x), '{}') into v_keep from unnest(b.players) x where not (x = any(p_players));
  v_left := coalesce(array_length(v_keep, 1), 0);
  v_rm := b.n - v_left;
  if v_rm <= 0 then raise exception 'Välj minst en spelare att avboka.'; end if;

  v_in_time := now() <= s.starts_at - interval '12 hours';
  v_paid := case when b.pay_status = 'verified' then b.pay_amount else 0 end;
  select coalesce(sum(amount), 0) into v_ref from public.refunds where booking_id = b.id;
  if v_paid > 0 and v_in_time then v_refund := least(v_paid - v_ref, v_rm * b.price); end if;

  update public.bookings set
    players = v_keep, n = v_left, total = v_left * b.price,
    status = case when v_left = 0 then 'cancelled' else status end,
    ended_at = case when v_left = 0 then now() else ended_at end,
    late_cancel = late_cancel or (v_paid > 0 and not v_in_time)
  where id = b.id;

  if v_refund > 0 then
    insert into public.refunds(booking_id, user_id, amount, reason)
    values (b.id, b.user_id, v_refund, case when v_left = 0 then 'Avbokad i tid' else 'Avbokning av ' || v_rm || ' spelare' end);
  end if;
  return v_refund;
end $$;

create or replace function public.move_booking(p_booking uuid, p_to uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings; s_from public.sessions; s_to public.sessions; e text; v_status text;
begin
  b := public._my_booking(p_booking); e := public.eff_status(b);
  select * into s_from from public.sessions where id = b.session_id;
  if e not in ('pending_review','approved','confirmed') or now() > s_from.starts_at - interval '12 hours' then
    raise exception 'Bokningen kan inte flyttas längre.';
  end if;
  select * into s_to from public.sessions where id = p_to for update;
  if not found or s_to.id = b.session_id or s_to.type <> b.type or s_to.status <> 'open'
     or s_to.starts_at - interval '12 hours' <= now() then
    raise exception 'Det passet går inte att flytta till.';
  end if;
  if public.used_seats(p_to, b.id) + b.n > s_to.max then raise exception 'Passet har inte längre plats för % spelare.', b.n; end if;
  v_status := case when s_to.type = 'grp' then 'pending_review' when e = 'confirmed' then 'confirmed' else b.status end;
  update public.bookings set session_id = p_to, status = v_status, moved_from = b.session_id, pay_by = null, decision_msg = ''
  where id = b.id;
end $$;

-- ---------- Abbes funktioner ----------

create or replace function public.admin_approve(p_booking uuid, p_msg text default '') returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings; s public.sessions; v_paid boolean;
begin
  perform public._require_admin();
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Bokningen finns inte.'; end if;
  if public.eff_status(b) <> 'pending_review' then raise exception 'Anmälan är redan hanterad.'; end if;
  select * into s from public.sessions where id = b.session_id;
  v_paid := b.pay_status = 'verified';
  update public.bookings set
    status = case when v_paid then 'confirmed' else 'approved' end,
    pay_by = case when v_paid then null
                  when now() < s.starts_at - interval '24 hours' then s.starts_at - interval '24 hours'
                  else s.starts_at - interval '1 hour' end,
    decision_msg = coalesce(p_msg, '')
  where id = b.id;
end $$;

create or replace function public.admin_decline(p_booking uuid, p_msg text default '') returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_paid int; v_ref int;
begin
  perform public._require_admin();
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'Bokningen finns inte.'; end if;
  v_paid := case when b.pay_status = 'verified' then b.pay_amount else 0 end;
  select coalesce(sum(amount), 0) into v_ref from public.refunds where booking_id = b.id;
  update public.bookings set status = 'declined', ended_at = now(), decision_msg = coalesce(p_msg, '') where id = b.id;
  if v_paid - v_ref > 0 then
    insert into public.refunds(booking_id, user_id, amount, reason) values (b.id, b.user_id, v_paid - v_ref, 'Anmälan avslagen');
  end if;
end $$;

create or replace function public._cancel_session(p_session uuid, p_reason text, p_msg text) returns void
language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_paid int; v_ref int;
begin
  update public.sessions set status = 'cancelled', cancel_reason = p_reason, cancel_msg = coalesce(p_msg, ''),
    cancelled_at = now(), checked = 'cancelled'
  where id = p_session;
  for b in select * from public.bookings where session_id = p_session
           and status in ('reserved','pending_review','approved','confirmed') for update loop
    v_paid := case when b.pay_status = 'verified' then b.pay_amount else 0 end;
    select coalesce(sum(amount), 0) into v_ref from public.refunds where booking_id = b.id;
    update public.bookings set status = 'session_cancelled', ended_at = now() where id = b.id;
    if v_paid - v_ref > 0 then
      insert into public.refunds(booking_id, user_id, amount, reason) values (b.id, b.user_id, v_paid - v_ref, 'Passet inställt');
    end if;
  end loop;
end $$;

create or replace function public.admin_cancel_session(p_session uuid, p_reason text, p_msg text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  if not exists (select 1 from public.sessions where id = p_session and status = 'open') then raise exception 'Passet är redan inställt.'; end if;
  perform public._cancel_session(p_session, p_reason, p_msg);
end $$;

create or replace function public.admin_set_attendance(p_booking uuid, p_player uuid, p_val boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  update public.bookings set attended = attended || jsonb_build_object(p_player::text, p_val) where id = p_booking;
end $$;

create or replace function public.admin_upsert_session(p_id uuid, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_type text := p_data->>'type'; v_max int := (p_data->>'max')::int;
  v_start timestamptz := (p_data->>'starts_at')::timestamptz; old public.sessions; v_used int;
begin
  perform public._require_admin();
  if v_type not in ('ind','duo','grp') then raise exception 'Välj träningsform.'; end if;
  if v_max < public.min_of(v_type) or v_max > (case v_type when 'grp' then 12 when 'duo' then 3 else 1 end) then
    raise exception 'Fel antal platser för träningsformen.';
  end if;
  if p_id is null then
    insert into public.sessions(type, starts_at, max, place, focus, audience, equipment)
    values (v_type, v_start, v_max, coalesce(p_data->>'place',''), coalesce(p_data->>'focus',''),
            coalesce(p_data->>'audience',''), coalesce(p_data->>'equipment',''))
    returning id into v_id;
  else
    select * into old from public.sessions where id = p_id for update;
    if not found then raise exception 'Passet finns inte.'; end if;
    v_used := public.used_seats(p_id);
    if v_max < v_used then raise exception 'Det finns redan % bokade platser. Max kan inte vara lägre.', v_used; end if;
    if old.type <> v_type and exists (select 1 from public.bookings where session_id = p_id) then
      raise exception 'Träningsformen kan inte ändras när passet har bokningar.';
    end if;
    update public.sessions set type = v_type, starts_at = v_start, max = v_max,
      place = coalesce(p_data->>'place',''), focus = coalesce(p_data->>'focus',''),
      audience = coalesce(p_data->>'audience',''), equipment = coalesce(p_data->>'equipment',''),
      checked = case when old.starts_at <> v_start then null else checked end
    where id = p_id;
    v_id := p_id;
  end if;
  return v_id;
end $$;

create or replace function public.admin_delete_session(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  if exists (select 1 from public.bookings where session_id = p_id) then raise exception 'Passet har bokningar. Ställ in det i stället.'; end if;
  delete from public.sessions where id = p_id;
end $$;

-- Körs automatiskt var tionde minut: pass med för få bekräftade 24 h före ställs in
create or replace function public.run_checks() returns void
language plpgsql security definer set search_path = public as $$
declare s public.sessions; v_conf int; v_min int;
begin
  for s in select * from public.sessions where status = 'open' and checked is null
           and now() >= starts_at - interval '24 hours' and now() < starts_at loop
    select coalesce(sum(n), 0) into v_conf from public.bookings where session_id = s.id and status = 'confirmed';
    v_min := public.min_of(s.type);
    if s.type = 'ind' or v_conf >= v_min then
      update public.sessions set checked = 'ok' where id = s.id;
    else
      perform public._cancel_session(s.id, 'För få bekräftade spelare (' || v_conf || ' av minst ' || v_min || ')', '');
    end if;
  end loop;
end $$;

-- Interna funktioner får bara köras av databasen själv
revoke all on function public._cancel_session(uuid, text, text) from public, anon, authenticated;
revoke all on function public.run_checks() from public, anon, authenticated;
revoke all on function public._my_booking(uuid, boolean) from public, anon, authenticated;
revoke all on function public._require_admin() from public, anon, authenticated;

-- ---------- Behörighetsregler: vem ser vad ----------

alter table public.sessions enable row level security;
alter table public.families enable row level security;
alter table public.players  enable row level security;
alter table public.bookings enable row level security;
alter table public.refunds  enable row level security;
alter table public.admins   enable row level security;
alter table public.blocked  enable row level security;

drop policy if exists "Alla ser pass" on public.sessions;
create policy "Alla ser pass" on public.sessions for select using (true);

drop policy if exists "Egna uppgifter läsa" on public.families;
create policy "Egna uppgifter läsa" on public.families for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists "Egna uppgifter skapa" on public.families;
create policy "Egna uppgifter skapa" on public.families for insert with check (user_id = auth.uid());
drop policy if exists "Egna uppgifter ändra" on public.families;
create policy "Egna uppgifter ändra" on public.families for update using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "Egna spelare läsa" on public.players;
create policy "Egna spelare läsa" on public.players for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists "Egna spelare skapa" on public.players;
create policy "Egna spelare skapa" on public.players for insert with check (user_id = auth.uid());
drop policy if exists "Egna spelare ändra" on public.players;
create policy "Egna spelare ändra" on public.players for update using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "Egna bokningar läsa" on public.bookings;
create policy "Egna bokningar läsa" on public.bookings for select using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Egna återbetalningar läsa" on public.refunds;
create policy "Egna återbetalningar läsa" on public.refunds for select using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Admin ser admins" on public.admins;
create policy "Admin ser admins" on public.admins for select using (public.is_admin());

drop policy if exists "Admin spärrlista" on public.blocked;
create policy "Admin spärrlista" on public.blocked for all using (public.is_admin()) with check (public.is_admin());

-- ---------- Testpass (tas bort i adminpanelen när riktiga pass finns) ----------

insert into public.sessions(type, starts_at, max, place, focus, audience, equipment, test)
select * from (values
  ('ind', date_trunc('day', now()) + interval '1 day 16 hours', 1,  'Testplan A', 'Utifrån spelarens behov',        'Alla åldrar',     'Fotbollsskor, benskydd och vattenflaska. Bollar finns på plats.', true),
  ('grp', date_trunc('day', now()) + interval '2 days 16 hours', 12, 'Testplan B', 'Passningsspel och första touch', '9–11 år',         'Fotbollsskor, benskydd och vattenflaska. Bollar finns på plats.', true),
  ('duo', date_trunc('day', now()) + interval '3 days 15 hours 30 minutes', 3, 'Testplan A', 'Avslut',               '10–13 år',        'Fotbollsskor, benskydd och vattenflaska. Bollar finns på plats.', true),
  ('grp', date_trunc('day', now()) + interval '5 days 9 hours', 12,  'Testplan B', 'Spelförståelse',                '12–14 år',       'Fotbollsskor, benskydd och vattenflaska. Bollar finns på plats.', true),
  ('duo', date_trunc('day', now()) + interval '6 days 10 hours', 3,  'Testplan A', 'Teknik i hög fart',             '15 år och vuxna', 'Fotbollsskor, benskydd och vattenflaska. Bollar finns på plats.', true),
  ('ind', date_trunc('day', now()) + interval '7 days 17 hours', 1,  'Testplan A', 'Utifrån spelarens behov',        'Alla åldrar',     'Fotbollsskor, benskydd och vattenflaska. Bollar finns på plats.', true)
) as t(type, starts_at, max, place, focus, audience, equipment, test)
where not exists (select 1 from public.sessions where test);

-- ---------- Automatisk kontroll 24 timmar före start ----------

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'abbe-kontroll';
  perform cron.schedule('abbe-kontroll', '*/10 * * * *', 'select public.run_checks();');
exception when others then
  raise notice 'Den automatiska kontrollen kunde inte slås på: %. Slå på Cron under Integrations och kör den här delen igen.', sqlerrm;
end $$;

-- ---------- Vem är administratör (ÄNDRA ADRESSERNA) ----------

insert into public.admins(email) values
  ('abbes-epost@exempel.se'),
  ('din-epost@exempel.se')
on conflict do nothing;
