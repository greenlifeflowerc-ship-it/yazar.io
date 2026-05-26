/**
 * Yazario Online Classic V4 — exact offline-classic physics, uWebSockets.js transport.
 *
 * Run:  npm run dev               (tsx watch)
 *       npm run build && npm start (prod — runs compiled dist/index.js)
 */

import uWS from "uWebSockets.js";

// ─────────────────────────────────────────────────────── world constants
const PORT = Number(process.env.PORT ?? 2567);

const WORLD_SIZE = 14142;
const TARGET_PELLETS = 8000;
const TARGET_VIRUSES = 30;
const TARGET_BOTS = 70;

const MAX_CELLS_PER_PLAYER = 16;
const MAX_CELL_MASS = 22500;
const SPLIT_MIN_MASS = 35;
const EJECT_MIN_MASS = 35;

const MASS_DECAY_RATE = 0.002;
const DECAY_THRESHOLD = 35;

const EJECT_COST = 13;
const EJECT_MASS = 13;
const EJECT_CONSUMED_MASS = 13;
const EJECT_VELOCITY_INITIAL = 1500;
const EJECT_FRICTION_PER_FRAME = 0.91;

const SPLIT_IMPULSE_INITIAL = 1500;
const SPLIT_FRICTION_PER_FRAME = 0.91;

const VIRUS_MASS = 100;
const VIRUS_SHOT_INITIAL = 1200;
const PELLET_MASS = 1;

// Movement (simple impulse + damping + per-radius clamp).
const INPUT_MOVE_STRENGTH = 1200;
const DAMPING_PER_SECOND = 5.8;

// Cohesion.
const COHESION_STRENGTH = 4.5;
const COHESION_MAX_DISTANCE = 120.0;
const COHESION_COOLDOWN_FACTOR = 0.35;

// Separation.
const SEPARATION_STRENGTH = 34.0;
const MIN_GAP = 3.0;
const HARD_CORRECTION_ALPHA = 0.5;      // 0 = none (jitter on split), 1 = full (snap)

// Attack spread.
const ATTACK_SPREAD_STRENGTH = 22.0;
const LAUNCH_OFFSET = 10.0;
const PROJECTILE_SPAWN_CLEARANCE = 6.0;
const LANE_WIDTH_BASE = 18.0;
const LANE_WIDTH_RADIUS_FACTOR = 0.72;
const LANE_FORWARD_DEPTH_FACTOR = 2.8;

const REFERENCE_RADIUS = 35.0;
const MAX_SMALL_CELL_SPEED = 360.0;
const MAX_LARGE_CELL_SPEED = 115.0;
const SPEED_RADIUS_POWER = 0.38;
const SPEED_SCALE_BASE = 260.0;

// Merge.
const MERGE_DISTANCE_FACTOR = 0.75;
const MERGE_COOLDOWN_BASE_S = 14.0;
const MERGE_COOLDOWN_MAX_S = 28.0;
const MERGE_COOLDOWN_PER_RADIUS = 0.12;

const EAT_RATIO_WHOLE = 1.25;
const EAT_RATIO_FRESH_SPLIT = 1.33;

// Bot scan radii / cadence.
const BOT_SCAN_RADIUS = 900;
const BOT_PELLET_SCAN = 600;
const BOT_VIRUS_AVOIDANCE = 250;
const BOT_DECIDE_CADENCE_MS = 200;
const BOT_RESPAWN_DELAY_MS = 500;

// Networking — 30 Hz is the proven stable rate on 1-vCPU hosts.
const TICK_RATE = 30;
const TICK_MS = 1000 / TICK_RATE;
const TICK_BUDGET_MS = TICK_MS * 0.8;   // warn when >80 % of budget used
const SLOW_TICK_EVERY = 4;              // 7.5 Hz pellet refresh
const VIEWPORT_RADIUS = 2200;
// Entities outside this multiple of VIEWPORT_RADIUS are NOT sent. 1.15
// gives a comfortable scroll margin so entities don't pop into view at the
// viewport edge, while still cutting ~20 % of the payload vs. the legacy
// 1.3 oversend. The 2-vCPU host can comfortably handle this.
const VIEWPORT_SEND_MULT = 1.15;
const LEADERBOARD_SIZE = 10;
const STALE_PLAYER_MS = 20000;
const EJECT_OWNER_IMMUNITY_MS = 200;

// Skip updCells / updViruses / updEjected for entities that moved less than
// these thresholds since the last broadcast. Saves a huge amount of "nothing
// really changed" updates when many cells are sitting still or barely
// drifting in cohesion.
const UPDATE_POS_EPSILON = 0.5;   // world units
const UPDATE_MASS_EPSILON = 0.5;  // mass units

// Spatial grid — 36×36 buckets of ~393 units each. Sized so an avg-radius
// cell touches 1 bucket and a max-radius cell touches at most 9.
const GRID_CELL_SIZE = 400;
const GRID_DIM = Math.ceil(WORLD_SIZE / GRID_CELL_SIZE);

const PALETTE = [
  "#FF0000", "#00FF00", "#0091FF", "#FFD700", "#FF00FF",
  "#00FFFF", "#FF6600", "#9D00FF", "#39FF14", "#FF1493",
];

const BOT_NAMES = [
  "Bot_Killer", "Doge", "Ninja", "Slayer42", "Cookie", "AgarKing",
  "TacoCat", "PixelPro", "Nyan", "Mario", "Sonic", "Pikachu", "Yoshi",
  "Bart", "Donut", "Bender", "Sponge", "Kirby", "Link", "Zelda", "Samus",
  "Ezio", "Solid", "Master", "Sneaky", "Wraith", "Reaper", "Phantom",
  "Bandit", "Viper", "Hawk",
];

// ─────────────────────────────────────────────────────── helpers
function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}
function radius(mass: number): number {
  return Math.sqrt(Math.max(mass, 0) / Math.PI) * 10;
}
function rand(min: number, max: number): number {
  return min + Math.random() * (max - min);
}
function pickPaletteColor(): string {
  return PALETTE[Math.floor(Math.random() * PALETTE.length)];
}
function maxSpeedForRadius(r: number): number {
  const s = SPEED_SCALE_BASE *
    Math.pow(REFERENCE_RADIUS / (r < 1 ? 1 : r), SPEED_RADIUS_POWER);
  return clamp(s, MAX_LARGE_CELL_SPEED, MAX_SMALL_CELL_SPEED);
}
function mergeCooldownMsForRadius(r: number): number {
  const secs = clamp(
    MERGE_COOLDOWN_BASE_S + r * MERGE_COOLDOWN_PER_RADIUS,
    MERGE_COOLDOWN_BASE_S,
    MERGE_COOLDOWN_MAX_S,
  );
  return Math.round(secs * 1000);
}

let entitySeq = 0;
function newId(prefix: string): string {
  return `${prefix}${++entitySeq}`;
}

// ─────────────────────────────────────────────────────── spatial hash grid
/**
 * Uniform-grid spatial hash. Insertion is O(1), removal is O(bucket_size),
 * query over a circle is O(buckets_covered × items_per_bucket).
 *
 * Two usage patterns:
 *   • Pellets — incrementally maintained (insert on spawn, remove on eat).
 *   • Cells/ejected/viruses — cleared and rebuilt once per tick after
 *     physics (positions moved so previous bucket addresses are stale).
 */
class SpatialGrid<T extends { id: string; x: number; y: number }> {
  private buckets: Map<number, T[]> = new Map();

  private key(x: number, y: number): number {
    const gx = clamp(Math.floor(x / GRID_CELL_SIZE), 0, GRID_DIM - 1);
    const gy = clamp(Math.floor(y / GRID_CELL_SIZE), 0, GRID_DIM - 1);
    return gy * GRID_DIM + gx;
  }

  clear(): void { this.buckets.clear(); }

  insert(item: T): void {
    const k = this.key(item.x, item.y);
    const b = this.buckets.get(k);
    if (b) b.push(item); else this.buckets.set(k, [item]);
  }

