-- Color Clash: Supabase schema for real-time 1v1 games
-- IMPORTANT: This resets the earlier prototype room table and removes existing prototype rooms.
-- Run once in Supabase SQL Editor after enabling Anonymous Sign-Ins in Authentication.

drop table if exists public.cc_room_submissions cascade;
drop table if exists public.cc_room_answers cascade;
drop table if exists public.cc_rooms cascade;

create table public.cc_rooms (
  code text primary key check (code ~ '^[A-Z0-9]{6}$'),
  host_id uuid not null references auth.users(id) on delete cascade,
  host_name text not null check (char_length(host_name) between 1 and 18),
  guest_id uuid references auth.users(id) on delete set null,
  guest_name text,
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  round integer not null default 0 check (round between 0 and 9),
  host_score integer not null default 0 check (host_score >= 0),
  guest_score integer not null default 0 check (guest_score >= 0),
  host_answered boolean not null default false,
  guest_answered boolean not null default false,
  deck jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Correct answers and individual submissions are not readable by clients.
create table public.cc_room_answers (
  code text primary key references public.cc_rooms(code) on delete cascade,
  answers jsonb not null check (jsonb_typeof(answers) = 'array')
);

create table public.cc_room_submissions (
  code text not null references public.cc_rooms(code) on delete cascade,
  round integer not null,
  player_id uuid not null references auth.users(id) on delete cascade,
  answer text not null,
  correct boolean not null,
  points integer not null,
  submitted_at timestamptz not null default now(),
  primary key (code, round, player_id)
);

alter table public.cc_rooms enable row level security;
alter table public.cc_room_answers enable row level security;
alter table public.cc_room_submissions enable row level security;

drop policy if exists "cc room members can read" on public.cc_rooms;
create policy "cc room members can read"
on public.cc_rooms for select to authenticated
using (auth.uid() = host_id or auth.uid() = guest_id);

-- No direct client insert/update/delete policies: state changes go through the checked RPC functions.
revoke all on public.cc_rooms from anon, authenticated;
grant select on public.cc_rooms to authenticated;
revoke all on public.cc_room_answers from anon, authenticated;
revoke all on public.cc_room_submissions from anon, authenticated;

create or replace function public.cc_create_room(p_code text, p_name text)
returns public.cc_rooms
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_room public.cc_rooms;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  if p_code !~ '^[A-Z0-9]{6}$' then raise exception 'Invalid room code'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Player name is required'; end if;

  insert into public.cc_rooms(code, host_id, host_name)
  values (p_code, v_user, left(trim(p_name),18))
  returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.cc_join_room(p_code text, p_name text)
returns public.cc_rooms
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid();
  v_room public.cc_rooms;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Player name is required'; end if;

  select * into v_room from public.cc_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.status <> 'waiting' then raise exception 'This room has already started'; end if;
  if v_room.host_id = v_user then raise exception 'Host cannot join their own room as guest'; end if;
  if v_room.guest_id is not null then raise exception 'This room is full'; end if;

  update public.cc_rooms
  set guest_id = v_user, guest_name = left(trim(p_name),18), updated_at = now()
  where code = v_room.code
  returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.cc_start_room(p_code text, p_deck jsonb, p_answers jsonb)
returns public.cc_rooms
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_room public.cc_rooms;
begin
  select * into v_room from public.cc_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if auth.uid() is distinct from v_room.host_id then raise exception 'Only the host can start the game'; end if;
  if v_room.guest_id is null then raise exception 'Waiting for the second player'; end if;
  if v_room.status <> 'waiting' then raise exception 'Game has already started'; end if;
  if jsonb_typeof(p_deck) is distinct from 'array' or jsonb_array_length(p_deck) <> 10 then
    raise exception 'The game deck must contain 10 rounds';
  end if;
  if jsonb_typeof(p_answers) is distinct from 'array' or jsonb_array_length(p_answers) <> 10 then
    raise exception 'The answer key must contain 10 answers';
  end if;

  insert into public.cc_room_answers(code, answers)
  values (v_room.code, p_answers)
  on conflict (code) do update set answers = excluded.answers;

  update public.cc_rooms
  set status = 'playing', round = 0, host_score = 0, guest_score = 0,
      host_answered = false, guest_answered = false, deck = p_deck, updated_at = now()
  where code = v_room.code
  returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.cc_submit_answer(p_code text, p_answer text, p_elapsed_ms integer)
returns json
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_room public.cc_rooms;
  v_answers jsonb;
  v_correct boolean;
  v_points integer;
  v_host_answered boolean;
  v_guest_answered boolean;
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'Sign in is required'; end if;

  select * into v_room from public.cc_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.status <> 'playing' then raise exception 'This game is not active'; end if;
  if v_user <> v_room.host_id and v_user <> v_room.guest_id then raise exception 'You are not a member of this room'; end if;

  if exists (
    select 1 from public.cc_room_submissions
    where code = v_room.code and round = v_room.round and player_id = v_user
  ) then raise exception 'You already submitted this round'; end if;

  select answers into v_answers from public.cc_room_answers where code = v_room.code;
  v_correct := (v_answers -> v_room.round) = to_jsonb(coalesce(p_answer, ''));
  v_points := case when v_correct then greatest(10, 100 - floor(greatest(0, least(20000, coalesce(p_elapsed_ms,20000))) / 250.0)::integer) else 0 end;

  insert into public.cc_room_submissions(code, round, player_id, answer, correct, points)
  values (v_room.code, v_room.round, v_user, left(coalesce(p_answer,''),120), v_correct, v_points);

  v_host_answered := v_room.host_answered or v_user = v_room.host_id;
  v_guest_answered := v_room.guest_answered or v_user = v_room.guest_id;

  update public.cc_rooms
  set host_score = host_score + case when v_user = host_id then v_points else 0 end,
      guest_score = guest_score + case when v_user = guest_id then v_points else 0 end,
      host_answered = case when v_host_answered and v_guest_answered and v_room.round < 9 then false else v_host_answered end,
      guest_answered = case when v_host_answered and v_guest_answered and v_room.round < 9 then false else v_guest_answered end,
      round = case when v_host_answered and v_guest_answered and v_room.round < 9 then v_room.round + 1 else v_room.round end,
      status = case when v_host_answered and v_guest_answered and v_room.round = 9 then 'finished' else status end,
      updated_at = now()
  where code = v_room.code
  returning * into v_room;

  return json_build_object(
    'correct', v_correct,
    'points', v_points,
    'host_answered', v_host_answered,
    'guest_answered', v_guest_answered,
    'round', v_room.round,
    'status', v_room.status
  );
end;
$$;

revoke all on function public.cc_create_room(text,text) from public;
revoke all on function public.cc_join_room(text,text) from public;
revoke all on function public.cc_start_room(text,jsonb,jsonb) from public;
revoke all on function public.cc_submit_answer(text,text,integer) from public;
grant execute on function public.cc_create_room(text,text) to anon, authenticated;
grant execute on function public.cc_join_room(text,text) to anon, authenticated;
grant execute on function public.cc_start_room(text,jsonb,jsonb) to anon, authenticated;
grant execute on function public.cc_submit_answer(text,text,integer) to anon, authenticated;

alter table public.cc_rooms replica identity full;
do $$
begin
  alter publication supabase_realtime add table public.cc_rooms;
exception when duplicate_object then
  null;
end $$;

-- Shared multiplayer foundation for XO, Plant/Animal/Object, and Penalty Shootout.
-- This is separate from cc_* so future games never need to delete Color Clash data.
create table if not exists public.game_rooms (
  code text primary key check (code ~ '^[A-Z0-9]{6}$'),
  game_type text not null check (game_type in ('xo','plant','penalty')),
  host_id uuid not null references auth.users(id) on delete cascade,
  host_name text not null check (char_length(host_name) between 1 and 18),
  guest_id uuid references auth.users(id) on delete set null,
  guest_name text,
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  state jsonb not null default '{}'::jsonb,
  version bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.game_room_events (
  id bigint generated always as identity primary key,
  room_code text not null references public.game_rooms(code) on delete cascade,
  actor_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null check (char_length(event_type) between 1 and 32),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists game_room_events_room_id_idx
  on public.game_room_events(room_code, id);

alter table public.game_rooms enable row level security;
alter table public.game_room_events enable row level security;
drop policy if exists "game room members can read" on public.game_rooms;
create policy "game room members can read" on public.game_rooms
for select to authenticated
using (auth.uid() = host_id or auth.uid() = guest_id);
drop policy if exists "game room members can read events" on public.game_room_events;
create policy "game room members can read events" on public.game_room_events
for select to authenticated
using (exists (
  select 1 from public.game_rooms r
  where r.code = room_code and (auth.uid() = r.host_id or auth.uid() = r.guest_id)
));
revoke all on public.game_rooms from anon, authenticated;
grant select on public.game_rooms to authenticated;
revoke all on public.game_room_events from anon, authenticated;
grant select on public.game_room_events to authenticated;

create or replace function public.game_create_room(
  p_code text, p_game_type text, p_name text
) returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid(); v_room public.game_rooms;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  if p_code !~ '^[A-Z0-9]{6}$' then raise exception 'Invalid room code'; end if;
  if p_game_type not in ('xo','plant','penalty') then raise exception 'Invalid game type'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Player name is required'; end if;
  insert into public.game_rooms(code, game_type, host_id, host_name)
  values (p_code, p_game_type, v_user, left(trim(p_name),18))
  returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.game_join_room(p_code text, p_name text)
returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid(); v_room public.game_rooms;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Player name is required'; end if;
  select * into v_room from public.game_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.status <> 'waiting' then raise exception 'This room has already started'; end if;
  if v_room.host_id = v_user then raise exception 'Host cannot join their own room'; end if;
  if v_room.guest_id is not null then raise exception 'This room is full'; end if;
  update public.game_rooms set guest_id = v_user, guest_name = left(trim(p_name),18), updated_at = now()
  where code = v_room.code returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.game_publish_state(
  p_code text, p_event_type text, p_payload jsonb, p_state jsonb, p_status text default null
) returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid := auth.uid(); v_room public.game_rooms;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.game_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if v_user <> v_room.host_id and v_user <> v_room.guest_id then raise exception 'You are not a member of this room'; end if;
  if v_room.status = 'finished' then raise exception 'This game has finished'; end if;
  if p_event_type not in ('start','move','round','decision','finish','rematch') then raise exception 'Invalid event type'; end if;
  if pg_column_size(coalesce(p_payload, '{}'::jsonb)) > 8192 or pg_column_size(coalesce(p_state, '{}'::jsonb)) > 32768 then
    raise exception 'Game update is too large';
  end if;
  if p_status is not null and p_status not in ('waiting','playing','finished') then raise exception 'Invalid status'; end if;
  insert into public.game_room_events(room_code, actor_id, event_type, payload)
  values (v_room.code, v_user, p_event_type, coalesce(p_payload, '{}'::jsonb));
  update public.game_rooms
  set state = coalesce(p_state, state),
      status = coalesce(p_status, status),
      version = version + 1,
      updated_at = now()
  where code = v_room.code returning * into v_room;
  return v_room;
end;
$$;

revoke all on function public.game_create_room(text,text,text) from public;
revoke all on function public.game_join_room(text,text) from public;
revoke all on function public.game_publish_state(text,text,jsonb,jsonb,text) from public;
grant execute on function public.game_create_room(text,text,text) to anon, authenticated;
grant execute on function public.game_join_room(text,text) to anon, authenticated;
grant execute on function public.game_publish_state(text,text,jsonb,jsonb,text) to anon, authenticated;

alter table public.game_rooms replica identity full;
alter table public.game_room_events replica identity full;
do $$
begin
  alter publication supabase_realtime add table public.game_rooms;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.game_room_events;
exception when duplicate_object then null;
end $$;
