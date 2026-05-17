-- =====================================================================
--  YAZAR.IO  ·  Supabase setup
-- =====================================================================
--  Run this whole file in the Supabase SQL Editor (project → SQL → New
--  query → paste → Run). It is idempotent: re-running won't drop data.
--
--  What it does:
--    • Creates tables: profiles, player_stats, match_history,
--      inventory_items, player_inventory, achievements,
--      player_achievements
--    • Enables RLS on every table and adds per-user policies
--    • Creates a trigger that auto-creates a fresh profile + stats row
--      whenever a new auth.users row is inserted
--    • Creates the `submit_match_result` RPC (SECURITY DEFINER) used by
--      the client at the end of every match
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  username    text,
  avatar_url  text,
  level       int  not null default 1,
  xp          int  not null default 0,
  coins       int  not null default 200,
  dna         int  not null default 50,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Idempotent: re-running setup nudges defaults to the new-user starter
-- values without touching any existing player's balance.
alter table public.profiles alter column coins set default 200;
alter table public.profiles alter column dna   set default 50;

create table if not exists public.player_stats (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references auth.users(id) on delete cascade unique,
  matches_played         int  not null default 0,
  best_score             int  not null default 0,
  total_score            bigint not null default 0,
  total_mass_collected   bigint not null default 0,
  total_kills            int  not null default 0,
  total_deaths           int  not null default 0,
  total_survival_seconds bigint not null default 0,
  wins                   int  not null default 0,
  updated_at             timestamptz not null default now()
);

create table if not exists public.match_history (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  score            int  not null default 0,
  mass_collected   int  not null default 0,
  kills            int  not null default 0,
  survival_seconds int  not null default 0,
  rank             int  not null default 9999,
  coins_earned     int  not null default 0,
  dna_earned       int  not null default 0,
  xp_earned        int  not null default 0,
  created_at       timestamptz not null default now()
);
create index if not exists match_history_user_created_idx
  on public.match_history(user_id, created_at desc);

create table if not exists public.inventory_items (
  id          uuid primary key default gen_random_uuid(),
  key         text unique not null,
  name        text not null,
  type        text not null,
  rarity      text default 'common',
  price_coins int  default 0,
  price_dna   int  default 0,
  image_url   text,
  created_at  timestamptz not null default now()
);

