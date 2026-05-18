/**
 * Yazario Online Classic — authoritative WebSocket game server.
 *
 * One global world, one room. Clients send `join` / `input` / `split` / `ping`,
 * server simulates physics + bots + collisions and broadcasts spatially
 * filtered snapshots at TICK_RATE Hz.
 *
 * No external state, no DB. Self-contained.
 *
 * Run: `npm i && npm run build && npm start`
 */
import { createServer } from "http";
import { WebSocketServer, WebSocket } from "ws";

// ────────────────────────────────────────────────────────── world constants
const PORT = Number(process.env.PORT ?? 2567);
const MAP_W = 8000;
const MAP_H = 8000;
const TICK_RATE = 30; // Hz — matched to the client's 30 Hz input pump.
const TICK_MS = 1000 / TICK_RATE;

const PELLET_TARGET = 900;
const VIRUS_TARGET = 15;
const BOT_TARGET = 25; // baseline; scaled down as humans join
const MAX_BOTS = 30;

const START_MASS = 30;
const MAX_MASS = 22500;
const DECAY_THRESHOLD = 35;
const DECAY_PER_SEC = 0.002; // 0.2 %/s above threshold
const EAT_RATIO = 1.25; // eater must be 25 % bigger

const SPLIT_MIN_MASS = 35;
const SPLIT_COOLDOWN_MS = 800;
const SPLIT_DASH_VELOCITY = 900;
const SPLIT_DASH_DECAY = 0.91; // per 1/60 s frame
const SPLIT_MASS_COST = 0.5; // half mass lost on split — kept name for clarity
const MAX_CELLS_PER_PLAYER = 16; // mirrors GameConstants.maxCellsPerPlayer
const SPLIT_MERGE_WINDOW_MS = 12000; // 12 s before fragments can re-merge

const VIRUS_MASS = 100;
const VIRUS_DAMAGE_MASS_LOSS = 0.4; // 40 % mass loss + small dash
const VIRUS_BOUNCE_VELOCITY = 700;

// ── Eject (feed) ─────────────────────────────────────────────────────────
const EJECT_MIN_MASS = 35;       // source cell needs at least this much
const EJECT_COST = 13;           // mass removed from source cell
const EJECT_MASS = 13;           // mass of the spawned projectile
const EJECT_VELOCITY = 1100;     // launch speed (u/s)
const EJECT_FRICTION_PER_S = 4;  // exponential decay rate (per second)
const EJECT_MIN_SPEED = 30;      // when speed drops below this, it parks
const EJECT_LIFETIME_MS = 30000; // server-side TTL for unclaimed feeds
const EJECT_COOLDOWN_MS = 60;    // per-press, prevents accidental double-fires

// ── Speed model: mirrors Offline Classic.
// Classic uses an impulse+damping model whose terminal velocity is
//   inputMoveStrength / dampingPerSecond = 1200 / 5.8 ≈ 207 u/s
// and a per-radius cap maxSpeedForRadius(r) clamped to [95, 360].
// We collapse that to a direct-velocity model:
//   v = input * min(CLASSIC_TERMINAL, maxSpeedForRadius(r))
// which gives the same steady-state feel without needing to simulate damping.
const CLASSIC_TERMINAL = 207;            // 1200 / 5.8
const SPEED_SCALE_BASE = 260;
const SPEED_REFERENCE_RADIUS = 35;
const SPEED_RADIUS_POWER = 0.42;
const MAX_SMALL_CELL_SPEED = 360;
const MAX_LARGE_CELL_SPEED = 95;

const SNAPSHOT_RADIUS = 1800; // how far around each viewer we send entities
const LEADERBOARD_SIZE = 10;

// Pool of skin ids assigned to bots. Clients map any string skinId →
// a deterministic image from their local SkinRegistry, so the actual
// values just need to be stable & varied.
const BOT_SKINS: string[] = [
  "bot_a", "bot_b", "bot_c", "bot_d", "bot_e",
  "bot_f", "bot_g", "bot_h", "bot_i", "bot_j",
  "bot_k", "bot_l", "bot_m", "bot_n", "bot_o",
];

const PALETTE = [
  "#FF1F2D", "#1E9BFF", "#34C924", "#FFD60A",
  "#FF6A00", "#A63CFF", "#00C8E0", "#FF2D87",
];