  remove(item: T): void {
    const k = this.key(item.x, item.y);
    const b = this.buckets.get(k);
    if (!b) return;
    const idx = b.indexOf(item);
    if (idx >= 0) {
      // Swap-remove for O(1) instead of splice O(N).
      const last = b.length - 1;
      if (idx !== last) b[idx] = b[last];
      b.pop();
    }
  }

  /** Invoke fn for every item whose bucket intersects circle (x,y,r). */
  queryEach(x: number, y: number, r: number, fn: (item: T) => void): void {
    const minGx = clamp(Math.floor((x - r) / GRID_CELL_SIZE), 0, GRID_DIM - 1);
    const maxGx = clamp(Math.floor((x + r) / GRID_CELL_SIZE), 0, GRID_DIM - 1);
    const minGy = clamp(Math.floor((y - r) / GRID_CELL_SIZE), 0, GRID_DIM - 1);
    const maxGy = clamp(Math.floor((y + r) / GRID_CELL_SIZE), 0, GRID_DIM - 1);
    for (let gy = minGy; gy <= maxGy; gy++) {
      const rowBase = gy * GRID_DIM;
      for (let gx = minGx; gx <= maxGx; gx++) {
        const b = this.buckets.get(rowBase + gx);
        if (b) for (let i = 0; i < b.length; i++) fn(b[i]);
      }
    }
  }
}

// ─────────────────────────────────────────────────────── types
interface InputState {
  dx: number;
  dy: number;
  attack: boolean;
  lastDir: { x: number; y: number };
  seq: number;
}

interface Cell {
  id: string;
  ownerId: string;
  x: number;
  y: number;
  vx: number;
  vy: number;
  spX: number;       // split impulse
  spY: number;
  mass: number;
  color: string;
  freshSplit: boolean;
  mergeReadyAt: number;
}

interface SocketData { playerId: string; }

interface Player {
  id: string;
  socket: uWS.WebSocket<SocketData> | null;
  isBot: boolean;
  name: string;
  color: string;
  skinId: string;
  cells: Cell[];
  input: InputState;
  dead: boolean;
  deadAt: number;
  lastInputSeq: number;
  lastSeenAt: number;
  spawnAt: number;
  highestMass: number;
  massMult: number;
  // Per-player eject tuning, sent by the client on join. These match the
  // GameSettings sliders in the offline classic so the server reproduces
  // the player's chosen feed feel — without this, the server's copy of
  // every piece flies on the default arc while the client's local copy
  // flies on the player's tuned arc, and the two diverge by the per-tick
  // friction × speed delta over the ~1 s flight.
  ejectSpeedMult: number;
  ejectDistMult: number;
  eatenCount: number;
  // bot scratch
  aiDir: { x: number; y: number };
  aiNextDecide: number;
  aiNextSplit: number;
  aiNextEject: number;
  // per-player visibility set
  seenCells: Set<string>;
  seenPellets: Set<string>;
  seenViruses: Set<string>;
  seenEjected: Set<string>;
  // Last broadcast (x, y, mass) per entity id — used to skip updates that
  // wouldn't actually move the cell on the client. Compact triplet array
  // {x,y,m} avoids the allocation cost of {x,y,mass} objects.
  lastSent: Map<string, [number, number, number]>;
  lastSentVirus: Map<string, [number, number, number]>;
  lastSentEjected: Map<string, [number, number]>;
}

interface Pellet { id: string; x: number; y: number; color: string; }
interface Virus { id: string; x: number; y: number; vx: number; vy: number; mass: number; feedCount: number; lfX: number; lfY: number; }
interface EjectedMass {
  id: string;
  ownerId: string;
  x: number; y: number;
  vx: number; vy: number;
  color: string;
  spawnedAt: number;
  // Per-piece friction baked in at spawn from the owner's
  // ejectSpeedMult / ejectDistMult so the piece honours the player's
  // tuning even after they disconnect.
  fric: number;
}

// ─────────────────────────────────────────────────────── world state
const players = new Map<string, Player>();
const pellets = new Map<string, Pellet>();
const viruses = new Map<string, Virus>();
const ejected = new Map<string, EjectedMass>();

// Spatial grids.
const pelletGrid = new SpatialGrid<Pellet>();   // incremental
const cellGrid = new SpatialGrid<Cell>();       // rebuilt per tick
const ejectedGrid = new SpatialGrid<EjectedMass>(); // rebuilt per tick
const virusGrid = new SpatialGrid<Virus>();     // rebuilt per tick

let serverTick = 0;
let lastNowMs = Date.now();

// ─────────────────────────────────────────────────────── spawning
function randomWorldPos(margin = 200): { x: number; y: number } {
  return { x: rand(margin, WORLD_SIZE - margin), y: rand(margin, WORLD_SIZE - margin) };
}

function safeSpawnPos(margin = 600): { x: number; y: number } {
  // Use cellGrid to find empty area instead of iterating all players.
  for (let attempt = 0; attempt < 20; attempt++) {
    const p = randomWorldPos(margin);
    let safe = true;
    cellGrid.queryEach(p.x, p.y, 800, (c) => {
      if (!safe) return;
      const dx = c.x - p.x, dy = c.y - p.y;
      if (dx * dx + dy * dy < 800 * 800) safe = false;
    });
    if (safe) return p;
  }
  return randomWorldPos(margin);
}

function spawnPellet(): Pellet {
  const p = randomWorldPos(40);
  const pellet: Pellet = { id: newId("p"), x: p.x, y: p.y, color: pickPaletteColor() };
  pellets.set(pellet.id, pellet);
  pelletGrid.insert(pellet);
  return pellet;
}

function removePellet(p: Pellet): void {
  pellets.delete(p.id);
  pelletGrid.remove(p);
}

function spawnVirus(): Virus {
  const p = randomWorldPos(300);
  const v: Virus = { id: newId("v"), x: p.x, y: p.y, vx: 0, vy: 0, mass: VIRUS_MASS, feedCount: 0, lfX: 0, lfY: 0 };
  viruses.set(v.id, v);
  return v;
}

function spawnCellForPlayer(p: Player): void {
  const pos = safeSpawnPos();
  const mult = p.isBot ? 1.0 : clamp(p.massMult, 0.5, 300.0);
  const startMass = p.isBot ? 100 : clamp(Math.round(5000 * mult), 76, 1e9);
  p.cells = [{
    id: newId("c"),
    ownerId: p.id,
    x: pos.x, y: pos.y,
    vx: 0, vy: 0,
    spX: 0, spY: 0,
    mass: startMass,
    color: p.color,
    freshSplit: false,
    mergeReadyAt: Date.now(),
  }];
  p.dead = false;
  p.deadAt = 0;
  p.spawnAt = Date.now();
  p.highestMass = startMass;
  p.eatenCount = 0;
  p.input.dx = 0;
  p.input.dy = 0;
  p.input.attack = false;
}

function makeBot(): Player {
  const id = newId("bot");
  const bot: Player = {
    id, socket: null, isBot: true,
    name: BOT_NAMES[Math.floor(Math.random() * BOT_NAMES.length)],
    color: pickPaletteColor(), skinId: `bot_${id}`,
    cells: [],
    input: { dx: 0, dy: 0, attack: false, lastDir: { x: 1, y: 0 }, seq: 0 },
    dead: false, deadAt: 0, lastInputSeq: 0,
    lastSeenAt: Date.now(), spawnAt: Date.now(),
    highestMass: 100, massMult: 1.0,
    ejectSpeedMult: 1.0, ejectDistMult: 1.0,
    eatenCount: 0,
    aiDir: { x: 0, y: 0 }, aiNextDecide: 0, aiNextSplit: 0, aiNextEject: 0,
    seenCells: new Set(), seenPellets: new Set(),
    seenViruses: new Set(), seenEjected: new Set(),
    lastSent: new Map(), lastSentVirus: new Map(), lastSentEjected: new Map(),
  };
  spawnCellForPlayer(bot);
  return bot;
}

// init world
for (let i = 0; i < TARGET_PELLETS; i++) spawnPellet();
for (let i = 0; i < TARGET_VIRUSES; i++) spawnVirus();
for (let i = 0; i < TARGET_BOTS; i++) {
  const b = makeBot();
  players.set(b.id, b);
}

