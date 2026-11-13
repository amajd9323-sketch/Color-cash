-- HEMA x Merve Multi-Game Upgrade
-- Safe to run after supabase.sql. This migration does NOT drop existing tables or rooms.
-- Requires Supabase Auth -> Anonymous Sign-Ins enabled.

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

create table if not exists public.game_plant_submissions (
  room_code text not null references public.game_rooms(code) on delete cascade,
  round_no integer not null check (round_no between 1 and 3),
  player_id uuid not null references auth.users(id) on delete cascade,
  answers jsonb not null check (jsonb_typeof(answers) = 'object'),
  submitted_at timestamptz not null default now(),
  primary key (room_code, round_no, player_id)
);

create table if not exists public.game_penalty_picks (
  room_code text not null references public.game_rooms(code) on delete cascade,
  kick_no integer not null check (kick_no between 0 and 9),
  player_id uuid not null references auth.users(id) on delete cascade,
  direction text not null check (direction in ('left','center','right')),
  submitted_at timestamptz not null default now(),
  primary key (room_code, kick_no, player_id)
);

alter table public.game_rooms enable row level security;
alter table public.game_room_events enable row level security;
alter table public.game_plant_submissions enable row level security;
alter table public.game_penalty_picks enable row level security;

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

drop policy if exists "game members can read plant submissions" on public.game_plant_submissions;
create policy "game members can read plant submissions" on public.game_plant_submissions
for select to authenticated
using (exists (
  select 1 from public.game_rooms r
  where r.code = room_code
    and (auth.uid() = r.host_id or auth.uid() = r.guest_id)
    and r.state->>'phase' in ('review','results','finished')
));

revoke all on public.game_rooms from anon, authenticated;
grant select on public.game_rooms to authenticated;
revoke all on public.game_room_events from anon, authenticated;
grant select on public.game_room_events to authenticated;
revoke all on public.game_plant_submissions from anon, authenticated;
grant select on public.game_plant_submissions to authenticated;
revoke all on public.game_penalty_picks from anon, authenticated;

create or replace function public.game_create_room(p_code text, p_game_type text, p_name text)
returns public.game_rooms
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
  if p_event_type <> 'start' then raise exception 'Unsupported generic room event'; end if;
  if v_room.status <> 'waiting' then raise exception 'Game has already started'; end if;
  if v_user <> v_room.host_id then raise exception 'Only the host can start the game'; end if;
  if v_room.guest_id is null then raise exception 'Waiting for the second player'; end if;
  if p_status <> 'playing' then raise exception 'Invalid start status'; end if;
  if pg_column_size(coalesce(p_payload, '{}'::jsonb)) > 8192 or pg_column_size(coalesce(p_state, '{}'::jsonb)) > 32768 then
    raise exception 'Game update is too large';
  end if;
  insert into public.game_room_events(room_code, actor_id, event_type, payload)
  values (v_room.code, v_user, 'start', coalesce(p_payload, '{}'::jsonb));
  update public.game_rooms
  set state = coalesce(p_state, '{}'::jsonb), status = 'playing',
      version = version + 1, updated_at = now()
  where code = v_room.code returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.game_xo_move(p_code text, p_index integer)
returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_room public.game_rooms;
  v_user uuid := auth.uid();
  v_board jsonb;
  v_cells text[];
  v_symbol text;
  v_next uuid;
  v_winner boolean := false;
  v_draw boolean := false;
  v_moves integer;
  v_state jsonb;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  if p_index < 0 or p_index > 8 then raise exception 'Invalid cell'; end if;
  select * into v_room from public.game_rooms where code = upper(trim(p_code)) for update;
  if not found or v_room.game_type <> 'xo' then raise exception 'XO room not found'; end if;
  if v_room.status <> 'playing' then raise exception 'Game is not active'; end if;
  if v_user <> v_room.host_id and v_user <> v_room.guest_id then raise exception 'You are not a room member'; end if;
  if (v_room.state->>'turn')::uuid is distinct from v_user then raise exception 'It is not your turn'; end if;

  v_board := v_room.state->'board';
  if jsonb_typeof(v_board) <> 'array' or jsonb_array_length(v_board) <> 9 then raise exception 'Invalid board'; end if;
  if v_board->p_index <> 'null'::jsonb then raise exception 'Cell is already used'; end if;

  v_symbol := case when v_user = v_room.host_id then 'X' else 'O' end;
  v_board := jsonb_set(v_board, array[p_index::text], to_jsonb(v_symbol), false);
  select array[
    v_board->>0,v_board->>1,v_board->>2,v_board->>3,v_board->>4,
    v_board->>5,v_board->>6,v_board->>7,v_board->>8
  ] into v_cells;

  if (v_cells[1] is not null and v_cells[1]=v_cells[2] and v_cells[2]=v_cells[3]) or
     (v_cells[4] is not null and v_cells[4]=v_cells[5] and v_cells[5]=v_cells[6]) or
     (v_cells[7] is not null and v_cells[7]=v_cells[8] and v_cells[8]=v_cells[9]) or
     (v_cells[1] is not null and v_cells[1]=v_cells[4] and v_cells[4]=v_cells[7]) or
     (v_cells[2] is not null and v_cells[2]=v_cells[5] and v_cells[5]=v_cells[8]) or
     (v_cells[3] is not null and v_cells[3]=v_cells[6] and v_cells[6]=v_cells[9]) or
     (v_cells[1] is not null and v_cells[1]=v_cells[5] and v_cells[5]=v_cells[9]) or
     (v_cells[3] is not null and v_cells[3]=v_cells[5] and v_cells[5]=v_cells[7]) then
    v_winner := true;
  end if;

  v_moves := coalesce((v_room.state->>'moves')::integer,0)+1;
  v_draw := not v_winner and v_moves >= 9;
  v_next := case when v_user = v_room.host_id then v_room.guest_id else v_room.host_id end;
  v_state := v_room.state || jsonb_build_object(
    'board',v_board,'moves',v_moves,'winner',case when v_winner then to_jsonb(v_user) else 'null'::jsonb end,
    'draw',v_draw,'turn',case when v_winner or v_draw then null else to_jsonb(v_next) end
  );

  update public.game_rooms set state=v_state,
    status=case when v_winner or v_draw then 'finished' else 'playing' end,
    version=version+1, updated_at=now()
  where code=v_room.code returning * into v_room;
  insert into public.game_room_events(room_code,actor_id,event_type,payload)
  values(v_room.code,v_user,'move',jsonb_build_object('index',p_index,'symbol',v_symbol));
  return v_room;
end;
$$;

create or replace function public.game_plant_submit(p_code text, p_answers jsonb)
returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid:=auth.uid(); v_room public.game_rooms; v_count integer;
  v_key text; v_value text; v_clean jsonb:='{}'::jsonb; v_letter text; v_first text;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  if jsonb_typeof(p_answers) <> 'object' or pg_column_size(p_answers) > 8192 then raise exception 'Invalid answers'; end if;
  select * into v_room from public.game_rooms where code=upper(trim(p_code)) for update;
  if not found or v_room.game_type <> 'plant' then raise exception 'Plant game room not found'; end if;
  if v_room.status <> 'playing' or v_room.state->>'phase' <> 'answer' then raise exception 'Round is not accepting answers'; end if;
  if v_user <> v_room.host_id and v_user <> v_room.guest_id then raise exception 'You are not a room member'; end if;

  v_letter:=v_room.state->>'letter';
  foreach v_key in array array['name','plant','animal','object','country'] loop
    v_value:=btrim(coalesce(p_answers->>v_key,''));
    v_first:=left(v_value,1);
    if v_value<>'' and v_first<>v_letter and not (v_letter='أ' and v_first in ('ا','أ','إ','آ')) then
      v_value:='';
    end if;
    v_clean:=v_clean||jsonb_build_object(v_key,v_value);
  end loop;

  insert into public.game_plant_submissions(room_code,round_no,player_id,answers)
  values(v_room.code,(v_room.state->>'round')::integer,v_user,v_clean);
  select count(*) into v_count from public.game_plant_submissions
  where room_code=v_room.code and round_no=(v_room.state->>'round')::integer;
  update public.game_rooms
  set state=case when v_count=2 then state || jsonb_build_object('phase','review') else state end,
      version=version+1,updated_at=now()
  where code=v_room.code returning * into v_room;
  insert into public.game_room_events(room_code,actor_id,event_type,payload)
  values(v_room.code,v_user,'round',jsonb_build_object('round',(v_room.state->>'round')::integer,'submitted',true));
  return v_room;
