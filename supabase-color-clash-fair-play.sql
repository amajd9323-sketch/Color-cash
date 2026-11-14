-- Color Clash Fair Play Upgrade
-- Run after supabase.sql. This is additive and preserves rooms, profiles, friends and scores.

create table if not exists public.cc_match_history (
  id bigint generated always as identity primary key,
  room_code text not null,
  set_number integer not null,
  host_id uuid not null references auth.users(id) on delete cascade,
  guest_id uuid not null references auth.users(id) on delete cascade,
  host_name text not null,
  guest_name text not null,
  host_score integer not null check (host_score >= 0),
  guest_score integer not null check (guest_score >= 0),
  winner_id uuid references auth.users(id) on delete set null,
  host_correct integer not null default 0 check (host_correct between 0 and 10),
  guest_correct integer not null default 0 check (guest_correct between 0 and 10),
  host_powerups integer not null default 0 check (host_powerups between 0 and 2),
  guest_powerups integer not null default 0 check (guest_powerups between 0 and 2),
  played_at timestamptz not null default now(),
  unique (room_code, set_number)
);

alter table public.cc_match_history enable row level security;
drop policy if exists "cc match history visible to match players" on public.cc_match_history;
create policy "cc match history visible to match players"
on public.cc_match_history for select to authenticated
using ((select auth.uid()) = host_id or (select auth.uid()) = guest_id);
revoke all on public.cc_match_history from anon, authenticated;
grant select on public.cc_match_history to authenticated;
create index if not exists cc_match_history_host_played_idx
  on public.cc_match_history(host_id, played_at desc);
create index if not exists cc_match_history_guest_played_idx
  on public.cc_match_history(guest_id, played_at desc);

create or replace function private.cc_room_event_send_core(
  p_code text, p_event_type text, p_payload jsonb
)
returns public.cc_room_events
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $function$
declare
  v_room public.cc_rooms;
  v_event public.cc_room_events;
  v_type text := p_event_type;
  v_set_uses integer := 0;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into v_room from public.cc_rooms
  where code = upper(trim(p_code)) for update;
  if not found or (v_room.host_id <> auth.uid() and v_room.guest_id <> auth.uid()) then
    raise exception 'Room not found or access denied';
  end if;
  if v_room.status <> 'playing' then raise exception 'Room is not playing'; end if;
  if v_type not in ('reaction','powerup:extra_time','powerup:reveal','powerup:freeze') then
    raise exception 'Invalid event';
  end if;
  if pg_column_size(coalesce(p_payload, '{}'::jsonb)) > 512 then
    raise exception 'Event payload is too large';
  end if;

  if v_type like 'powerup:%' then
    if exists (
      select 1 from public.cc_room_submissions
      where code = v_room.code and round = v_room.round and player_id = auth.uid()
    ) then
      raise exception 'You already answered this round';
    end if;
    select count(*)::integer into v_set_uses
    from public.cc_room_events
    where code = v_room.code and set_number = v_room.set_number
      and actor_id = auth.uid() and event_type like 'powerup:%';
    if v_set_uses >= 2 then raise exception 'No power-up charges left this set'; end if;
    if exists (
      select 1 from public.cc_room_events
      where code = v_room.code and set_number = v_room.set_number
        and round = v_room.round and actor_id = auth.uid()
        and event_type like 'powerup:%'
    ) then
      raise exception 'Only one power-up can be used per round';
    end if;
    if exists (
      select 1 from public.cc_room_events
      where code = v_room.code and set_number = v_room.set_number
        and actor_id = auth.uid() and event_type = v_type
    ) then
      raise exception 'Each power-up type can only be used once per set';
    end if;
  end if;

  insert into public.cc_room_events(code,set_number,round,actor_id,event_type,payload)
  values(v_room.code,v_room.set_number,v_room.round,auth.uid(),v_type,coalesce(p_payload,'{}'::jsonb))
  returning * into v_event;
  return v_event;
end;
$function$;