// ─────────────────────────────────────────────────────── grid rebuild
function rebuildMovingGrids(): void {
  cellGrid.clear();
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const c of p.cells) cellGrid.insert(c);
  }
  ejectedGrid.clear();
  for (const e of ejected.values()) ejectedGrid.insert(e);
  virusGrid.clear();
  for (const v of viruses.values()) virusGrid.insert(v);
}

// ─────────────────────────────────────────────────────── centre of mass
function centerOfMass(p: Player): { x: number; y: number } {
  if (p.cells.length === 0) return { x: WORLD_SIZE / 2, y: WORLD_SIZE / 2 };
  let cx = 0, cy = 0, tm = 0;
  for (const c of p.cells) { cx += c.x * c.mass; cy += c.y * c.mass; tm += c.mass; }
  if (tm <= 0) return { x: p.cells[0].x, y: p.cells[0].y };
  return { x: cx / tm, y: cy / tm };
}

function totalMass(p: Player): number {
  let m = 0;
  for (const c of p.cells) m += c.mass;
  return m;
}

// ─────────────────────────────────────────────────────── bot AI (grid-based)
function botDecide(p: Player, now: number): void {
  if (p.dead || now < p.aiNextDecide) return;
  p.aiNextDecide = now + BOT_DECIDE_CADENCE_MS + Math.random() * 250;

  const c = centerOfMass(p);
  const myMass = totalMass(p);
  if (myMass <= 0) return;

  let threatX = 0, threatY = 0, threatW = 0;
  let preyX = c.x, preyY = c.y, preyDist = Infinity;

  // Query nearby cells via grid (≈10 instead of all players' cells).
  cellGrid.queryEach(c.x, c.y, BOT_SCAN_RADIUS, (oc) => {
    if (oc.ownerId === p.id) return;
    const dx = oc.x - c.x, dy = oc.y - c.y;
    const d2 = dx * dx + dy * dy;
    if (d2 > BOT_SCAN_RADIUS * BOT_SCAN_RADIUS) return;
    const d = Math.sqrt(d2);
    if (oc.mass > myMass * EAT_RATIO_WHOLE && d < 750) {
      const w = 1 - d / 750;
      threatX += (c.x - oc.x) * w;
      threatY += (c.y - oc.y) * w;
      threatW += w;
    } else if (myMass > oc.mass * EAT_RATIO_WHOLE && d < preyDist) {
      preyX = oc.x; preyY = oc.y; preyDist = d;
    }
  });

  if (myMass > 130 && p.cells.length < MAX_CELLS_PER_PLAYER) {
    virusGrid.queryEach(c.x, c.y, BOT_VIRUS_AVOIDANCE, (v) => {
      const dx = v.x - c.x, dy = v.y - c.y;
      const d = Math.hypot(dx, dy);
      if (d > 0 && d < BOT_VIRUS_AVOIDANCE) {
        const w = (1 - d / BOT_VIRUS_AVOIDANCE) * 0.7;
        threatX += (c.x - v.x) * w;
        threatY += (c.y - v.y) * w;
        threatW += w;
      }
    });
  }

  let tx: number, ty: number;
  if (threatW > 0.3) {
    tx = c.x + threatX; ty = c.y + threatY;
  } else if (isFinite(preyDist)) {
    tx = preyX; ty = preyY;
  } else {
    // Find nearest pellet via grid.
    let bd = BOT_PELLET_SCAN * BOT_PELLET_SCAN;
    let bestX = 0, bestY = 0, found = false;
    pelletGrid.queryEach(c.x, c.y, BOT_PELLET_SCAN, (pe) => {
      const dx = pe.x - c.x, dy = pe.y - c.y;
      const d2 = dx * dx + dy * dy;
      if (d2 < bd) { bd = d2; bestX = pe.x; bestY = pe.y; found = true; }
    });
    if (found) { tx = bestX; ty = bestY; }
    else { tx = c.x + rand(-300, 300); ty = c.y + rand(-300, 300); }
  }

  const margin = 400;
  if (c.x < margin) tx += 400;
  if (c.x > WORLD_SIZE - margin) tx -= 400;
  if (c.y < margin) ty += 400;
  if (c.y > WORLD_SIZE - margin) ty -= 400;

  const dx = tx - c.x, dy = ty - c.y;
  const m = Math.hypot(dx, dy);
  if (m > 0.5) { p.aiDir.x = dx / m; p.aiDir.y = dy / m; }
  else { p.aiDir.x = 0; p.aiDir.y = 0; }
}

function botDecideSplit(p: Player, now: number): void {
  if (p.dead || now < p.aiNextSplit) return;
  if (p.cells.length >= 6) { p.aiNextSplit = now + 1500; return; }
  const myMass = totalMass(p);
  if (myMass < 60) { p.aiNextSplit = now + 800; return; }
  const c = centerOfMass(p);
  const myR = radius(myMass);

  let shouldSplit = false;
  cellGrid.queryEach(c.x, c.y, myR * 2.8, (oc) => {
    if (shouldSplit || oc.ownerId === p.id) return;
    const dx = oc.x - c.x, dy = oc.y - c.y;
    const d = Math.hypot(dx, dy);
    if (myMass > oc.mass * 1.3 && d > myR * 1.1 && d < myR * 2.8) shouldSplit = true;
  });

  if (shouldSplit) {
    tryDoSplit(p, p.aiDir.x, p.aiDir.y);
    p.aiNextSplit = now + 3000 + Math.random() * 5000;
  } else {
    p.aiNextSplit = now + 900;
  }
}

function botDecideEject(p: Player, now: number): void {
  if (p.dead || now < p.aiNextEject) return;
  const myMass = totalMass(p);
  if (myMass < 140) { p.aiNextEject = now + 800; return; }
  const c = centerOfMass(p);

  let bigEnemy = false;
  cellGrid.queryEach(c.x, c.y, 600, (oc) => {
    if (bigEnemy || oc.ownerId === p.id) return;
    if (oc.mass > myMass * 1.4) bigEnemy = true;
  });
  if (!bigEnemy) { p.aiNextEject = now + 600; return; }

  let didEject = false;
  virusGrid.queryEach(c.x, c.y, 450, (v) => {
    if (didEject) return;
    const dx = v.x - c.x, dy = v.y - c.y;
    const d = Math.hypot(dx, dy);
    if (d < 20 || d > 450) return;
    const ax = dx / d, ay = dy / d;
    if (ax * p.aiDir.x + ay * p.aiDir.y > 0.45) {
      tryDoEject(p, p.aiDir.x, p.aiDir.y);
      didEject = true;
    }
  });
  p.aiNextEject = didEject ? now + 1500 + Math.random() * 2000 : now + 700;
}

// ─────────────────────────────────────────────────────── physics
function applyInputForce(p: Player, dt: number): void {
  const rawDx = p.isBot ? p.aiDir.x : p.input.dx;
  const rawDy = p.isBot ? p.aiDir.y : p.input.dy;
  const mag = Math.hypot(rawDx, rawDy);
  if (mag < 0.05) return;
  const intensity = mag > 1.0 ? 1.0 : mag;
  const ux = rawDx / mag, uy = rawDy / mag;
  const com = centerOfMass(p);
  const targetX = com.x + ux * 1000;
  const targetY = com.y + uy * 1000;
  for (const c of p.cells) {
    const toX = targetX - c.x, toY = targetY - c.y;
    const dist = Math.hypot(toX, toY);
    if (dist < 0.1) continue;
    const dirX = toX / dist, dirY = toY / dist;
    const r = radius(c.mass);
    const maxV = maxSpeedForRadius(r);
    const agility = clamp(Math.pow(150.0 / (c.mass + 50.0), 0.15), 0.7, 1.5);
    const accel = maxV * DAMPING_PER_SECOND * agility;
    c.vx += dirX * accel * intensity * dt;
    c.vy += dirY * accel * intensity * dt;
  }
}