const BOT_NAMES = [
  "Doge", "Ninja", "Cookie", "Slayer42", "Mario", "Sonic", "Yoshi", "Kirby",
  "Reaper", "Phantom", "Bandit", "Viper", "Hawk", "Pixel", "Wraith", "Pumba",
  "Bender", "Sponge", "Zelda", "Samus", "Ezio", "Solid", "Master", "Sneaky",
];

// ────────────────────────────────────────────────────────── types
type Color = string;

interface InputState {
  dx: number;
  dy: number;
}

interface Entity {
  id: string;
  x: number;
  y: number;
  mass: number;
  color: Color;
}

interface Cell extends Entity {
  vx: number; // base velocity (from input)
  vy: number;
  dashVx: number; // split-dash velocity (decays fast)
  dashVy: number;
  ownerId: string;
  freshSplitUntil: number; // ms timestamp: can't merge yet
}

interface Player {
  id: string;
  socket: WebSocket | null; // null for bots
  isBot: boolean;
  name: string;
  color: Color;
  skinId: string; // opaque string; clients map to a local image
  cells: Cell[];
  input: InputState;
  dead: boolean;
  deadUntil: number; // ms timestamp; bots only
  lastSplitAt: number;
  lastEjectAt: number;
  spawnTime: number;
  highestMass: number;
  lastSeenAt: number; // ms
  // bot AI scratch
  botTarget?: { x: number; y: number };
  nextDecideAt: number;
}

interface Pellet extends Entity {}
interface Virus extends Entity {}

interface EjectedMass extends Entity {
  vx: number;
  vy: number;
  expiresAt: number;
  ownerId: string; // so the source cell can't eat its own feed instantly
}

// ────────────────────────────────────────────────────────── world state
const players = new Map<string, Player>();
const pellets: Pellet[] = [];
const viruses: Virus[] = [];
const ejected: EjectedMass[] = [];
let entitySeq = 0;

const newId = (prefix: string) => `${prefix}_${++entitySeq}`;

function rand(min: number, max: number): number {
  return min + Math.random() * (max - min);
}
function pickColor(): Color {
  return PALETTE[Math.floor(Math.random() * PALETTE.length)];
}
function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}
function radius(mass: number): number {
  return Math.sqrt(mass / Math.PI) * 10;
}
function dist(ax: number, ay: number, bx: number, by: number): number {
  const dx = ax - bx, dy = ay - by;
  return Math.sqrt(dx * dx + dy * dy);
}

// ────────────────────────────────────────────────────────── spawning
function safeSpawnPosition(margin = 500): { x: number; y: number } {
  for (let attempt = 0; attempt < 30; attempt++) {
    const x = rand(margin, MAP_W - margin);
    const y = rand(margin, MAP_H - margin);
    let ok = true;
    for (const p of players.values()) {
      if (p.dead) continue;
      for (const c of p.cells) {
        if (dist(c.x, c.y, x, y) < 600) {
          ok = false;
          break;
        }
      }
      if (!ok) break;
    }
    for (const v of viruses) {
      if (dist(v.x, v.y, x, y) < 200) {
        ok = false;
        break;
      }
    }
    if (ok) return { x, y };
  }
  return { x: rand(margin, MAP_W - margin), y: rand(margin, MAP_H - margin) };
}

function spawnPellet(): Pellet {
  return {
    id: newId("p"),
    x: rand(20, MAP_W - 20),
    y: rand(20, MAP_H - 20),
    mass: 1,
    color: pickColor(),
  };
}
function spawnVirus(): Virus {
  return {
    id: newId("v"),
    x: rand(200, MAP_W - 200),
    y: rand(200, MAP_H - 200),
    mass: VIRUS_MASS,
    color: "#33FF33",
  };
}

function spawnCellForPlayer(p: Player, mass: number = START_MASS): void {
  const pos = safeSpawnPosition();
  p.cells = [{
    id: newId("c"),
    ownerId: p.id,
    x: pos.x,
    y: pos.y,
    mass,
    vx: 0,
    vy: 0,
    dashVx: 0,
    dashVy: 0,
    color: p.color,
    freshSplitUntil: 0,
  }];
  p.dead = false;
  p.spawnTime = Date.now();
  p.highestMass = mass;
  p.input = { dx: 0, dy: 0 };
}