end;
$$;


create or replace function public.game_plant_my_submission(p_code text)
returns boolean
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid:=auth.uid(); v_room public.game_rooms;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.game_rooms where code=upper(trim(p_code));
  if not found or v_room.game_type<>'plant' then raise exception 'Plant room not found'; end if;
  if v_user<>v_room.host_id and v_user<>v_room.guest_id then raise exception 'You are not a room member'; end if;
  return exists(
    select 1 from public.game_plant_submissions
    where room_code=v_room.code and round_no=(v_room.state->>'round')::integer and player_id=v_user
  );
end;
$$;

create or replace function public.game_plant_resolve(p_code text)
returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid := auth.uid(); v_room public.game_rooms;
  v_host jsonb; v_guest jsonb; v_key text;
  v_hp integer:=0; v_gp integer:=0;
  v_h text; v_g text; v_scores jsonb;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.game_rooms where code=upper(trim(p_code)) for update;
  if not found or v_room.game_type <> 'plant' then raise exception 'Plant room not found'; end if;
  if v_user <> v_room.host_id and v_user <> v_room.guest_id then raise exception 'You are not a room member'; end if;
  if v_room.state->>'phase'='results' then return v_room; end if;
  if v_room.state->>'phase'<>'review' then raise exception 'Both players have not submitted yet'; end if;
  select answers into v_host from public.game_plant_submissions
   where room_code=v_room.code and round_no=(v_room.state->>'round')::integer and player_id=v_room.host_id;
  select answers into v_guest from public.game_plant_submissions
   where room_code=v_room.code and round_no=(v_room.state->>'round')::integer and player_id=v_room.guest_id;
  if v_host is null or v_guest is null then raise exception 'Missing player answers'; end if;

  foreach v_key in array array['plant','animal','object','country','name'] loop
    v_h := nullif(lower(btrim(coalesce(v_host->>v_key,''))),'');
    v_g := nullif(lower(btrim(coalesce(v_guest->>v_key,''))),'');
    if v_h is not null and v_g is not null and v_h=v_g then
      v_hp:=v_hp+5; v_gp:=v_gp+5;
    elsif v_h is not null then v_hp:=v_hp+10;
    elsif v_g is not null then v_gp:=v_gp+10;
    end if;
  end loop;

  v_scores:=jsonb_build_object(
    'host',coalesce((v_room.state->'scores'->>'host')::integer,0)+v_hp,
    'guest',coalesce((v_room.state->'scores'->>'guest')::integer,0)+v_gp
  );
  update public.game_rooms set
    state=state || jsonb_build_object('phase','results','scores',v_scores,
      'lastPoints',jsonb_build_object('host',v_hp,'guest',v_gp)),
    version=version+1,updated_at=now()
  where code=v_room.code returning * into v_room;
  return v_room;
end;
$$;

create or replace function public.game_plant_next(p_code text)
returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare v_user uuid:=auth.uid(); v_room public.game_rooms;
  v_round integer; v_letters text[]:=array['أ','ب','ت','ج','ح','د','ر','س','ع','ف','ك','م','ن','ه','و'];
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  select * into v_room from public.game_rooms where code=upper(trim(p_code)) for update;
  if not found or v_room.game_type<>'plant' then raise exception 'Plant room not found'; end if;
  if v_user<>v_room.host_id and v_user<>v_room.guest_id then raise exception 'You are not a room member'; end if;
  if v_room.state->>'phase'<>'results' then raise exception 'Finish current round first'; end if;
  v_round:=(v_room.state->>'round')::integer;
  if v_round>=3 then
    update public.game_rooms set state=state||jsonb_build_object('phase','finished'),
      status='finished',version=version+1,updated_at=now()
    where code=v_room.code returning * into v_room;
  else
    update public.game_rooms set state=state||jsonb_build_object(
      'phase','answer','round',v_round+1,'letter',v_letters[1+floor(random()*array_length(v_letters,1))::integer]
    ),version=version+1,updated_at=now()
    where code=v_room.code returning * into v_room;
  end if;
  return v_room;
end;
$$;