function applyCohesion(p: Player, dt: number): void {
  if (p.cells.length < 2) return;
  const com = centerOfMass(p);
  let maxMass = 0;
  for (const c of p.cells) if (c.mass > maxMass) maxMass = c.mass;
  const now = Date.now();
  for (const c of p.cells) {
    if (Math.hypot(c.spX, c.spY) >= 1) continue;
    const dx = com.x - c.x, dy = com.y - c.y;
    const d = Math.hypot(dx, dy);
    if (d === 0) continue;
    let factor = now >= c.mergeReadyAt ? 1.0 : COHESION_COOLDOWN_FACTOR;
    if (maxMass > 500 && c.mass < maxMass * 0.2) factor *= 0.3;
    const accel = COHESION_STRENGTH * Math.min(d, COHESION_MAX_DISTANCE) * factor;
    c.vx += (dx / d) * accel * dt;
    c.vy += (dy / d) * accel * dt;
  }
}

function applySeparation(p: Player, dt: number): void {
  const cs = p.cells;
  if (cs.length < 2) return;
  const now = Date.now();
  for (let i = 0; i < cs.length; i++) {
    const a = cs[i];
    for (let j = i + 1; j < cs.length; j++) {
      const b = cs[j];
      if (now >= a.mergeReadyAt && now >= b.mergeReadyAt) continue;
      const dx = a.x - b.x, dy = a.y - b.y;
      let d = Math.hypot(dx, dy);
      const ar = radius(a.mass), br = radius(b.mass);
      const minDist = ar + br + MIN_GAP;
      if (d >= minDist) continue;
      if (d === 0) { a.x += 0.5; d = 0.5; }
      const overlap = minDist - d;
      const nx = dx / d, ny = dy / d;
      const totMass = a.mass + b.mass;
      // Velocity push (smooth ramp).
      const fx = nx * overlap * SEPARATION_STRENGTH;
      const fy = ny * overlap * SEPARATION_STRENGTH;
      a.vx += fx * (b.mass / totMass) * dt;
      a.vy += fy * (b.mass / totMass) * dt;
      b.vx -= fx * (a.mass / totMass) * dt;
      b.vy -= fy * (a.mass / totMass) * dt;
      // Soft position correction (alpha < 1 to avoid snap jitter).
      // Fixes "cells overlap visibly" without the harsh client/server snap
      // that a full alpha=1 correction produced in earlier attempts.
      const aPush = overlap * (b.mass / totMass) * HARD_CORRECTION_ALPHA;
      const bPush = overlap * (a.mass / totMass) * HARD_CORRECTION_ALPHA;
      a.x += nx * aPush; a.y += ny * aPush;
      b.x -= nx * bPush; b.y -= ny * bPush;
    }
  }
}

function applyAttackSpread(p: Player, dt: number): void {
  if (!p.input.attack || p.cells.length < 2) return;
  const dirRaw = p.input.lastDir;
  const amag = Math.hypot(dirRaw.x, dirRaw.y);
  if (amag === 0) return;
  const ux = dirRaw.x / amag, uy = dirRaw.y / amag;
  const px = -uy, py = ux;
  let main = p.cells[0];
  for (const c of p.cells) if (c.mass > main.mass) main = c;
  const mR = radius(main.mass);
  const laneW = LANE_WIDTH_BASE + mR * LANE_WIDTH_RADIUS_FACTOR;
  const laneD = mR * LANE_FORWARD_DEPTH_FACTOR;
  for (const c of p.cells) {
    if (c === main) continue;
    if (Math.hypot(c.spX, c.spY) >= 1) continue;
    const rx = c.x - main.x, ry = c.y - main.y;
    const fwd = rx * ux + ry * uy;
    const side = rx * px + ry * py;
    if (fwd <= 0 || fwd >= laneD) continue;
    if (Math.abs(side) >= laneW) continue;
    let sign: number;
    if (Math.abs(side) < 1) sign = (c.id.charCodeAt(c.id.length - 1) & 1) ? 1 : -1;
    else sign = side >= 0 ? 1 : -1;
    const sidePush = ATTACK_SPREAD_STRENGTH * (laneW - Math.abs(side));
    c.vx += px * sign * sidePush * dt;
    c.vy += py * sign * sidePush * dt;
    c.vx += -ux * ATTACK_SPREAD_STRENGTH * 0.25 * dt;
    c.vy += -uy * ATTACK_SPREAD_STRENGTH * 0.25 * dt;
  }
}

function applyPelletMagnet(p: Player, dt: number): void {
  if (p.dead) return;
  for (const c of p.cells) {
    pelletGrid.queryEach(c.x, c.y, 100, (pe) => {
      const dx = pe.x - c.x, dy = pe.y - c.y;
      const d = Math.hypot(dx, dy);
      if (d < 100 && d > 1) {
        const strength = (1.0 - d / 100) * 150.0;
        c.vx += (dx / d) * strength * dt;
        c.vy += (dy / d) * strength * dt;
      }
    });
  }
}

function integrateCells(p: Player, dt: number): void {
  const damping = Math.exp(-DAMPING_PER_SECOND * dt);
  const splitFric = Math.pow(SPLIT_FRICTION_PER_FRAME, dt * 60);
  for (const c of p.cells) {
    if (Math.hypot(c.spX, c.spY) >= 1) {
      c.x += c.spX * dt; c.y += c.spY * dt;
      c.spX *= splitFric; c.spY *= splitFric;
      if (Math.hypot(c.spX, c.spY) < 1) { c.spX = 0; c.spY = 0; }
    }
    c.vx *= damping; c.vy *= damping;
    const r = radius(c.mass);
    const maxV = maxSpeedForRadius(r);
    const vMag = Math.hypot(c.vx, c.vy);
    if (vMag > maxV) { c.vx = c.vx * (maxV / vMag); c.vy = c.vy * (maxV / vMag); }
    c.x += c.vx * dt; c.y += c.vy * dt;
    if (c.mass > DECAY_THRESHOLD) {
      const nm = c.mass * Math.pow(1 - MASS_DECAY_RATE, dt);
      c.mass = nm < DECAY_THRESHOLD ? DECAY_THRESHOLD : nm;
    }
    const inset = r * 0.75;
    const atLeft = c.x <= inset;
    const atRight = c.x >= WORLD_SIZE - inset;
    const atTop = c.y <= inset;
    const atBottom = c.y >= WORLD_SIZE - inset;
    if ((atLeft && c.vx < 0) || (atRight && c.vx > 0)) c.vx = 0;
    if ((atTop && c.vy < 0) || (atBottom && c.vy > 0)) c.vy = 0;
    c.x = clamp(c.x, inset, WORLD_SIZE - inset);
    c.y = clamp(c.y, inset, WORLD_SIZE - inset);
  }
}

function updateLastDir(p: Player): void {
  const mag = Math.hypot(p.input.dx, p.input.dy);
  if (mag > 0.05) {
    p.input.lastDir.x = p.input.dx / mag;
    p.input.lastDir.y = p.input.dy / mag;
  }
}

// ─────────────────────────────────────────────────────── viruses
function updateViruses(dt: number): void {
  const fric = Math.pow(0.96, dt * 60);
  for (const v of viruses.values()) {
    if (Math.hypot(v.vx, v.vy) > 1) {
      v.x += v.vx * dt; v.y += v.vy * dt;
      v.vx *= fric; v.vy *= fric;
    }
    const r = radius(v.mass);
    const inset = r * 0.5;
    v.x = clamp(v.x, inset, WORLD_SIZE - inset);
    v.y = clamp(v.y, inset, WORLD_SIZE - inset);
  }
}