function makeBot(): Player {
  const id = newId("bot");
  const bot: Player = {
    id,
    socket: null,
    isBot: true,
    name: BOT_NAMES[Math.floor(Math.random() * BOT_NAMES.length)],
    color: pickColor(),
    skinId: BOT_SKINS[Math.floor(Math.random() * BOT_SKINS.length)],
    cells: [],
    input: { dx: 0, dy: 0 },
    dead: false,
    deadUntil: 0,
    lastSplitAt: 0,
    lastEjectAt: 0,
    spawnTime: Date.now(),
    highestMass: START_MASS,
    lastSeenAt: Date.now(),
    nextDecideAt: 0,
  };
  spawnCellForPlayer(bot);
  return bot;
}

// initialise world
for (let i = 0; i < PELLET_TARGET; i++) pellets.push(spawnPellet());
for (let i = 0; i < VIRUS_TARGET; i++) viruses.push(spawnVirus());
for (let i = 0; i < BOT_TARGET; i++) {
  const b = makeBot();
  players.set(b.id, b);
}

// ────────────────────────────────────────────────────────── bot AI
function botDecide(b: Player, now: number): void {
  if (b.dead) return;
  if (now < b.nextDecideAt) return;
  b.nextDecideAt = now + 250 + Math.random() * 250;

  // Compute center of mass
  let cx = 0, cy = 0, tm = 0;
  for (const c of b.cells) {
    cx += c.x * c.mass;
    cy += c.y * c.mass;
    tm += c.mass;
  }
  if (tm <= 0) return;
  cx /= tm;
  cy /= tm;
  const myMass = tm;

  let threatX = 0, threatY = 0, threatStrength = 0;
  let preyX = cx, preyY = cy, preyDist = Infinity;

  for (const other of players.values()) {
    if (other.id === b.id || other.dead) continue;
    for (const oc of other.cells) {
      const d = dist(cx, cy, oc.x, oc.y);
      if (d > 900) continue;
      if (oc.mass > myMass * EAT_RATIO) {
        // threat: stronger when closer
        const w = 1 - d / 900;
        threatX += (cx - oc.x) * w;
        threatY += (cy - oc.y) * w;
        threatStrength += w;
      } else if (myMass > oc.mass * EAT_RATIO && d < preyDist) {
        preyX = oc.x;
        preyY = oc.y;
        preyDist = d;
      }
    }
  }

  // Virus avoidance: only matters for big bots
  if (myMass > 130) {
    for (const v of viruses) {
      const d = dist(cx, cy, v.x, v.y);
      if (d < 260) {
        const w = 1 - d / 260;
        threatX += (cx - v.x) * w;
        threatY += (cy - v.y) * w;
        threatStrength += w * 0.7;
      }
    }
  }

  let tx: number, ty: number;
  if (threatStrength > 0.3) {
    tx = cx + threatX;
    ty = cy + threatY;
  } else if (isFinite(preyDist)) {
    tx = preyX;
    ty = preyY;
  } else {
    // Find closest pellet
    let bd = Infinity;
    let bp: Pellet | null = null;
    for (const pe of pellets) {
      const d = dist(cx, cy, pe.x, pe.y);
      if (d < bd) {
        bd = d;
        bp = pe;
      }
      if (bd < 50) break;
    }
    if (bp) {
      tx = bp.x;
      ty = bp.y;
    } else {
      tx = cx + rand(-300, 300);
      ty = cy + rand(-300, 300);
    }
  }

  // Steer away from world edges
  const margin = 350;
  if (cx < margin) tx += 400;
  if (cx > MAP_W - margin) tx -= 400;
  if (cy < margin) ty += 400;
  if (cy > MAP_H - margin) ty -= 400;

  const dx = tx - cx, dy = ty - cy;
  const m = Math.hypot(dx, dy);
  if (m > 0.5) {
    b.input.dx = clamp(dx / m, -1, 1);
    b.input.dy = clamp(dy / m, -1, 1);
  } else {
    b.input.dx = 0;
    b.input.dy = 0;
  }
}

// ────────────────────────────────────────────────────────── simulation
// Mirrors GameConstants.maxSpeedForRadius from the offline engine.
function maxSpeedForRadius(r: number): number {
  const s =
    SPEED_SCALE_BASE *
    Math.pow(SPEED_REFERENCE_RADIUS / (r < 1 ? 1 : r), SPEED_RADIUS_POWER);
  return clamp(s, MAX_LARGE_CELL_SPEED, MAX_SMALL_CELL_SPEED);
}

