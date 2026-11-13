-- Color Clash Supabase starter schema
create table if not exists public.cc_rooms (
 code text primary key,
 host_id text not null,
 host_name text not null,
 guest_id text,
 guest_name text,
 status text not null default 'waiting' check (status in ('waiting','playing','finished')),
 round integer not null default 0,
 host_score integer not null default 0,
 guest_score integer not null default 0,
 created_at timestamptz not null default now()
);
alter table public.cc_rooms enable row level security;
-- Prototype policies only. Replace with authenticated, membership-based policies before production.
create policy "rooms can be read" on public.cc_rooms for select to anon, authenticated using (true);
create policy "rooms can be created" on public.cc_rooms for insert to anon, authenticated with check (true);
create policy "rooms can be updated" on public.cc_rooms for update to anon, authenticated using (true) with check (true);
alter publication supabase_realtime add table public.cc_rooms;