// ─────────────────────────────────────────────────────── eject
// `burstIdx` and `burstCount` describe this piece's position inside a
// multi-piece burst (high feedSpeedMultiplier). They drive a deterministic
// per-index angular spread that matches the client EjectHandler's spread
// when `deterministic` is on — both sides end up with identical piece
// paths even though there's no shared RNG.
function tryDoEject(
  p: Player,
  dirX: number,
  dirY: number,
  burstIdx: number = 0,
  burstCount: number = 1,
): void {
  if (p.dead) return;
  const m = Math.hypot(dirX, dirY);
  const ux = m > 0.05 ? dirX / m : p.input.lastDir.x;
  const uy = m > 0.05 ? dirY / m : p.input.lastDir.y;
  const er = radius(EJECT_MASS);
  const speedMult = p.ejectSpeedMult > 0 ? p.ejectSpeedMult : 1.0;
  const distMult = p.ejectDistMult > 0 ? p.ejectDistMult : 1.0;
  const derivedFric = clamp(
    1 - (1 - EJECT_FRICTION_PER_FRAME) * speedMult / distMult,
    0.01,
    0.99,
  );
  // Deterministic spread matching the client EjectHandler: half-degree-per-
  // index fan, centered on the aim direction. For burst=1 the offset is 0,
  // so single-piece feed flies in a perfectly straight line.
  const centeredIdx = burstIdx - (burstCount - 1) / 2;
  const spreadAng = centeredIdx * 4 * Math.PI / 180;
  const csA = Math.cos(spreadAng), snA = Math.sin(spreadAng);
  for (const c of p.cells) {
    if (c.mass < EJECT_MIN_MASS) continue;
    c.mass -= EJECT_COST;
    const fx = ux * csA - uy * snA;
    const fy = ux * snA + uy * csA;
    const cr = radius(c.mass);
    let lx = c.x + fx * (cr + er + LAUNCH_OFFSET);
    let ly = c.y + fy * (cr + er + LAUNCH_OFFSET);
    for (let iter = 0; iter < 30; iter++) {
      let blocked = false;
      for (const other of p.cells) {
        if (other === c) continue;
        const dx = lx - other.x, dy = ly - other.y;
        const minD = radius(other.mass) + er + PROJECTILE_SPAWN_CLEARANCE;
        if (dx * dx + dy * dy < minD * minD) { blocked = true; break; }
      }
      if (!blocked) break;
      lx += fx * 3; ly += fy * 3;
    }
    const id = newId("e");
    ejected.set(id, {
      id, ownerId: p.id, x: lx, y: ly,
      vx: fx * EJECT_VELOCITY_INITIAL * speedMult,
      vy: fy * EJECT_VELOCITY_INITIAL * speedMult,
      color: c.color, spawnedAt: Date.now(),
      fric: derivedFric,
    });
  }
}

function updateEjected(dt: number): void {
  if (ejected.size === 0) return;
  const er = radius(EJECT_MASS);
  const dt60 = dt * 60;
  for (const e of ejected.values()) {
    if (e.vx === 0 && e.vy === 0) continue;
    // Feed magnet — pulls pieces toward nearby cells. Range scales with
    // the cell's radius so even massive cells (dev start mass,
    // late-game splits) can recover the feed they shoot from their
    // edge. Mirrors the client EjectHandler magnet so server and client
    // agree on where each piece ends up.
    let magVx = 0, magVy = 0;
    cellGrid.queryEach(e.x, e.y, 1200, (c) => {
      const cr = radius(c.mass);
      const magnetRange = Math.max(150, cr + 300);
      const dx = c.x - e.x, dy = c.y - e.y;
      const d = Math.hypot(dx, dy);
      if (d < 10 || d > magnetRange) return;
      const strength = (1 - d / magnetRange) * 800;
      magVx += (dx / d) * strength;
      magVy += (dy / d) * strength;
    });
    e.vx += magVx * dt;
    e.vy += magVy * dt;
    // Per-piece friction so each owner's pieces honour that owner's
    // ejectSpeedMult / ejectDistMult tuning. The math matches the
    // client EjectHandler.update exactly.
    const fric = Math.pow(e.fric || EJECT_FRICTION_PER_FRAME, dt60);
    e.x += e.vx * dt; e.y += e.vy * dt;
    e.vx *= fric; e.vy *= fric;
    if (Math.hypot(e.vx, e.vy) < 1) { e.vx = 0; e.vy = 0; }
    if (e.x < er) { e.x = er; e.vx = 0; }
    else if (e.x > WORLD_SIZE - er) { e.x = WORLD_SIZE - er; e.vx = 0; }
    if (e.y < er) { e.y = er; e.vy = 0; }
    else if (e.y > WORLD_SIZE - er) { e.y = WORLD_SIZE - er; e.vy = 0; }
  }
}

// ─────────────────────────────────────────────────────── split
function tryDoSplit(p: Player, dirX: number, dirY: number): void {
  if (p.dead) return;
  const m = Math.hypot(dirX, dirY);
  const ux = m > 0.05 ? dirX / m : p.input.lastDir.x;
  const uy = m > 0.05 ? dirY / m : p.input.lastDir.y;
  const now = Date.now();
  const candidates = [...p.cells].sort((a, b) => b.mass - a.mass);
  for (const source of candidates) {
    if (p.cells.length >= MAX_CELLS_PER_PLAYER) break;
    if (source.mass < SPLIT_MIN_MASS) continue;
    const newMass = source.mass / 2;
    source.mass = newMass;
    const sR = radius(source.mass);
    const cd = mergeCooldownMsForRadius(sR);
    source.mergeReadyAt = now + cd;
    source.freshSplit = true;
    const radiusScale = clamp(Math.pow(sR / REFERENCE_RADIUS, 0.5), 1.0, 5.0);
    const id = newId("c");
    p.cells.push({
      id, ownerId: p.id, x: source.x, y: source.y,
      vx: 0, vy: 0,
      spX: ux * SPLIT_IMPULSE_INITIAL * radiusScale,
      spY: uy * SPLIT_IMPULSE_INITIAL * radiusScale,
      mass: newMass, color: source.color,
      freshSplit: true, mergeReadyAt: now + cd,
    });
  }
}

// ─────────────────────────────────────────────────────── collisions (grid-based)
function resolveEatPellets(): void {
  // Collect pellets to remove and apply mass after the queryEach pass to
  // avoid mutating a bucket while iterating it.
  const eaten: Pellet[] = [];
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const c of p.cells) {
      const r = radius(c.mass);
      const r2 = r * r;
      pelletGrid.queryEach(c.x, c.y, r, (pe) => {
        const dx = pe.x - c.x, dy = pe.y - c.y;
        if (dx * dx + dy * dy < r2) {
          if (c.mass < MAX_CELL_MASS) c.mass += PELLET_MASS;
          eaten.push(pe);
        }
      });
    }
  }
  for (const pe of eaten) removePellet(pe);
}

function resolveEatEjected(): void {
  if (ejected.size === 0) return;
  const now = Date.now();
  const er = radius(EJECT_MASS);
  const toRemove: string[] = [];
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const c of p.cells) {
      if (c.mass < 22) continue;
      const r = radius(c.mass);
      const eatR = r - er * 0.4;
      ejectedGrid.queryEach(c.x, c.y, r + er, (e) => {
        if (e.ownerId === c.ownerId && now - e.spawnedAt < EJECT_OWNER_IMMUNITY_MS) return;
        const dx = e.x - c.x, dy = e.y - c.y;
        if (dx * dx + dy * dy < eatR * eatR) {
          if (c.mass < MAX_CELL_MASS) c.mass += EJECT_CONSUMED_MASS;
          toRemove.push(e.id);
        }
      });
    }
  }
  for (const id of toRemove) ejected.delete(id);
}

function resolveEjectedFeedsVirus(): void {
  if (ejected.size === 0) return;
  for (const [eId, e] of ejected) {
    let popped = false;
    virusGrid.queryEach(e.x, e.y, 100, (v) => {
      if (popped) return;
      const dx = e.x - v.x, dy = e.y - v.y;
      const d = Math.hypot(dx, dy);
      if (d < radius(v.mass) + radius(EJECT_MASS) * 0.5) {
        v.mass += EJECT_MASS;
        v.feedCount++;
        const m = Math.hypot(e.vx, e.vy);
        if (m > 0) { v.lfX = e.vx / m; v.lfY = e.vy / m; }
        ejected.delete(eId);
        popped = true;
        if (v.mass >= 200) {
          v.feedCount = 0;
          v.mass = VIRUS_MASS;
          const dx0 = v.lfX === 0 && v.lfY === 0 ? 1 : v.lfX;
          const dy0 = v.lfX === 0 && v.lfY === 0 ? 0 : v.lfY;
          const id = newId("v");
          viruses.set(id, {
            id, x: v.x + dx0 * (radius(v.mass) + 30),
            y: v.y + dy0 * (radius(v.mass) + 30),
            vx: dx0 * VIRUS_SHOT_INITIAL, vy: dy0 * VIRUS_SHOT_INITIAL,
            mass: VIRUS_MASS, feedCount: 0, lfX: 0, lfY: 0,
          });
        }
      }
    });
  }
}