// Direct steady-state speed for a cell of given radius. Bots & humans
// use the same curve — same as Offline Classic.
function speedForRadius(r: number): number {
  return Math.min(CLASSIC_TERMINAL, maxSpeedForRadius(r));
}

function applyMovement(p: Player, dt: number): void {
  const idx = clamp(p.input.dx, -1, 1);
  const idy = clamp(p.input.dy, -1, 1);
  const im = Math.hypot(idx, idy) || 1;
  const ux = im > 1 ? idx / im : idx;
  const uy = im > 1 ? idy / im : idy;

  for (const c of p.cells) {
    const r = radius(c.mass);
    const speed = speedForRadius(r);
    const vx = ux * speed;
    const vy = uy * speed;
    c.vx = vx;
    c.vy = vy;

    // Apply velocity + dash and clamp to world.
    c.x += (c.vx + c.dashVx) * dt;
    c.y += (c.vy + c.dashVy) * dt;

    // Dash decays per 60 fps frame, scaled by dt.
    const decay = Math.pow(SPLIT_DASH_DECAY, dt * 60);
    c.dashVx *= decay;
    c.dashVy *= decay;
    if (Math.abs(c.dashVx) < 1) c.dashVx = 0;
    if (Math.abs(c.dashVy) < 1) c.dashVy = 0;

    const rClamp = radius(c.mass);
    c.x = clamp(c.x, rClamp * 0.75, MAP_W - rClamp * 0.75);
    c.y = clamp(c.y, rClamp * 0.75, MAP_H - rClamp * 0.75);

    // Mass decay
    if (c.mass > DECAY_THRESHOLD) {
      c.mass = Math.max(
        DECAY_THRESHOLD,
        c.mass * Math.pow(1 - DECAY_PER_SEC, dt),
      );
    }
  }
}

function tryEatPellets(p: Player): void {
  for (const c of p.cells) {
    const r = radius(c.mass);
    const r2 = r * r;
    for (let i = pellets.length - 1; i >= 0; i--) {
      const pe = pellets[i];
      const dx = pe.x - c.x, dy = pe.y - c.y;
      if (dx * dx + dy * dy < r2) {
        if (c.mass < MAX_MASS) c.mass += pe.mass;
        // Respawn pellet elsewhere instead of removing — keeps array stable.
        pe.x = rand(20, MAP_W - 20);
        pe.y = rand(20, MAP_H - 20);
        pe.color = pickColor();
      }
    }
  }
}

function resolveCellVsCell(): void {
  // Gather all alive cells
  const all: Cell[] = [];
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const c of p.cells) all.push(c);
  }
  const dead = new Set<Cell>();
  for (let i = 0; i < all.length; i++) {
    const a = all[i];
    if (dead.has(a)) continue;
    const ar = radius(a.mass);
    for (let j = 0; j < all.length; j++) {
      if (i === j) continue;
      const b = all[j];
      if (dead.has(b)) continue;
      if (a.ownerId === b.ownerId) continue; // same-player: never eat
      if (a.mass < b.mass * EAT_RATIO) continue;
      const br = radius(b.mass);
      const dx = b.x - a.x, dy = b.y - a.y;
      const eatR = ar - br * 0.4;
      if (eatR < 0) continue;
      if (dx * dx + dy * dy < eatR * eatR) {
        if (a.mass < MAX_MASS) a.mass = Math.min(MAX_MASS, a.mass + b.mass);
        dead.add(b);
      }
    }
  }
  if (dead.size === 0) return;
  for (const p of players.values()) {
    if (p.cells.length === 0) continue;
    p.cells = p.cells.filter((c) => !dead.has(c));
    if (p.cells.length === 0 && !p.dead) {
      p.dead = true;
      p.deadUntil = Date.now() + 600; // bots respawn after 0.6 s
    }
  }
}