create or replace function private.cc_submit_answer_core(
  p_code text, p_answer text, p_elapsed_ms integer
)
returns json
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $function$
declare
  v_room public.cc_rooms;
  v_answers jsonb;
  v_correct boolean;
  v_points integer;
  v_host_answered boolean;
  v_guest_answered boolean;
  v_host_total integer;
  v_guest_total integer;
  v_set_complete boolean;
  v_user uuid := auth.uid();
  v_powerups integer := 0;
  v_host_correct integer := 0;
  v_guest_correct integer := 0;
  v_host_powerups integer := 0;
  v_guest_powerups integer := 0;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.cc_rooms
  where code = upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found'; end if;
  if v_room.status <> 'playing' then raise exception 'This game is not active'; end if;
  if v_user <> v_room.host_id and v_user <> v_room.guest_id then
    raise exception 'You are not a member of this room';
  end if;
  if exists (
    select 1 from public.cc_room_submissions
    where code = v_room.code and round = v_room.round and player_id = v_user
  ) then raise exception 'You already submitted this round'; end if;

  select answers into v_answers from public.cc_room_answers where code = v_room.code;
  v_correct := (v_answers -> v_room.round) = to_jsonb(coalesce(p_answer, ''));
  v_points := case when v_correct then greatest(
    10, 100 - floor(greatest(0, least(35000, coalesce(p_elapsed_ms,35000))) / 350.0)::integer
  ) else 0 end;

  select count(*)::integer into v_powerups
  from public.cc_room_events
  where code = v_room.code and set_number = v_room.set_number
    and round = v_room.round and actor_id = v_user and event_type like 'powerup:%';
  if v_correct and v_powerups > 0 then
    v_points := greatest(1, floor(v_points * 0.75)::integer);
  end if;

  insert into public.cc_room_submissions(code,round,player_id,answer,correct,points)
  values(v_room.code,v_room.round,v_user,left(coalesce(p_answer,''),120),v_correct,v_points);

  v_host_answered := v_room.host_answered or v_user = v_room.host_id;
  v_guest_answered := v_room.guest_answered or v_user = v_room.guest_id;
  v_host_total := v_room.host_score + case when v_user = v_room.host_id then v_points else 0 end;
  v_guest_total := v_room.guest_score + case when v_user = v_room.guest_id then v_points else 0 end;
  v_set_complete := v_host_answered and v_guest_answered and v_room.round = 9;

  update public.cc_rooms
  set host_score = v_host_total,
      guest_score = v_guest_total,
      host_answered = case when v_host_answered and v_guest_answered and v_room.round < 9 then false else v_host_answered end,
      guest_answered = case when v_host_answered and v_guest_answered and v_room.round < 9 then false else v_guest_answered end,
      round = case when v_host_answered and v_guest_answered and v_room.round < 9 then v_room.round + 1 else v_room.round end,
      host_wins = host_wins + case when v_set_complete and v_host_total > v_guest_total and host_wins < 3 then 1 else 0 end,
      guest_wins = guest_wins + case when v_set_complete and v_guest_total > v_host_total and guest_wins < 3 then 1 else 0 end,
      status = case when v_set_complete then 'finished' else status end,
      updated_at = now()
  where code = v_room.code returning * into v_room;

  if v_set_complete then
    select
      count(*) filter (where player_id = v_room.host_id and correct)::integer,
      count(*) filter (where player_id = v_room.guest_id and correct)::integer
    into v_host_correct,v_guest_correct
    from public.cc_room_submissions
    where code = v_room.code and round between 0 and 9;

    select
      count(*) filter (where actor_id = v_room.host_id and event_type like 'powerup:%')::integer,
      count(*) filter (where actor_id = v_room.guest_id and event_type like 'powerup:%')::integer
    into v_host_powerups,v_guest_powerups
    from public.cc_room_events
    where code = v_room.code and set_number = v_room.set_number;

    insert into public.cc_match_history(
      room_code,set_number,host_id,guest_id,host_name,guest_name,
      host_score,guest_score,winner_id,host_correct,guest_correct,
      host_powerups,guest_powerups
    )
    values(
      v_room.code,v_room.set_number,v_room.host_id,v_room.guest_id,
      v_room.host_name,v_room.guest_name,v_room.host_score,v_room.guest_score,
      case when v_room.host_score > v_room.guest_score then v_room.host_id
           when v_room.guest_score > v_room.host_score then v_room.guest_id else null end,
      coalesce(v_host_correct,0),coalesce(v_guest_correct,0),
      coalesce(v_host_powerups,0),coalesce(v_guest_powerups,0)
    )
    on conflict (room_code,set_number) do nothing;
  end if;

  return json_build_object(
    'correct',v_correct,'points',v_points,'powerup_penalty',(v_correct and v_powerups > 0),
    'host_answered',v_host_answered,'guest_answered',v_guest_answered,
    'round',v_room.round,'status',v_room.status,
    'host_wins',v_room.host_wins,'guest_wins',v_room.guest_wins,
    'set_number',v_room.set_number,
    'series_finished',(v_room.host_wins >= 3 or v_room.guest_wins >= 3)
  );
end;
$function$;