function resolveCellVsCell(): void {
  const dead = new Set<Cell>();
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const a of p.cells) {
      if (dead.has(a)) continue;
      const ar = radius(a.mass);
      cellGrid.queryEach(a.x, a.y, ar + 50, (b) => {
        if (a === b || dead.has(b)) return;
        if (a.ownerId === b.ownerId) return;
        if (a.mass <= b.mass) return;
        const ratio = a.freshSplit ? EAT_RATIO_FRESH_SPLIT : EAT_RATIO_WHOLE;
        if (a.mass < b.mass * ratio) return;
        const br = radius(b.mass);
        const eatR = ar - br * 0.4;
        const dx = b.x - a.x, dy = b.y - a.y;
        if (dx * dx + dy * dy < eatR * eatR) {
          if (a.mass < MAX_CELL_MASS) a.mass = Math.min(MAX_CELL_MASS, a.mass + b.mass);
          dead.add(b);
          const eater = players.get(a.ownerId);
          if (eater) eater.eatenCount++;
        }
      });
    }
  }
  if (dead.size === 0) return;
  for (const p of players.values()) {
    if (p.cells.length === 0) continue;
    p.cells = p.cells.filter(c => !dead.has(c));
    if (p.cells.length === 0 && !p.dead) { p.dead = true; p.deadAt = Date.now(); }
  }
}

function resolveCellVsVirus(): void {
  const consumed = new Set<string>();
  for (const p of players.values()) {
    if (p.dead) continue;
    for (const c of p.cells.slice()) {
      const cr = radius(c.mass);
      virusGrid.queryEach(c.x, c.y, cr + 50, (v) => {
        if (consumed.has(v.id)) return;
        const vr = radius(v.mass);
        if (cr <= vr * 1.15) return;
        const trigger = cr + vr * 0.2;
        const dx = v.x - c.x, dy = v.y - c.y;
        if (dx * dx + dy * dy < trigger * trigger) {
          consumed.add(v.id);
          popVirus(p, c, v);
        }
      });
    }
  }
  for (const id of consumed) viruses.delete(id);
}

function popVirus(p: Player, eater: Cell, _v: Virus): void {
  const now = Date.now();
  if (p.cells.length >= MAX_CELLS_PER_PLAYER) {
    eater.mass = Math.min(MAX_CELL_MASS, eater.mass + VIRUS_MASS);
    return;
  }
  const available = MAX_CELLS_PER_PLAYER - p.cells.length;
  const totMass = eater.mass + VIRUS_MASS;
  const desired = totMass > 350 ? 16 : 8 + Math.floor(Math.random() * 5);
  const n = Math.min(Math.max(2, Math.min(desired, available + 1)), 16);
  const masses: number[] = [];
  if (totMass > 350) {
    let remaining = totMass;
    const main = totMass * (0.45 + Math.random() * 0.1);
    masses.push(main); remaining -= main;
    const medCount = 2 + Math.floor(Math.random() * 2);
    for (let i = 0; i < medCount && masses.length < n; i++) {
      const mm = totMass * (0.08 + Math.random() * 0.04);
      masses.push(mm); remaining -= mm;
    }
    const small = n - masses.length;
    if (small > 0) {
      const sm = remaining / small;
      for (let i = 0; i < small; i++) masses.push(sm);
    } else masses[0] += remaining;
  } else {
    const each = totMass / n;
    for (let i = 0; i < n; i++) masses.push(each);
  }
  eater.mass = masses[0];
  const er = radius(eater.mass);
  eater.mergeReadyAt = now + mergeCooldownMsForRadius(er);
  eater.freshSplit = true;
  const base = Math.random() * Math.PI * 2;
  for (let i = 1; i < masses.length; i++) {
    const ang = base + (i / n) * 2 * Math.PI + (Math.random() - 0.5) * 0.3;
    const dx = Math.cos(ang), dy = Math.sin(ang);
    const m = masses[i];
    const r = radius(m);
    const radiusScale = clamp(Math.pow(er / REFERENCE_RADIUS, 0.35), 1.0, 2.5);
    p.cells.push({
      id: newId("c"), ownerId: p.id,
      x: eater.x, y: eater.y, vx: 0, vy: 0,
      spX: dx * SPLIT_IMPULSE_INITIAL * radiusScale,
      spY: dy * SPLIT_IMPULSE_INITIAL * radiusScale,
      mass: m, color: eater.color,
      freshSplit: true, mergeReadyAt: now + mergeCooldownMsForRadius(r),
    });
  }
}

// ─────────────────────────────────────────────────────── merge
function processMerges(p: Player): void {
  const now = Date.now();
  for (const c of p.cells) if (c.freshSplit && now >= c.mergeReadyAt) c.freshSplit = false;
  if (p.cells.length < 2) return;
  for (let i = 0; i < p.cells.length; i++) {
    for (let j = i + 1; j < p.cells.length; j++) {
      const a = p.cells[i], b = p.cells[j];
      if (now < a.mergeReadyAt || now < b.mergeReadyAt) continue;
      const ar = radius(a.mass), br = radius(b.mass);
      const dx = a.x - b.x, dy = a.y - b.y;
      const d = Math.hypot(dx, dy);
      if (d >= (ar + br) * MERGE_DISTANCE_FACTOR) continue;
      const keeper = a.mass >= b.mass ? a : b;
      const consumed = keeper === a ? b : a;
      const idx = keeper === a ? j : i;
      const total = keeper.mass + consumed.mass;
      keeper.x = (keeper.x * keeper.mass + consumed.x * consumed.mass) / total;
      keeper.y = (keeper.y * keeper.mass + consumed.y * consumed.mass) / total;
      keeper.vx = (keeper.vx * keeper.mass + consumed.vx * consumed.mass) / total;
      keeper.vy = (keeper.vy * keeper.mass + consumed.vy * consumed.mass) / total;
      keeper.mass = total;
      keeper.freshSplit = false;
      p.cells.splice(idx, 1);
      return processMerges(p);
    }
  }
}

// ─────────────────────────────────────────────────────── refill
function refillWorld(): void {
  while (pellets.size < TARGET_PELLETS) spawnPellet();
  while (viruses.size < TARGET_VIRUSES) spawnVirus();
  const now = Date.now();
  for (const p of players.values()) {
    if (!p.isBot) continue;
    if (p.dead && now - p.deadAt >= BOT_RESPAWN_DELAY_MS) spawnCellForPlayer(p);
  }
  let aliveBots = 0;
  for (const p of players.values()) if (p.isBot && !p.dead) aliveBots++;
  if (aliveBots < TARGET_BOTS) {
    const b = makeBot();
    players.set(b.id, b);
  }
}

// ─────────────────────────────────────────────────────── leaderboard
interface LBEntry { id: string; name: string; mass: number; isHuman: boolean; }
function buildLeaderboard(): LBEntry[] {
  const list: LBEntry[] = [];
  for (const p of players.values()) {
    if (p.dead) continue;
    const m = totalMass(p);
    if (m <= 0) continue;
    list.push({ id: p.id, name: p.name, mass: Math.round(m), isHuman: !p.isBot });
  }
  list.sort((a, b) => b.mass - a.mass);
  return list.slice(0, LEADERBOARD_SIZE);
}