function resolveCellVsVirus(): void {
  const virusesConsumed = new Set<Virus>();
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const c of p.cells) {
      if (radius(c.mass) <= radius(VIRUS_MASS) * 1.15) continue;
      for (const v of viruses) {
        if (virusesConsumed.has(v)) continue;
        const cr = radius(c.mass);
        const vr = radius(v.mass);
        const dx = v.x - c.x, dy = v.y - c.y;
        const trigger = cr + vr * 0.2;
        if (dx * dx + dy * dy < trigger * trigger) {
          // Pop: lose mass, bounce away. Simplified Classic-style hit.
          virusesConsumed.add(v);
          const loss = c.mass * VIRUS_DAMAGE_MASS_LOSS;
          c.mass = Math.max(DECAY_THRESHOLD, c.mass - loss);
          const m = Math.hypot(dx, dy) || 1;
          c.dashVx = -dx / m * VIRUS_BOUNCE_VELOCITY * 0.5;
          c.dashVy = -dy / m * VIRUS_BOUNCE_VELOCITY * 0.5;
          break;
        }
      }
    }
  }
  if (virusesConsumed.size > 0) {
    for (let i = viruses.length - 1; i >= 0; i--) {
      if (virusesConsumed.has(viruses[i])) {
        viruses[i] = spawnVirus();
      }
    }
  }
}

function refillWorld(): void {
  while (pellets.length < PELLET_TARGET) pellets.push(spawnPellet());
  while (viruses.length < VIRUS_TARGET) viruses.push(spawnVirus());

  // Maintain bot count: humans replace bots up to MAX_BOTS budget.
  const humans = [...players.values()].filter((p) => !p.isBot).length;
  const bots = [...players.values()].filter((p) => p.isBot && !p.dead).length;
  const wanted = clamp(BOT_TARGET - humans, 6, MAX_BOTS);
  if (bots < wanted) {
    const b = makeBot();
    players.set(b.id, b);
  }

  // Bot respawn after death timer
  const now = Date.now();
  for (const p of players.values()) {
    if (!p.isBot) continue;
    if (p.dead && now >= p.deadUntil) {
      spawnCellForPlayer(p);
    }
  }
}

// ────────────────────────────────────────────────────────── split
function tryDoSplit(p: Player): void {
  if (p.dead) return;
  const now = Date.now();
  if (now - p.lastSplitAt < SPLIT_COOLDOWN_MS) {
    console.log("split blocked: cooldown");
    return;
  }
  // Pick a dash direction. If the player isn't pressing any input (e.g.
  // tapping split while idle on the joystick), fall back to (1, 0) so the
  // split still fires — same forgiving behaviour as Offline Classic's
  // SplitHandler.splitPlayer.
  let dx = p.input.dx, dy = p.input.dy;
  const m = Math.hypot(dx, dy);
  if (m < 0.05) {
    dx = 1;
    dy = 0;
  } else {
    dx /= m;
    dy /= m;
  }
  // Snapshot the eligible cells *before* we start splitting — otherwise
  // the new cells we push to p.cells would also be considered for further
  // splitting on the same press.
  const candidates = [...p.cells].sort((a, b) => b.mass - a.mass);
  let acted = false;
  let anyEligible = false;
  for (const source of candidates) {
    if (p.cells.length >= MAX_CELLS_PER_PLAYER) break;
    if (source.mass < SPLIT_MIN_MASS) continue;
    anyEligible = true;
    const half = source.mass / 2;
    source.mass = half;
    source.freshSplitUntil = now + SPLIT_MERGE_WINDOW_MS;
    const r = radius(half);
    const baby: Cell = {
      id: newId("c"),
      ownerId: p.id,
      x: clamp(source.x + dx * (r + 4), r * 0.75, MAP_W - r * 0.75),
      y: clamp(source.y + dy * (r + 4), r * 0.75, MAP_H - r * 0.75),
      mass: half,
      vx: 0,
      vy: 0,
      dashVx: dx * SPLIT_DASH_VELOCITY,
      dashVy: dy * SPLIT_DASH_VELOCITY,
      color: source.color,
      freshSplitUntil: now + SPLIT_MERGE_WINDOW_MS,
    };
    p.cells.push(baby);
    acted = true;
  }
  if (acted) {
    p.lastSplitAt = now;
    console.log("[action] split success", { player: p.id, cells: p.cells.length });
  } else if (!anyEligible) {
    console.log("split blocked: mass too low");
  } else {
    console.log("split blocked: cell cap reached");
  }
}