create table if not exists public.player_inventory (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  item_id     uuid not null references public.inventory_items(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  equipped    boolean not null default false,
  unique (user_id, item_id)
);

create table if not exists public.achievements (
  id            uuid primary key default gen_random_uuid(),
  key           text unique not null,
  name          text not null,
  description   text,
  reward_coins  int default 0,
  reward_dna    int default 0,
  reward_xp     int default 0
);

create table if not exists public.player_achievements (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  achievement_id uuid not null references public.achievements(id) on delete cascade,
  unlocked_at    timestamptz not null default now(),
  unique (user_id, achievement_id)
);

-- ---------------------------------------------------------------------
-- 2. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.profiles            enable row level security;
alter table public.player_stats        enable row level security;
alter table public.match_history       enable row level security;
alter table public.inventory_items     enable row level security;
alter table public.player_inventory    enable row level security;
alter table public.achievements        enable row level security;
alter table public.player_achievements enable row level security;

-- profiles: a user can see/update only their own row.
drop policy if exists "profiles self select"    on public.profiles;
drop policy if exists "profiles self update"    on public.profiles;
drop policy if exists "profiles self insert"    on public.profiles;
create policy "profiles self select" on public.profiles
  for select using (auth.uid() = id);
create policy "profiles self update" on public.profiles
  for update using (auth.uid() = id);
create policy "profiles self insert" on public.profiles
  for insert with check (auth.uid() = id);
-- NOTE: clients CAN write to email/username/avatar_url/updated_at but the
-- RPC is the only path that touches coins/dna/xp/level (security definer).
-- If you want to harden this further, use a column-level grant or revoke
-- update on those columns from authenticated users.

-- player_stats: read-only for the owner. All writes go through the RPC.
drop policy if exists "stats self select" on public.player_stats;
create policy "stats self select" on public.player_stats
  for select using (auth.uid() = user_id);

-- match_history: read-only for the owner.
drop policy if exists "history self select" on public.match_history;
create policy "history self select" on public.match_history
  for select using (auth.uid() = user_id);

-- inventory_items: world-readable catalogue.
drop policy if exists "items world read" on public.inventory_items;
create policy "items world read" on public.inventory_items
  for select using (true);

-- player_inventory: read/update own row (no inserts from client).
drop policy if exists "inv self select" on public.player_inventory;
drop policy if exists "inv self update" on public.player_inventory;
create policy "inv self select" on public.player_inventory
  for select using (auth.uid() = user_id);
create policy "inv self update" on public.player_inventory
  for update using (auth.uid() = user_id);

-- achievements: world-readable catalogue.
drop policy if exists "ach world read" on public.achievements;
create policy "ach world read" on public.achievements
  for select using (true);

-- player_achievements: read-only for the owner.
drop policy if exists "pach self select" on public.player_achievements;
create policy "pach self select" on public.player_achievements
  for select using (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- 3. NEW-USER TRIGGER  (clean fresh state on every signup)
-- ---------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- New users only: ON CONFLICT DO NOTHING ensures we NEVER overwrite an
  -- existing player's balance. The starter (200 coins, 50 DNA) is applied
  -- exactly once, at signup.
  insert into public.profiles (id, email, username, level, xp, coins, dna)
  values (
    new.id,
    new.email,
    coalesce(split_part(new.email, '@', 1), 'Player'),
    1,
    0,
    200,
    50
  )
  on conflict (id) do nothing;

  insert into public.player_stats (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 4. RPC  ·  submit_match_result
-- ---------------------------------------------------------------------
-- This is the ONLY path that mutates coins / dna / xp / level. Because it
-- is SECURITY DEFINER it runs as table owner and can write past RLS, but
-- it uses auth.uid() internally so a user can only ever update their own
-- row.

create or replace function public.submit_match_result(
  p_score            int,
  p_mass_collected   int,
  p_kills            int,
  p_survival_seconds int,
  p_rank             int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user        uuid := auth.uid();
  v_score       int  := greatest(coalesce(p_score, 0), 0);
  v_mass        int  := greatest(coalesce(p_mass_collected, 0), 0);
  v_kills       int  := greatest(coalesce(p_kills, 0), 0);
  v_survival    int  := greatest(coalesce(p_survival_seconds, 0), 0);
  v_rank        int  := greatest(coalesce(p_rank, 9999), 1);

  v_coins_earned int;
  v_dna_earned   int;
  v_xp_earned    int;
  v_xp_mult      numeric := 1.0;

  v_prev_level   int;
  v_prev_xp      int;
  v_new_xp       int;
  v_new_level    int;
  v_required     int;
  v_leveled_up   boolean := false;
  v_levels_gained int := 0;
  v_level_up_coins int := 0;
  v_level_up_dna   int := 0;

  v_profile      profiles%rowtype;
  v_coins_total  int;
  v_dna_total    int;
begin
  if v_user is null then
    raise exception 'Not authenticated';
  end if;

  -- ---------- match reward formulas ----------------------------------
  -- Coins and DNA are ONLY earned through leveling up (not per-match).
  v_coins_earned := 0;
  v_dna_earned   := 0;
  v_xp_earned    := (v_score / 3)
                    + (v_kills * 12)
                    + (v_survival / 2)
                    + greatest(0, 50 - v_rank) * 4;

  v_xp_earned    := greatest(v_xp_earned, 1);

  -- ---------- XP BOOST (server-side, cannot be faked) ---------------
  -- Expire stale boosts first, then pick the strongest still-active XP
  -- boost for this user (if any) and multiply.
  update public.player_boosts
     set status = 'expired'
   where user_id = v_user
     and status = 'active'
     and expires_at <= now();

  select coalesce(max(bd.multiplier), 1.0) into v_xp_mult
    from public.player_boosts pb
    join public.boost_definitions bd on bd.id = pb.boost_id
   where pb.user_id = v_user
     and bd.type = 'xp'
     and pb.status = 'active'
     and pb.expires_at > now();

  v_xp_earned := floor(v_xp_earned * v_xp_mult)::int;

  -- ---------- read current profile (insert if missing) ---------------
  insert into public.profiles (id, email, coins, dna)
  values (v_user, (select email from auth.users where id = v_user), 200, 50)
  on conflict (id) do nothing;

  select * into v_profile from public.profiles where id = v_user for update;
  v_prev_level := coalesce(v_profile.level, 1);
  v_prev_xp    := coalesce(v_profile.xp, 0);

  v_new_xp    := v_prev_xp + v_xp_earned;
  v_new_level := v_prev_level;

  -- ---------- level-up loop (requiredXP = 100 * level * level) ------
  -- Each level-up adds a FLAT +100 Coins and +20 DNA (spec).
  loop
    v_required := 100 * v_new_level * v_new_level;
    exit when v_new_xp < v_required;
    v_new_xp        := v_new_xp - v_required;
    v_new_level     := v_new_level + 1;
    v_levels_gained := v_levels_gained + 1;
    v_leveled_up    := true;
    v_level_up_coins := v_level_up_coins + 100;
    v_level_up_dna   := v_level_up_dna + 20;
  end loop;

  v_coins_total := coalesce(v_profile.coins, 0) + v_coins_earned + v_level_up_coins;
  v_dna_total   := coalesce(v_profile.dna,   0) + v_dna_earned   + v_level_up_dna;

  -- ---------- write profile -----------------------------------------
  update public.profiles
     set level      = v_new_level,
         xp         = v_new_xp,
         coins      = v_coins_total,
         dna        = v_dna_total,
         updated_at = now()
   where id = v_user;

  -- ---------- write player_stats ------------------------------------
  insert into public.player_stats (user_id) values (v_user)
  on conflict (user_id) do nothing;

  update public.player_stats
     set matches_played         = matches_played + 1,
         best_score             = greatest(best_score, v_score),
         total_score            = total_score + v_score,
         total_mass_collected   = total_mass_collected + v_mass,
         total_kills            = total_kills + v_kills,
         total_deaths           = total_deaths + 1,
         total_survival_seconds = total_survival_seconds + v_survival,
         wins                   = wins + case when v_rank = 1 then 1 else 0 end,
         updated_at             = now()
   where user_id = v_user;

  -- ---------- match_history row -------------------------------------
  insert into public.match_history (
    user_id, score, mass_collected, kills, survival_seconds, rank,
    coins_earned, dna_earned, xp_earned
  ) values (
    v_user, v_score, v_mass, v_kills, v_survival, v_rank,
    v_coins_earned + v_level_up_coins,
    v_dna_earned   + v_level_up_dna,
    v_xp_earned
  );

  return jsonb_build_object(
    'level',                  v_new_level,
    'xp',                     v_new_xp,
    'coins',                  v_coins_total,
    'dna',                    v_dna_total,
    'coins_earned',           v_coins_earned,
    'dna_earned',             v_dna_earned,
    'xp_earned',              v_xp_earned,
    'xp_multiplier',          v_xp_mult,
    'level_up_coins_earned',  v_level_up_coins,
    'level_up_dna_earned',    v_level_up_dna,
    'levels_gained',          v_levels_gained,
    'leveled_up',             v_leveled_up
  );
end;
$$;

grant execute on function public.submit_match_result(int, int, int, int, int)
  to authenticated;

-- =====================================================================
-- 5. BOOSTS  ·  catalogue + per-player ownership + RPCs
-- =====================================================================

create table if not exists public.boost_definitions (
  id               uuid primary key default gen_random_uuid(),
  key              text unique not null,
  name             text not null,
  type             text not null check (type in ('mass', 'xp')),
  multiplier       numeric not null check (multiplier >= 1),
  duration_seconds int not null check (duration_seconds > 0),
  price_coins      int not null default 0 check (price_coins >= 0),
  price_dna        int not null default 0 check (price_dna   >= 0),
  description      text,
  icon_url         text,
  created_at       timestamptz not null default now()
);

create table if not exists public.player_boosts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  boost_id      uuid not null references public.boost_definitions(id) on delete cascade,
  status        text not null default 'owned'
                  check (status in ('owned', 'active', 'expired', 'used')),
  purchased_at  timestamptz not null default now(),
  activated_at  timestamptz,
  expires_at    timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists player_boosts_user_id_idx on public.player_boosts(user_id);
create index if not exists player_boosts_status_idx  on public.player_boosts(status);
create index if not exists player_boosts_expires_idx on public.player_boosts(expires_at);

-- ---------- RLS ------------------------------------------------------
alter table public.boost_definitions enable row level security;
alter table public.player_boosts     enable row level security;

drop policy if exists "boosts world read" on public.boost_definitions;
create policy "boosts world read" on public.boost_definitions
  for select using (true);

-- Owners can read their own boosts only. ALL mutations go via RPC.
drop policy if exists "pboost self select" on public.player_boosts;
create policy "pboost self select" on public.player_boosts
  for select using (auth.uid() = user_id);

-- ---------- seed catalogue ------------------------------------------
insert into public.boost_definitions (key, name, type, multiplier, duration_seconds, price_coins, price_dna, description)
values
  ('mass_boost_2x_30m', '2x Mass Boost',  'mass', 2, 1800,    300, 0,  'Start every match with double mass for 30 minutes.'),
  ('mass_boost_2x_2h',  '2x Mass Boost',  'mass', 2, 7200,    800, 0,  'Start every match with double mass for 2 hours.'),
  ('mass_boost_3x_1h',  '3x Mass Boost',  'mass', 3, 3600,      0, 35, 'Start every match with triple mass for 1 hour.'),
  ('mass_boost_3x_24h', '3x Mass Boost',  'mass', 3, 86400,     0, 99, 'Start every match with triple mass for 24 hours.'),
  ('xp_boost_2x_30m',   '2x XP Boost',    'xp',   2, 1800,    250, 0,  'Earn double XP for 30 minutes.'),
  ('xp_boost_2x_2h',    '2x XP Boost',    'xp',   2, 7200,    700, 0,  'Earn double XP for 2 hours.'),
  ('xp_boost_3x_1h',    '3x XP Boost',    'xp',   3, 3600,      0, 30, 'Earn triple XP for 1 hour.'),
  ('xp_boost_3x_24h',   '3x XP Boost',    'xp',   3, 86400,     0, 90, 'Earn triple XP for 24 hours.')
on conflict (key) do update
  set name = excluded.name,
      type = excluded.type,
      multiplier = excluded.multiplier,
      duration_seconds = excluded.duration_seconds,
      price_coins = excluded.price_coins,
      price_dna = excluded.price_dna,
      description = excluded.description;

-- ---------- buy_boost ------------------------------------------------
create or replace function public.buy_boost(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user    uuid := auth.uid();
  v_boost   boost_definitions%rowtype;
  v_profile profiles%rowtype;
  v_new_id  uuid;
  v_new_coins int;
  v_new_dna   int;
begin
  if v_user is null then raise exception 'Not authenticated'; end if;

  select * into v_boost from public.boost_definitions where key = p_key;
  if not found then raise exception 'Boost not found: %', p_key; end if;

  select * into v_profile from public.profiles where id = v_user for update;
  if not found then raise exception 'Profile missing'; end if;

  if v_boost.price_coins > 0 and v_profile.coins < v_boost.price_coins then
    raise exception 'Not enough Coins';
  end if;
  if v_boost.price_dna > 0 and v_profile.dna < v_boost.price_dna then
    raise exception 'Not enough DNA';
  end if;

  v_new_coins := v_profile.coins - v_boost.price_coins;
  v_new_dna   := v_profile.dna   - v_boost.price_dna;

  update public.profiles
     set coins      = v_new_coins,
         dna        = v_new_dna,
         updated_at = now()
   where id = v_user;

  insert into public.player_boosts (user_id, boost_id, status)
       values (v_user, v_boost.id, 'owned')
       returning id into v_new_id;

  return jsonb_build_object(
    'player_boost_id', v_new_id,
    'boost_key',       v_boost.key,
    'coins',           v_new_coins,
    'dna',             v_new_dna
  );
end;
$$;
grant execute on function public.buy_boost(text) to authenticated;

-- ---------- activate_boost ------------------------------------------
create or replace function public.activate_boost(p_player_boost_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user      uuid := auth.uid();
  v_pb        player_boosts%rowtype;
  v_def       boost_definitions%rowtype;
  v_active_n  int;
  v_expires   timestamptz;
begin
  if v_user is null then raise exception 'Not authenticated'; end if;

  -- Auto-expire any stale rows so the same-type check is accurate.
  update public.player_boosts
     set status = 'expired'
   where user_id = v_user
     and status = 'active'
     and expires_at <= now();

  select * into v_pb
    from public.player_boosts
   where id = p_player_boost_id and user_id = v_user
   for update;
  if not found then raise exception 'Boost not found'; end if;
  if v_pb.status <> 'owned' then
    raise exception 'Boost is not available to activate';
  end if;

  select * into v_def from public.boost_definitions where id = v_pb.boost_id;

  -- Disallow stacking: one active boost per type.
  select count(*) into v_active_n
    from public.player_boosts pb
    join public.boost_definitions bd on bd.id = pb.boost_id
   where pb.user_id = v_user
     and bd.type    = v_def.type
     and pb.status  = 'active'
     and pb.expires_at > now();
  if v_active_n > 0 then
    raise exception 'A % boost is already active', v_def.type;
  end if;

  v_expires := now() + make_interval(secs => v_def.duration_seconds);

  update public.player_boosts
     set status       = 'active',
         activated_at = now(),
         expires_at   = v_expires
   where id = p_player_boost_id;

  return jsonb_build_object(
    'id',           p_player_boost_id,
    'type',         v_def.type,
    'multiplier',   v_def.multiplier,
    'expires_at',   v_expires,
    'key',          v_def.key,
    'name',         v_def.name
  );
end;
$$;
grant execute on function public.activate_boost(uuid) to authenticated;

-- ---------- get_active_boosts ---------------------------------------
create or replace function public.get_active_boosts()
returns table (
  id                uuid,
  boost_id          uuid,
  status            text,
  activated_at      timestamptz,
  expires_at        timestamptz,
  key               text,
  name              text,
  type              text,
  multiplier        numeric,
  duration_seconds  int
)
language plpgsql
security definer
set search_path = public
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then return; end if;

  -- Auto-expire stale rows on every read.
  update public.player_boosts
     set status = 'expired'
   where user_id = v_user
     and status = 'active'
     and expires_at <= now();

  return query
    select pb.id, pb.boost_id, pb.status, pb.activated_at, pb.expires_at,
           bd.key, bd.name, bd.type, bd.multiplier, bd.duration_seconds
      from public.player_boosts pb
      join public.boost_definitions bd on bd.id = pb.boost_id
     where pb.user_id = v_user
       and pb.status  = 'active'
       and pb.expires_at > now()
     order by pb.expires_at;
end;
$$;
grant execute on function public.get_active_boosts() to authenticated;

-- =====================================================================
-- 6. BOOSTS  ·  v2: quantity-based inventory + separate active table
-- =====================================================================
-- The v1 player_boosts table (row-per-purchase) is left intact for
-- backwards compatibility, but the app now uses these two tables instead.
-- All writes still go through SECURITY DEFINER RPCs.

create table if not exists public.player_boost_inventory (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  boost_id   uuid not null references public.boost_definitions(id) on delete cascade,
  quantity   int  not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now(),
  unique (user_id, boost_id)
);
create index if not exists pbi_user_idx on public.player_boost_inventory(user_id);

create table if not exists public.player_active_boosts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  boost_id     uuid not null references public.boost_definitions(id) on delete cascade,
  type         text not null check (type in ('mass', 'xp')),
  multiplier   numeric not null,
  activated_at timestamptz not null default now(),
  expires_at   timestamptz not null,
  created_at   timestamptz not null default now()
);
create index if not exists pab_user_type_idx on public.player_active_boosts(user_id, type);
create index if not exists pab_expires_idx   on public.player_active_boosts(expires_at);

alter table public.player_boost_inventory enable row level security;
alter table public.player_active_boosts   enable row level security;

drop policy if exists "pbi self read" on public.player_boost_inventory;
create policy "pbi self read" on public.player_boost_inventory
  for select using (auth.uid() = user_id);

drop policy if exists "pab self read" on public.player_active_boosts;
create policy "pab self read" on public.player_active_boosts
  for select using (auth.uid() = user_id);

-- Replace the v1 functions (they were signed for old shapes).
drop function if exists public.buy_boost(text);
drop function if exists public.activate_boost(uuid);
drop function if exists public.get_active_boosts();

-- ---------- buy_boost  (v2: quantity-based) -------------------------
create or replace function public.buy_boost(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user    uuid := auth.uid();
  v_boost   boost_definitions%rowtype;
  v_profile profiles%rowtype;
  v_new_qty int;
begin
  if v_user is null then raise exception 'Not authenticated'; end if;

  select * into v_boost from public.boost_definitions where key = p_key;
  if not found then raise exception 'Boost not found: %', p_key; end if;

  select * into v_profile from public.profiles where id = v_user for update;
  if not found then raise exception 'Profile missing'; end if;

  if v_boost.price_coins > 0 and v_profile.coins < v_boost.price_coins then
    raise exception 'Not enough Coins';
  end if;
  if v_boost.price_dna > 0 and v_profile.dna < v_boost.price_dna then
    raise exception 'Not enough DNA';
  end if;

  update public.profiles
     set coins      = v_profile.coins - v_boost.price_coins,
         dna        = v_profile.dna   - v_boost.price_dna,
         updated_at = now()
   where id = v_user;

  insert into public.player_boost_inventory (user_id, boost_id, quantity)
       values (v_user, v_boost.id, 1)
  on conflict (user_id, boost_id) do update
       set quantity   = public.player_boost_inventory.quantity + 1,
           updated_at = now()
       returning quantity into v_new_qty;

  return jsonb_build_object(
    'boost_key', v_boost.key,
    'quantity',  v_new_qty,
    'coins',     v_profile.coins - v_boost.price_coins,
    'dna',       v_profile.dna   - v_boost.price_dna
  );
end;
$$;
grant execute on function public.buy_boost(text) to authenticated;

-- ---------- activate_boost  (v2: by key, decrements inventory) ------
create or replace function public.activate_boost(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user      uuid := auth.uid();
  v_boost     boost_definitions%rowtype;
  v_inventory player_boost_inventory%rowtype;
  v_expires   timestamptz;
begin
  if v_user is null then raise exception 'Not authenticated'; end if;

  delete from public.player_active_boosts
   where user_id = v_user and expires_at <= now();

  select * into v_boost from public.boost_definitions where key = p_key;
  if not found then raise exception 'Boost not found'; end if;

  select * into v_inventory from public.player_boost_inventory
   where user_id = v_user and boost_id = v_boost.id
   for update;
  if not found or v_inventory.quantity < 1 then
    raise exception 'You don''t own this boost';
  end if;

  if exists (
    select 1 from public.player_active_boosts
     where user_id = v_user and type = v_boost.type and expires_at > now()
  ) then
    raise exception 'You already have an active % Boost', upper(v_boost.type);
  end if;

  v_expires := now() + make_interval(secs => v_boost.duration_seconds);

  update public.player_boost_inventory
     set quantity   = quantity - 1,
         updated_at = now()
   where user_id = v_user and boost_id = v_boost.id;

  insert into public.player_active_boosts
       (user_id, boost_id, type, multiplier, expires_at)
  values (v_user, v_boost.id, v_boost.type, v_boost.multiplier, v_expires);

  return jsonb_build_object(
    'boost_key',  v_boost.key,
    'type',       v_boost.type,
    'multiplier', v_boost.multiplier,
    'expires_at', v_expires,
    'quantity',   v_inventory.quantity - 1
  );
end;
$$;
grant execute on function public.activate_boost(text) to authenticated;

-- ---------- get_boost_inventory  -----------------------------------
create or replace function public.get_boost_inventory()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user   uuid := auth.uid();
  v_items  jsonb;
begin
  if v_user is null then return '[]'::jsonb; end if;

  delete from public.player_active_boosts
   where user_id = v_user and expires_at <= now();

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',               bd.id,
    'key',              bd.key,
    'name',             bd.name,
    'type',             bd.type,
    'multiplier',       bd.multiplier,
    'duration_seconds', bd.duration_seconds,
    'price_coins',      bd.price_coins,
    'price_dna',        bd.price_dna,
    'description',      bd.description,
    'quantity',         coalesce(pbi.quantity, 0),
    'active_expires_at', (
      select pab.expires_at
        from public.player_active_boosts pab
       where pab.user_id = v_user
         and pab.boost_id = bd.id
         and pab.expires_at > now()
       limit 1
    )
  ) order by bd.type, bd.price_coins, bd.price_dna), '[]'::jsonb)
    into v_items
    from public.boost_definitions bd
    left join public.player_boost_inventory pbi
      on pbi.user_id = v_user and pbi.boost_id = bd.id;

  return v_items;
end;
$$;
grant execute on function public.get_boost_inventory() to authenticated;

-- ---------- get_match_start_modifiers  -----------------------------
create or replace function public.get_match_start_modifiers()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_mass numeric := 1.0;
  v_xp   numeric := 1.0;
  v_mass_exp timestamptz;
  v_xp_exp   timestamptz;
begin
  if v_user is null then
    return jsonb_build_object('mass_multiplier', 1.0, 'xp_multiplier', 1.0);
  end if;

  delete from public.player_active_boosts
   where user_id = v_user and expires_at <= now();

  select multiplier, expires_at into v_mass, v_mass_exp
    from public.player_active_boosts
   where user_id = v_user and type = 'mass' and expires_at > now()
   order by expires_at desc limit 1;

  select multiplier, expires_at into v_xp, v_xp_exp
    from public.player_active_boosts
   where user_id = v_user and type = 'xp' and expires_at > now()
   order by expires_at desc limit 1;

  return jsonb_build_object(
    'mass_multiplier', coalesce(v_mass, 1.0),
    'xp_multiplier',   coalesce(v_xp,   1.0),
    'mass_expires_at', v_mass_exp,
    'xp_expires_at',   v_xp_exp
  );
end;
$$;
grant execute on function public.get_match_start_modifiers() to authenticated;

-- =====================================================================
-- 7. SKINS  ·  catalogue + per-player ownership + equipped slot
-- =====================================================================

create table if not exists public.skin_definitions (
  id           uuid primary key default gen_random_uuid(),
  key          text unique not null,
  name         text not null,
  category     text not null check (category in ('level', 'premium', 'free')),
  image_path   text not null,
  unlock_level int default 0,
  price_coins  int default 0,
  sort_order   int default 0,
  created_at   timestamptz not null default now()
);
create index if not exists skin_def_cat_sort_idx
  on public.skin_definitions(category, sort_order);

create table if not exists public.player_skins (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  skin_id     uuid not null references public.skin_definitions(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  source      text not null check (source in ('level', 'premium', 'default', 'free')),
  unique (user_id, skin_id)
);
create index if not exists ps_user_idx on public.player_skins(user_id);

create table if not exists public.player_equipped_skin (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  skin_id    uuid references public.skin_definitions(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.skin_definitions     enable row level security;
alter table public.player_skins         enable row level security;
alter table public.player_equipped_skin enable row level security;

drop policy if exists "skindef world read" on public.skin_definitions;
create policy "skindef world read" on public.skin_definitions
  for select using (true);

drop policy if exists "ps self read" on public.player_skins;
create policy "ps self read" on public.player_skins
  for select using (auth.uid() = user_id);

drop policy if exists "pes self read" on public.player_equipped_skin;
create policy "pes self read" on public.player_equipped_skin
  for select using (auth.uid() = user_id);

-- ---------- sync_skin_catalogue  -----------------------------------
-- Idempotent upsert. The client calls this on startup with the manifest
-- it discovered from rootBundle so the server-side catalogue mirrors
-- what's actually on disk. The client passes pre-computed unlock_level
-- and price_coins per the spec rules (5-step for level skins, 50-9999
-- ascending for premium).
create or replace function public.sync_skin_catalogue(p_items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
begin
  if p_items is null then return; end if;
  for v_item in select jsonb_array_elements(p_items) loop
    insert into public.skin_definitions (
      key, name, category, image_path,
      unlock_level, price_coins, sort_order
    ) values (
      v_item->>'key',
      coalesce(v_item->>'name', v_item->>'key'),
      v_item->>'category',
      v_item->>'image_path',
      coalesce((v_item->>'unlock_level')::int, 0),
      coalesce((v_item->>'price_coins')::int, 0),
      coalesce((v_item->>'sort_order')::int, 0)
    )
    on conflict (key) do update
      set name         = excluded.name,
          category     = excluded.category,
          image_path   = excluded.image_path,
          unlock_level = excluded.unlock_level,
          price_coins  = excluded.price_coins,
          sort_order   = excluded.sort_order;
  end loop;
end;
$$;
grant execute on function public.sync_skin_catalogue(jsonb) to authenticated;

-- ---------- unlock_level_skins_for_user  ---------------------------
-- Auto-grants level skins whose unlock_level <= profile.level and that
-- aren't already owned. Returns the newly-unlocked skins for popup use.
create or replace function public.unlock_level_skins_for_user(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_level    int;
  v_unlocked jsonb;
begin
  -- Only the user themselves (or trusted server context) may call this.
  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'Forbidden';
  end if;

  select level into v_level from public.profiles where id = p_user_id;
  if v_level is null then return '[]'::jsonb; end if;

  with newly as (
    insert into public.player_skins (user_id, skin_id, source)
    select p_user_id, sd.id, 'level'
      from public.skin_definitions sd
     where sd.category = 'level'
       and sd.unlock_level > 0
       and sd.unlock_level <= v_level
       and not exists (
         select 1 from public.player_skins ps
          where ps.user_id = p_user_id and ps.skin_id = sd.id
       )
    on conflict (user_id, skin_id) do nothing
    returning skin_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'key',          sd.key,
    'name',         sd.name,
    'image_path',   sd.image_path,
    'unlock_level', sd.unlock_level
  )), '[]'::jsonb) into v_unlocked
    from newly
    join public.skin_definitions sd on sd.id = newly.skin_id;

  return v_unlocked;
end;
$$;
grant execute on function public.unlock_level_skins_for_user(uuid) to authenticated;

create or replace function public.claim_level_skins()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.unlock_level_skins_for_user(auth.uid());
end;
$$;
grant execute on function public.claim_level_skins() to authenticated;

-- ---------- get_player_skins  --------------------------------------
create or replace function public.get_player_skins()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user         uuid := auth.uid();
  v_equipped_key text;
  v_skins        jsonb;
begin
  if v_user is null then
    return jsonb_build_object('skins', '[]'::jsonb, 'equipped_key', null);
  end if;

  select sd.key into v_equipped_key
    from public.player_equipped_skin pes
    join public.skin_definitions sd on sd.id = pes.skin_id
   where pes.user_id = v_user;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',           sd.id,
    'key',          sd.key,
    'name',         sd.name,
    'category',     sd.category,
    'image_path',   sd.image_path,
    'unlock_level', sd.unlock_level,
    'price_coins',  sd.price_coins,
    'sort_order',   sd.sort_order,
    'owned',        (ps.id is not null) or sd.category = 'free',
    'source',       ps.source,
    'equipped',     sd.key = v_equipped_key
  ) order by sd.category, sd.sort_order), '[]'::jsonb)
    into v_skins
    from public.skin_definitions sd
    left join public.player_skins ps
      on ps.user_id = v_user and ps.skin_id = sd.id;

  return jsonb_build_object(
    'skins',        v_skins,
    'equipped_key', v_equipped_key
  );
end;
$$;
grant execute on function public.get_player_skins() to authenticated;

-- ---------- buy_premium_skin  --------------------------------------
create or replace function public.buy_premium_skin(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user    uuid := auth.uid();
  v_skin    skin_definitions%rowtype;
  v_profile profiles%rowtype;
begin
  if v_user is null then raise exception 'Not authenticated'; end if;

  select * into v_skin from public.skin_definitions where key = p_key;
  if not found then raise exception 'Skin not found'; end if;
  if v_skin.category <> 'premium' then
    raise exception 'Not a premium skin';
  end if;

  if exists (select 1 from public.player_skins
              where user_id = v_user and skin_id = v_skin.id) then
    raise exception 'Already owned';
  end if;

  select * into v_profile from public.profiles where id = v_user for update;
  if v_profile.coins < v_skin.price_coins then
    raise exception 'Not enough Coins';
  end if;

  update public.profiles
     set coins      = coins - v_skin.price_coins,
         updated_at = now()
   where id = v_user;

  insert into public.player_skins (user_id, skin_id, source)
       values (v_user, v_skin.id, 'premium');

  return jsonb_build_object(
    'skin_key', v_skin.key,
    'coins',    v_profile.coins - v_skin.price_coins
  );
end;
$$;
grant execute on function public.buy_premium_skin(text) to authenticated;

-- ---------- equip_skin  --------------------------------------------
create or replace function public.equip_skin(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user  uuid := auth.uid();
  v_skin  skin_definitions%rowtype;
  v_owned boolean;
begin
  if v_user is null then raise exception 'Not authenticated'; end if;
  select * into v_skin from public.skin_definitions where key = p_key;
  if not found then raise exception 'Skin not found'; end if;

  -- Free skins are owned by everyone, level/premium need a player_skins row.
  v_owned := v_skin.category = 'free'
          or exists (select 1 from public.player_skins
                      where user_id = v_user and skin_id = v_skin.id);
  if not v_owned then raise exception 'You don''t own this skin'; end if;

  insert into public.player_equipped_skin (user_id, skin_id, updated_at)
       values (v_user, v_skin.id, now())
  on conflict (user_id) do update
       set skin_id = excluded.skin_id, updated_at = now();

  return jsonb_build_object('skin_key', v_skin.key);
end;
$$;
grant execute on function public.equip_skin(text) to authenticated;

-- =====================================================================
-- 8. submit_match_result  ·  v3: XP boost from new table + skin unlock
-- =====================================================================

create or replace function public.submit_match_result(
  p_score            int,
  p_mass_collected   int,
  p_kills            int,
  p_survival_seconds int,
  p_rank             int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user        uuid := auth.uid();
  v_score       int  := greatest(coalesce(p_score, 0), 0);
  v_mass        int  := greatest(coalesce(p_mass_collected, 0), 0);
  v_kills       int  := greatest(coalesce(p_kills, 0), 0);
  v_survival    int  := greatest(coalesce(p_survival_seconds, 0), 0);
  v_rank        int  := greatest(coalesce(p_rank, 9999), 1);

  v_coins_earned int;
  v_dna_earned   int;
  v_xp_earned    int;
  v_xp_mult      numeric := 1.0;

  v_prev_level   int;
  v_prev_xp      int;
  v_new_xp       int;
  v_new_level    int;
  v_required     int;
  v_leveled_up   boolean := false;
  v_levels_gained int := 0;
  v_level_up_coins int := 0;
  v_level_up_dna   int := 0;

  v_profile      profiles%rowtype;
  v_coins_total  int;
  v_dna_total    int;
  v_unlocked_skins jsonb := '[]'::jsonb;
begin
  if v_user is null then
    raise exception 'Not authenticated';
  end if;

  -- Coins and DNA are ONLY earned through leveling up (not per-match).
  v_coins_earned := 0;
  v_dna_earned   := 0;
  v_xp_earned    := (v_score / 3)
                    + (v_kills * 12)
                    + (v_survival / 2)
                    + greatest(0, 50 - v_rank) * 4;

  v_xp_earned    := greatest(v_xp_earned, 1);

  -- Server-side XP boost lookup (v2 active table).
  delete from public.player_active_boosts
   where user_id = v_user and expires_at <= now();

  select coalesce(max(multiplier), 1.0) into v_xp_mult
    from public.player_active_boosts
   where user_id = v_user and type = 'xp' and expires_at > now();

  v_xp_earned := floor(v_xp_earned * v_xp_mult)::int;

  insert into public.profiles (id, email, coins, dna)
  values (v_user, (select email from auth.users where id = v_user), 200, 50)
  on conflict (id) do nothing;

  select * into v_profile from public.profiles where id = v_user for update;
  v_prev_level := coalesce(v_profile.level, 1);
  v_prev_xp    := coalesce(v_profile.xp, 0);

  v_new_xp    := v_prev_xp + v_xp_earned;
  v_new_level := v_prev_level;

  loop
    v_required := 100 * v_new_level * v_new_level;
    exit when v_new_xp < v_required;
    v_new_xp        := v_new_xp - v_required;
    v_new_level     := v_new_level + 1;
    v_levels_gained := v_levels_gained + 1;
    v_leveled_up    := true;
    v_level_up_coins := v_level_up_coins + 100;
    v_level_up_dna   := v_level_up_dna   + 20;
  end loop;

  v_coins_total := coalesce(v_profile.coins, 0) + v_coins_earned + v_level_up_coins;
  v_dna_total   := coalesce(v_profile.dna,   0) + v_dna_earned   + v_level_up_dna;

  update public.profiles
     set level      = v_new_level,
         xp         = v_new_xp,
         coins      = v_coins_total,
         dna        = v_dna_total,
         updated_at = now()
   where id = v_user;

  insert into public.player_stats (user_id) values (v_user)
  on conflict (user_id) do nothing;

  update public.player_stats
     set matches_played         = matches_played + 1,
         best_score             = greatest(best_score, v_score),
         total_score            = total_score + v_score,
         total_mass_collected   = total_mass_collected + v_mass,
         total_kills            = total_kills + v_kills,
         total_deaths           = total_deaths + 1,
         total_survival_seconds = total_survival_seconds + v_survival,
         wins                   = wins + case when v_rank = 1 then 1 else 0 end,
         updated_at             = now()
   where user_id = v_user;

  insert into public.match_history (
    user_id, score, mass_collected, kills, survival_seconds, rank,
    coins_earned, dna_earned, xp_earned
  ) values (
    v_user, v_score, v_mass, v_kills, v_survival, v_rank,
    v_coins_earned + v_level_up_coins,
    v_dna_earned   + v_level_up_dna,
    v_xp_earned
  );

  -- Unlock any level skins now reachable.
  v_unlocked_skins := public.unlock_level_skins_for_user(v_user);

  return jsonb_build_object(
    'level',                  v_new_level,
    'xp',                     v_new_xp,
    'coins',                  v_coins_total,
    'dna',                    v_dna_total,
    'coins_earned',           v_coins_earned,
    'dna_earned',             v_dna_earned,
    'xp_earned',              v_xp_earned,
    'xp_multiplier',          v_xp_mult,
    'level_up_coins_earned',  v_level_up_coins,
    'level_up_dna_earned',    v_level_up_dna,
    'levels_gained',          v_levels_gained,
    'leveled_up',             v_leveled_up,
    'newly_unlocked_skins',   v_unlocked_skins
  );
end;
$$;
grant execute on function public.submit_match_result(int, int, int, int, int)
  to authenticated;

-- =====================================================================
--  DONE. Test login from the app, play a match, hit "PLAY AGAIN" to
--  watch coins/DNA/XP grow in the profile screen.
-- =====================================================================