// ─────────────────────────────────────────────────────── snapshot
function buildSnapshot(p: Player, lb: LBEntry[], sendSlow: boolean): unknown {
  const com = centerOfMass(p);
  const sendRadius2 =
    VIEWPORT_RADIUS * VIEWPORT_RADIUS * VIEWPORT_SEND_MULT * VIEWPORT_SEND_MULT;
  const now = Date.now();

  const currentCells = new Set<string>();
  const addCells: unknown[] = [];
  const updCells: unknown[] = [];
  const posEps = UPDATE_POS_EPSILON;
  const massEps = UPDATE_MASS_EPSILON;
  for (const other of players.values()) {
    if (other.dead) continue;
    for (const c of other.cells) {
      const dx = c.x - com.x, dy = c.y - com.y;
      if (dx * dx + dy * dy > sendRadius2) continue;
      currentCells.add(c.id);
      const cx = Math.round(c.x * 10) / 10;
      const cy = Math.round(c.y * 10) / 10;
      const cm = Math.round(c.mass * 10) / 10;
      if (!p.seenCells.has(c.id)) {
        addCells.push({
          id: c.id, x: cx, y: cy, m: cm,
          o: other.id, n: other.name, col: c.color, sk: other.skinId,
          h: other.isBot ? 0 : 1, s: c.freshSplit ? 1 : 0, mr: c.mergeReadyAt,
        });
        p.seenCells.add(c.id);
        p.lastSent.set(c.id, [cx, cy, cm]);
      } else {
        // Skip ONLY for cells that are truly idle (no velocity, no split
        // impulse). Moving cells must keep their full 30 Hz update stream
        // so the client interp span stays at one server tick (~33 ms) —
        // otherwise the cell visibly "ticks forward" every 100 ms instead
        // of flowing smoothly.
        const speed2 = c.vx * c.vx + c.vy * c.vy;
        const splitSpeed2 = c.spX * c.spX + c.spY * c.spY;
        const truelyIdle = speed2 < 1 && splitSpeed2 < 1;
        const last = p.lastSent.get(c.id);
        const moved = !truelyIdle ||
          last === undefined ||
          Math.abs(cx - last[0]) >= posEps ||
          Math.abs(cy - last[1]) >= posEps ||
          Math.abs(cm - last[2]) >= massEps ||
          c.freshSplit;
        if (moved) {
          updCells.push({ id: c.id, x: cx, y: cy, m: cm, s: c.freshSplit ? 1 : 0 });
          p.lastSent.set(c.id, [cx, cy, cm]);
        }
      }
    }
  }
  const rmCells: string[] = [];
  for (const id of p.seenCells) {
    if (!currentCells.has(id)) {
      rmCells.push(id);
      p.seenCells.delete(id);
      p.lastSent.delete(id);
    }
  }

  const addPellets: unknown[] = [];
  if (sendSlow) {
    pelletGrid.queryEach(com.x, com.y, VIEWPORT_RADIUS, (pe) => {
      if (p.seenPellets.has(pe.id)) return;
      addPellets.push({ id: pe.id, x: Math.round(pe.x), y: Math.round(pe.y), c: pe.color });
      p.seenPellets.add(pe.id);
    });
  }
  const rmPellets: string[] = [];
  for (const id of p.seenPellets) if (!pellets.has(id)) { rmPellets.push(id); p.seenPellets.delete(id); }

  const addViruses: unknown[] = [];
  const updViruses: unknown[] = [];
  const currentViruses = new Set<string>();
  for (const v of viruses.values()) {
    const dx = v.x - com.x, dy = v.y - com.y;
    if (dx * dx + dy * dy > sendRadius2) continue;
    currentViruses.add(v.id);
    const vx = Math.round(v.x * 10) / 10;
    const vy = Math.round(v.y * 10) / 10;
    const vm = Math.round(v.mass);
    if (!p.seenViruses.has(v.id)) {
      addViruses.push({ id: v.id, x: vx, y: vy, m: vm });
      p.seenViruses.add(v.id);
      p.lastSentVirus.set(v.id, [vx, vy, vm]);
    } else {
      const last = p.lastSentVirus.get(v.id);
      // A virus that's just been "shot" by repeated feed has high vx/vy and
      // must keep streaming every tick; an idle virus rarely sends.
      const virusMoving = (v.vx * v.vx + v.vy * v.vy) > 1;
      const moved = virusMoving ||
        last === undefined ||
        Math.abs(vx - last[0]) >= posEps ||
        Math.abs(vy - last[1]) >= posEps ||
        Math.abs(vm - last[2]) >= 1;
      if (moved) {
        updViruses.push({ id: v.id, x: vx, y: vy, m: vm });
        p.lastSentVirus.set(v.id, [vx, vy, vm]);
      }
    }
  }
  const rmViruses: string[] = [];
  for (const id of p.seenViruses) {
    if (!currentViruses.has(id)) {
      rmViruses.push(id);
      p.seenViruses.delete(id);
      p.lastSentVirus.delete(id);
    }
  }

  const addEjected: unknown[] = [];
  const updEjected: unknown[] = [];
  const currentEjected = new Set<string>();
  for (const e of ejected.values()) {
    const dx = e.x - com.x, dy = e.y - com.y;
    if (dx * dx + dy * dy > sendRadius2) continue;
    currentEjected.add(e.id);
    const ex = Math.round(e.x * 10) / 10;
    const ey = Math.round(e.y * 10) / 10;
    if (!p.seenEjected.has(e.id)) {
      addEjected.push({ id: e.id, x: ex, y: ey, c: e.color, o: e.ownerId });
      p.seenEjected.add(e.id);
      p.lastSentEjected.set(e.id, [ex, ey]);
    } else {
      const last = p.lastSentEjected.get(e.id);
      const ejectedMoving = (e.vx * e.vx + e.vy * e.vy) > 1;
      const moved = ejectedMoving ||
        last === undefined ||
        Math.abs(ex - last[0]) >= posEps ||
        Math.abs(ey - last[1]) >= posEps;
      if (moved) {
        updEjected.push({ id: e.id, x: ex, y: ey });
        p.lastSentEjected.set(e.id, [ex, ey]);
      }
    }
  }
  const rmEjected: string[] = [];
  for (const id of p.seenEjected) {
    if (!currentEjected.has(id)) {
      rmEjected.push(id);
      p.seenEjected.delete(id);
      p.lastSentEjected.delete(id);
    }
  }

  return {
    type: "state",
    t: serverTick,
    now,
    ack: p.lastInputSeq,
    self: {
      id: p.id, dead: p.dead,
      cm: { x: Math.round(com.x * 10) / 10, y: Math.round(com.y * 10) / 10 },
      mass: Math.round(totalMass(p)),
      kills: p.eatenCount,
      highestMass: Math.round(p.highestMass),
    },
    addCells, updCells, rmCells,
    addPellets, rmPellets,
    addViruses, updViruses, rmViruses,
    addEjected, updEjected, rmEjected,
    leaderboard: lb,
    online: [...players.values()].filter(q => !q.isBot).length,
  };
}

function safeSend(ws: uWS.WebSocket<SocketData>, obj: unknown): void {
  try { ws.send(JSON.stringify(obj)); } catch { /* closed */ }
}

function sendSnapshotTo(p: Player, lb: LBEntry[], sendSlow: boolean): void {
  if (p.isBot || !p.socket) return;
  let snap: unknown;
  try { snap = buildSnapshot(p, lb, sendSlow); } catch { return; }
  const sock = p.socket;
  setImmediate(() => {
    try { sock.send(JSON.stringify(snap)); } catch { /* closed */ }
  });
}

// ─────────────────────────────────────────────────────── main loop
let slowTickCount = 0;
let slowTickReportAt = Date.now() + 5000;