// ────────────────────────────────────────────────────────── eject (feed)
function tryDoEject(p: Player): void {
  if (p.dead) return;
  const now = Date.now();
  if (now - p.lastEjectAt < EJECT_COOLDOWN_MS) {
    console.log("eject blocked: cooldown");
    return;
  }
  // Pick a launch direction. Same fallback as split — (1, 0) when idle.
  let dx = p.input.dx, dy = p.input.dy;
  const m = Math.hypot(dx, dy);
  if (m < 0.05) {
    dx = 1;
    dy = 0;
  } else {
    dx /= m;
    dy /= m;
  }
  let anyFired = false;
  let anyEligible = false;
  for (const c of p.cells) {
    // Match Offline: just need mass >= EJECT_MIN_MASS to feed. Cell can dip
    // below DECAY_THRESHOLD via eject (Offline does the same).
    if (c.mass < EJECT_MIN_MASS) continue;
    anyEligible = true;
    c.mass -= EJECT_COST;
    const r = radius(c.mass < 1 ? 1 : c.mass);
    // Spawn just outside the cell so it doesn't immediately re-overlap.
    const launchX = c.x + dx * (r + 4);
    const launchY = c.y + dy * (r + 4);
    ejected.push({
      id: newId("e"),
      ownerId: p.id,
      x: launchX,
      y: launchY,
      vx: dx * EJECT_VELOCITY,
      vy: dy * EJECT_VELOCITY,
      mass: EJECT_MASS,
      color: c.color,
      expiresAt: now + EJECT_LIFETIME_MS,
    });
    anyFired = true;
  }
  if (anyFired) {
    p.lastEjectAt = now;
    console.log("[action] eject success", { ejected: ejected.length });
  } else if (!anyEligible) {
    console.log("eject blocked: mass too low");
  }
}

function updateEjected(dt: number): void {
  if (ejected.length === 0) return;
  const now = Date.now();
  // Exponential friction; matches feel of Offline Classic's per-frame decay.
  const decay = Math.exp(-EJECT_FRICTION_PER_S * dt);
  for (let i = ejected.length - 1; i >= 0; i--) {
    const e = ejected[i];
    e.x += e.vx * dt;
    e.y += e.vy * dt;
    e.vx *= decay;
    e.vy *= decay;
    if (Math.abs(e.vx) < EJECT_MIN_SPEED) e.vx = 0;
    if (Math.abs(e.vy) < EJECT_MIN_SPEED) e.vy = 0;
    // Clamp to world.
    if (e.x < 8) { e.x = 8; e.vx = -e.vx * 0.5; }
    if (e.x > MAP_W - 8) { e.x = MAP_W - 8; e.vx = -e.vx * 0.5; }
    if (e.y < 8) { e.y = 8; e.vy = -e.vy * 0.5; }
    if (e.y > MAP_H - 8) { e.y = MAP_H - 8; e.vy = -e.vy * 0.5; }
    if (now >= e.expiresAt) {
      ejected.splice(i, 1);
    }
  }
}

function mergeOwnCells(): void {
  const now = Date.now();
  for (const p of players.values()) {
    if (p.dead) continue;
    if (p.cells.length < 2) continue;
    // O(n^2) but n <= 16 by MAX_CELLS_PER_PLAYER — trivial.
    outer: for (let i = 0; i < p.cells.length; i++) {
      for (let j = i + 1; j < p.cells.length; j++) {
        const a = p.cells[i];
        const b = p.cells[j];
        if (a.freshSplitUntil > now || b.freshSplitUntil > now) continue;
        const ar = radius(a.mass);
        const br = radius(b.mass);
        const dx = a.x - b.x, dy = a.y - b.y;
        const d2 = dx * dx + dy * dy;
        const merge = (ar + br) * 0.6; // deep enough overlap = merge
        if (d2 < merge * merge) {
          // Absorb smaller into larger.
          const winner = a.mass >= b.mass ? a : b;
          const loser = winner === a ? b : a;
          winner.mass += loser.mass;
          p.cells.splice(p.cells.indexOf(loser), 1);
          break outer;
        }
      }
    }
  }
}

function tryEatEjected(): void {
  if (ejected.length === 0) return;
  const now = Date.now();
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const c of p.cells) {
      const r = radius(c.mass);
      const r2 = r * r;
      for (let i = ejected.length - 1; i >= 0; i--) {
        const e = ejected[i];
        // Don't let the source eat their own feed before it's traveled.
        if (e.ownerId === p.id && now - (e.expiresAt - EJECT_LIFETIME_MS) < 250) continue;
        const dx = e.x - c.x, dy = e.y - c.y;
        if (dx * dx + dy * dy < r2) {
          if (c.mass < MAX_MASS) c.mass = Math.min(MAX_MASS, c.mass + e.mass);
          ejected.splice(i, 1);
        }
      }
    }
  }
}