create or replace function public.game_penalty_pick(p_code text,p_direction text)
returns public.game_rooms
language plpgsql security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_user uuid:=auth.uid(); v_room public.game_rooms;
  v_kick integer; v_shooter uuid; v_shoot_dir text; v_keep_dir text;
  v_count integer; v_hg integer; v_gg integer; v_goal boolean;
  v_state jsonb;
begin
  if v_user is null then raise exception 'Sign in is required'; end if;
  if p_direction not in ('left','center','right') then raise exception 'Invalid direction'; end if;
  select * into v_room from public.game_rooms where code=upper(trim(p_code)) for update;
  if not found or v_room.game_type<>'penalty' then raise exception 'Penalty room not found'; end if;
  if v_room.status<>'playing' then raise exception 'Match is not active'; end if;
  if v_user<>v_room.host_id and v_user<>v_room.guest_id then raise exception 'You are not a room member'; end if;
  v_kick:=coalesce((v_room.state->>'kick')::integer,0);
  if v_kick>9 then raise exception 'All penalties have been taken'; end if;
  insert into public.game_penalty_picks(room_code,kick_no,player_id,direction)
  values(v_room.code,v_kick,v_user,p_direction);
  select count(*) into v_count from public.game_penalty_picks where room_code=v_room.code and kick_no=v_kick;
  if v_count<2 then
    update public.game_rooms set version=version+1,updated_at=now()
    where code=v_room.code returning * into v_room;
    return v_room;
  end if;

  v_shooter:=case when mod(v_kick,2)=0 then v_room.host_id else v_room.guest_id end;
  select direction into v_shoot_dir from public.game_penalty_picks
   where room_code=v_room.code and kick_no=v_kick and player_id=v_shooter;
  select direction into v_keep_dir from public.game_penalty_picks
   where room_code=v_room.code and kick_no=v_kick and player_id<>v_shooter;
  v_goal:=v_shoot_dir is distinct from v_keep_dir;
  v_hg:=coalesce((v_room.state->>'hostGoals')::integer,0);
  v_gg:=coalesce((v_room.state->>'guestGoals')::integer,0);
  if v_goal then
    if v_shooter=v_room.host_id then v_hg:=v_hg+1; else v_gg:=v_gg+1; end if;
  end if;
  v_state:=v_room.state||jsonb_build_object(
    'kick',v_kick+1,'hostGoals',v_hg,'guestGoals',v_gg,
    'lastShot',jsonb_build_object('shooter',v_shooter,'goal',v_goal,'shotDirection',v_shoot_dir,'keeperDirection',v_keep_dir)
  );
  update public.game_rooms set state=v_state,status=case when v_kick=9 then 'finished' else 'playing' end,
    version=version+1,updated_at=now()
  where code=v_room.code returning * into v_room;
  insert into public.game_room_events(room_code,actor_id,event_type,payload)
  values(v_room.code,v_user,'move',jsonb_build_object('kick',v_kick,'goal',v_goal));
  return v_room;
end;
$$;

revoke all on function public.game_create_room(text,text,text) from public;
revoke all on function public.game_join_room(text,text) from public;
revoke all on function public.game_publish_state(text,text,jsonb,jsonb,text) from public;
revoke all on function public.game_xo_move(text,integer) from public;
revoke all on function public.game_plant_submit(text,jsonb) from public;
revoke all on function public.game_plant_my_submission(text) from public;
grant execute on function public.game_plant_my_submission(text) to anon, authenticated;
revoke all on function public.game_plant_resolve(text) from public;
revoke all on function public.game_plant_next(text) from public;
revoke all on function public.game_penalty_pick(text,text) from public;

grant execute on function public.game_create_room(text,text,text) to anon, authenticated;
grant execute on function public.game_join_room(text,text) to anon, authenticated;
grant execute on function public.game_publish_state(text,text,jsonb,jsonb,text) to anon, authenticated;
grant execute on function public.game_xo_move(text,integer) to anon, authenticated;
grant execute on function public.game_plant_submit(text,jsonb) to anon, authenticated;
grant execute on function public.game_plant_resolve(text) to anon, authenticated;
grant execute on function public.game_plant_next(text) to anon, authenticated;
grant execute on function public.game_penalty_pick(text,text) to anon, authenticated;

alter table public.game_rooms replica identity full;
do $$
begin
  alter publication supabase_realtime add table public.game_rooms;
exception when duplicate_object then null;
end $$;

-- Realtime notifies both players when room state changes.