setInterval(() => {
  const tickStart = performance.now();
  const now = Date.now();
  let dt = (now - lastNowMs) / 1000;
  if (dt < 0) dt = 0;
  if (dt > 0.1) dt = 0.1;
  lastNowMs = now;
  serverTick++;

  // 1. Bot AI (uses last tick's grids — staleness of 33ms is irrelevant).
  for (const p of players.values()) {
    if (!p.isBot || p.dead) continue;
    botDecide(p, now);
    botDecideSplit(p, now);
    botDecideEject(p, now);
  }

  // 2. Physics for every player.
  for (const p of players.values()) {
    if (p.dead) continue;
    updateLastDir(p);
    applyInputForce(p, dt);
    applyCohesion(p, dt);
    applySeparation(p, dt);
    applyAttackSpread(p, dt);
    applyPelletMagnet(p, dt);
    integrateCells(p, dt);
  }
  updateViruses(dt);
  updateEjected(dt);

  // 3. Rebuild grids with updated positions for collision broadphase.
  rebuildMovingGrids();

  // 4. Resolve collisions (all grid-accelerated).
  resolveEatPellets();
  resolveEatEjected();
  resolveEjectedFeedsVirus();
  resolveCellVsCell();
  resolveCellVsVirus();

  // 5. Merge cells that satisfied cooldown + proximity.
  for (const p of players.values()) processMerges(p);

  // 6. Repopulate world (pellets, viruses, bots).
  refillWorld();

  // 7. Track player records.
  for (const p of players.values()) {
    if (p.dead) continue;
    const m = totalMass(p);
    if (m > p.highestMass) p.highestMass = m;
  }

  // 8. Send snapshots to all humans.
  const lb = buildLeaderboard();
  const sendSlow = serverTick % SLOW_TICK_EVERY === 0;
  for (const p of players.values()) {
    if (!p.isBot) sendSnapshotTo(p, lb, sendSlow);
  }

  // 9. Drop stale humans.
  for (const [id, p] of players) {
    if (p.isBot) continue;
    if (now - p.lastSeenAt > STALE_PLAYER_MS) {
      try { p.socket?.close(); } catch { /* already closed */ }
      p.socket = null;
      players.delete(id);
    }
  }

  // 10. Tick budget monitor — log if we exceed 80 % of the budget.
  const tickMs = performance.now() - tickStart;
  if (tickMs > TICK_BUDGET_MS) {
    slowTickCount++;
    if (now >= slowTickReportAt) {
      console.warn(`[yazario-v4] ${slowTickCount} slow ticks in last 5s (last: ${tickMs.toFixed(1)}ms, budget: ${TICK_BUDGET_MS.toFixed(1)}ms)`);
      slowTickCount = 0;
      slowTickReportAt = now + 5000;
    }
  }
}, TICK_MS);

// ─────────────────────────────────────────────────────── uWebSockets.js server
function handleMessage(ws: uWS.WebSocket<SocketData>, message: ArrayBuffer): void {
  let msg: { type?: string; [k: string]: unknown };
  try { msg = JSON.parse(Buffer.from(message).toString("utf-8")); } catch { return; }
  const type = msg?.type;
  const data = ws.getUserData();

  if (type === "join") {
    if (data.playerId) return;
    const rawName = typeof msg.name === "string" ? msg.name : "";
    const name = rawName.trim().slice(0, 18) || "Player";
    const skinId = typeof msg.skin === "string" ? msg.skin.slice(0, 128) : "";
    const rawMult = Number(msg.massMult);
    const massMult = Number.isFinite(rawMult) ? clamp(rawMult, 0.5, 300.0) : 1.0;
    const rawEsm = Number(msg.ejectSpeedMult);
    const ejectSpeedMult = Number.isFinite(rawEsm) ? clamp(rawEsm, 0.25, 5.0) : 1.0;
    const rawEdm = Number(msg.ejectDistMult);
    const ejectDistMult = Number.isFinite(rawEdm) ? clamp(rawEdm, 0.25, 5.0) : 1.0;
    const id = newId("h");
    data.playerId = id;
    const player: Player = {
      id, socket: ws, isBot: false, name,
      color: pickPaletteColor(), skinId,
      cells: [],
      input: { dx: 0, dy: 0, attack: false, lastDir: { x: 1, y: 0 }, seq: 0 },
      dead: false, deadAt: 0, lastInputSeq: 0,
      lastSeenAt: Date.now(), spawnAt: Date.now(),
      highestMass: 5000, massMult,
      ejectSpeedMult, ejectDistMult,
      eatenCount: 0,
      aiDir: { x: 0, y: 0 }, aiNextDecide: 0, aiNextSplit: 0, aiNextEject: 0,
      seenCells: new Set(), seenPellets: new Set(),
      seenViruses: new Set(), seenEjected: new Set(),
      lastSent: new Map(), lastSentVirus: new Map(), lastSentEjected: new Map(),
    };
    spawnCellForPlayer(player);
    players.set(id, player);
    safeSend(ws, {
      type: "welcome", id,
      worldSize: WORLD_SIZE, tickRate: TICK_RATE, tickMs: TICK_MS,
      name: player.name,
    });
    return;
  }

  const player = data.playerId ? players.get(data.playerId) : undefined;
  if (!player) return;
  player.lastSeenAt = Date.now();

  if (type === "input") {
    const dx = Number(msg.dx), dy = Number(msg.dy);
    const seq = Number(msg.seq);
    const attack = !!msg.attack;
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) return;
    player.input.dx = clamp(dx, -1, 1);
    player.input.dy = clamp(dy, -1, 1);
    player.input.attack = attack;
    if (Number.isFinite(seq) && seq > player.lastInputSeq) player.lastInputSeq = seq;
  } else if (type === "split") {
    const seq = Number(msg.seq);
    if (Number.isFinite(seq) && seq > player.lastInputSeq) player.lastInputSeq = seq;
    let dx = player.input.dx, dy = player.input.dy;
    const m = Math.hypot(dx, dy);
    if (m < 0.05) { dx = player.input.lastDir.x; dy = player.input.lastDir.y; }
    tryDoSplit(player, dx, dy);
  } else if (type === "eject") {
    const seq = Number(msg.seq);
    if (Number.isFinite(seq) && seq > player.lastInputSeq) player.lastInputSeq = seq;
    let dx = player.input.dx, dy = player.input.dy;
    const m = Math.hypot(dx, dy);
    if (m < 0.05) { dx = player.input.lastDir.x; dy = player.input.lastDir.y; }
    const rawCount = Number(msg.count);
    const count = Number.isFinite(rawCount) ? Math.max(1, Math.min(30, Math.floor(rawCount))) : 1;
    for (let i = 0; i < count; i++) tryDoEject(player, dx, dy, i, count);
  } else if (type === "respawn") {
    if (player.dead) spawnCellForPlayer(player);
  } else if (type === "ping") {
    const t = Number(msg.t);
    safeSend(ws, { type: "pong", t: Number.isFinite(t) ? t : 0, now: Date.now() });
  }
}

const app = uWS.App();

app.ws<SocketData>("/*", {
  compression: uWS.DISABLED,
  maxPayloadLength: 4 * 1024,
  idleTimeout: 60,
  open: (_ws) => { /* player created on join message */ },
  message: (ws, message, _isBinary) => { handleMessage(ws, message); },
  close: (ws, _code, _message) => {
    const data = ws.getUserData();
    if (data.playerId) {
      const p = players.get(data.playerId);
      if (p) { p.socket = null; players.delete(data.playerId); }
    }
  },
  upgrade: (res, req, context) => {
    res.upgrade<SocketData>(
      { playerId: "" },
      req.getHeader("sec-websocket-key"),
      req.getHeader("sec-websocket-protocol"),
      req.getHeader("sec-websocket-extensions"),
      context,
    );
  },
});

app.get("/*", (res, _req) => {
  res.writeStatus("200 OK").writeHeader("content-type", "text/plain").end("Yazario Online Classic V4");
});

app.listen(PORT, (listenSocket) => {
  if (listenSocket) {
    console.log(`[yazario-v4] Online Classic V4 (uWS) listening on :${PORT}`);
    console.log(`[yazario-v4] tick=${TICK_RATE}Hz, budget=${TICK_BUDGET_MS.toFixed(1)}ms, bots=${TARGET_BOTS}, grid=${GRID_DIM}x${GRID_DIM}`);
  } else {
    console.error(`[yazario-v4] Failed to listen on :${PORT}`);
  }
});