// ────────────────────────────────────────────────────────── snapshot
interface SnapshotEntity {
  id: string;
  name?: string;
  x: number;
  y: number;
  mass: number;
  radius: number;
  color: string;
  skinId?: string;
  ownerId?: string;
  isHuman?: boolean;
  isSelf?: boolean;
}

interface LeaderboardEntry {
  id: string;
  name: string;
  mass: number;
}

function buildLeaderboard(): LeaderboardEntry[] {
  const list: LeaderboardEntry[] = [];
  for (const p of players.values()) {
    if (p.dead) continue;
    let mass = 0;
    for (const c of p.cells) mass += c.mass;
    if (mass <= 0) continue;
    list.push({ id: p.id, name: p.name, mass: Math.round(mass) });
  }
  list.sort((a, b) => b.mass - a.mass);
  return list.slice(0, LEADERBOARD_SIZE);
}

function sendSnapshotTo(p: Player, leaderboard: LeaderboardEntry[]): void {
  if (p.isBot || !p.socket || p.socket.readyState !== WebSocket.OPEN) return;
  // Pick the viewer center: human's center of mass or world center if dead.
  let vx = MAP_W / 2, vy = MAP_H / 2;
  if (!p.dead && p.cells.length > 0) {
    let cx = 0, cy = 0, tm = 0;
    for (const c of p.cells) {
      cx += c.x * c.mass;
      cy += c.y * c.mass;
      tm += c.mass;
    }
    vx = cx / tm;
    vy = cy / tm;
  }
  const r2 = SNAPSHOT_RADIUS * SNAPSHOT_RADIUS;

  const cells: SnapshotEntity[] = [];
  for (const other of players.values()) {
    if (other.dead) continue;
    for (const c of other.cells) {
      const dx = c.x - vx, dy = c.y - vy;
      if (dx * dx + dy * dy > r2) continue;
      cells.push({
        id: c.id,
        name: other.name,
        x: Math.round(c.x),
        y: Math.round(c.y),
        mass: Math.round(c.mass),
        radius: Math.round(radius(c.mass)),
        color: c.color,
        skinId: other.skinId || "",
        ownerId: other.id,
        isHuman: !other.isBot,
        isSelf: other.id === p.id,
      });
    }
  }

  // Pellets are always mass=1, radius=6 — strip those redundant fields and
  // let the client default them. Saves ~30 % on the per-pellet payload,
  // which is the bulk of the snapshot.
  const visiblePellets: Array<{ id: string; x: number; y: number; color: string }> = [];
  for (const pe of pellets) {
    const dx = pe.x - vx, dy = pe.y - vy;
    if (dx * dx + dy * dy > r2) continue;
    visiblePellets.push({
      id: pe.id,
      x: Math.round(pe.x),
      y: Math.round(pe.y),
      color: pe.color,
    });
  }

  const visibleEjected: SnapshotEntity[] = [];
  for (const e of ejected) {
    const dx = e.x - vx, dy = e.y - vy;
    if (dx * dx + dy * dy > r2) continue;
    visibleEjected.push({
      id: e.id,
      x: Math.round(e.x),
      y: Math.round(e.y),
      mass: e.mass,
      radius: Math.round(radius(e.mass)),
      color: e.color,
    });
  }

  const visibleViruses: SnapshotEntity[] = [];
  for (const v of viruses) {
    const dx = v.x - vx, dy = v.y - vy;
    if (dx * dx + dy * dy > r2 * 1.2) continue;
    visibleViruses.push({
      id: v.id,
      x: Math.round(v.x),
      y: Math.round(v.y),
      mass: v.mass,
      radius: Math.round(radius(v.mass)),
      color: v.color,
    });
  }

  let selfMass = 0;
  if (!p.dead) for (const c of p.cells) selfMass += c.mass;

  const payload = {
    type: "state",
    serverTime: Date.now(),
    self: {
      id: p.id,
      dead: p.dead,
      mass: Math.round(selfMass),
      x: Math.round(vx),
      y: Math.round(vy),
    },
    players: cells,
    pellets: visiblePellets,
    viruses: visibleViruses,
    ejected: visibleEjected,
    leaderboard,
    online: [...players.values()].filter((q) => !q.isBot).length,
  };
  try {
    p.socket.send(JSON.stringify(payload));
  } catch {
    /* swallow — disconnects are handled by ws.on('close') */
  }
}

// ────────────────────────────────────────────────────────── main loop
let last = Date.now();
setInterval(() => {
  const now = Date.now();
  const dt = clamp((now - last) / 1000, 0, 0.1);
  last = now;

  // Bot decisions
  for (const p of players.values()) {
    if (p.isBot && !p.dead) botDecide(p, now);
  }

  // Per-player movement
  for (const p of players.values()) {
    if (p.dead) continue;
    applyMovement(p, dt);
  }

  // Eat pellets
  for (const p of players.values()) {
    if (p.dead) continue;
    tryEatPellets(p);
  }

  resolveCellVsCell();
  resolveCellVsVirus();
  mergeOwnCells();
  updateEjected(dt);
  tryEatEjected();
  refillWorld();

  // Highest mass tracking
  for (const p of players.values()) {
    if (p.dead) continue;
    let m = 0;
    for (const c of p.cells) m += c.mass;
    if (m > p.highestMass) p.highestMass = m;
  }

  const lb = buildLeaderboard();
  for (const p of players.values()) {
    if (!p.isBot) sendSnapshotTo(p, lb);
  }

  // Stale human cleanup (>15 s without messages)
  for (const [id, p] of players) {
    if (p.isBot) continue;
    if (now - p.lastSeenAt > 15000) {
      try { p.socket?.close(); } catch { /* ignore */ }
      players.delete(id);
    }
  }
}, TICK_MS);

// ────────────────────────────────────────────────────────── ws server
const http = createServer((_, res) => {
  res.writeHead(200, { "content-type": "text/plain" });
  res.end("Yazario Online Classic server");
});
const wss = new WebSocketServer({ server: http });

wss.on("connection", (ws) => {
  let player: Player | null = null;

  const safeSend = (obj: unknown) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    try { ws.send(JSON.stringify(obj)); } catch { /* ignore */ }
  };

  ws.on("message", (raw) => {
    let msg: any;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    const type = msg?.type;
    if (type === "join") {
      if (player) return; // already joined
      const name =
        typeof msg.name === "string" && msg.name.trim().length > 0
          ? msg.name.toString().slice(0, 18).trim()
          : "Player";
      const skinId =
        typeof msg.skin === "string" && msg.skin.length > 0
          ? msg.skin.toString().slice(0, 128)
          : "";
      const id = newId("human");
      player = {
        id,
        socket: ws,
        isBot: false,
        name,
        color: pickColor(),
        skinId,
        cells: [],
        input: { dx: 0, dy: 0 },
        dead: false,
        deadUntil: 0,
        lastSplitAt: 0,
        lastEjectAt: 0,
        spawnTime: Date.now(),
        highestMass: START_MASS,
        lastSeenAt: Date.now(),
        nextDecideAt: 0,
      };
      spawnCellForPlayer(player);
      players.set(id, player);
      safeSend({
        type: "connected",
        id,
        mapWidth: MAP_W,
        mapHeight: MAP_H,
        tickRate: TICK_RATE,
        name: player.name,
      });
    } else if (type === "input") {
      if (!player) return;
      const dx = Number(msg.dx);
      const dy = Number(msg.dy);
      if (!Number.isFinite(dx) || !Number.isFinite(dy)) return;
      player.input.dx = clamp(dx, -1, 1);
      player.input.dy = clamp(dy, -1, 1);
      player.lastSeenAt = Date.now();
    } else if (type === "split") {
      if (!player) return;
      console.log("[action] split", player.id, player.cells.length, player.cells[0]?.mass);
      tryDoSplit(player);
      player.lastSeenAt = Date.now();
    } else if (type === "eject") {
      if (!player) return;
      console.log("[action] eject", player.id, player.cells.length, player.cells[0]?.mass);
      tryDoEject(player);
      player.lastSeenAt = Date.now();
    } else if (type === "respawn") {
      if (!player) return;
      if (player.dead) spawnCellForPlayer(player);
      player.lastSeenAt = Date.now();
    } else if (type === "ping") {
      const t = Number(msg.t);
      safeSend({ type: "pong", t: Number.isFinite(t) ? t : 0 });
      if (player) player.lastSeenAt = Date.now();
    }
  });

  ws.on("close", () => {
    if (player) {
      players.delete(player.id);
      player = null;
    }
  });

  ws.on("error", () => { /* ignore */ });
});

http.listen(PORT, () => {
  console.log(`[yazario] Online Classic server listening on :${PORT}`);
});
