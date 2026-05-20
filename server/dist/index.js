"use strict";
/**
 * Yazario Online Classic V2 — authoritative WebSocket game server.
 *
 * Goal: behave exactly like Offline Classic so the client can mirror its
 * simulation locally for client-side prediction. Constants, speed model,
 * cohesion/separation/spread, split impulse, eject travel, merge cooldown,
 * virus pop and bot AI are all faithful ports of `lib/game/...`.
 *
 * Wire protocol (V2):
 *   client→server: {type:"join", name, skin}
 *                  {type:"input", seq, dx, dy, attack}
 *                  {type:"split", seq}
 *                  {type:"eject", seq}
 *                  {type:"respawn"}
 *                  {type:"ping", t}
 *   server→client: {type:"welcome", id, worldSize, tickRate, tickMs}
 *                  {type:"state", t, now, ack,
 *                      self:{id,dead,cm:{x,y}},
 *                      addCells:[...], updCells:[...], rmCells:[...],
 *                      addPellets:[...], rmPellets:[...],
 *                      addViruses:[...], updViruses:[...], rmViruses:[...],
 *                      addEjected:[...], updEjected:[...], rmEjected:[...],
 *                      leaderboard, online}
 *                  {type:"pong", t}
 *
 * Entity IDs are monotonically-increasing strings, never reused.
 * Run:  npx ts-node src/index.ts   (dev)
 *       npm run build && npm start (prod)
 */
Object.defineProperty(exports, "__esModule", { value: true });
const http_1 = require("http");
const ws_1 = require("ws");
// ─────────────────────────────────────────────────────── world constants
// Mirror of lib/game/game_engine.dart GameConstants.
const PORT = Number(process.env.PORT ?? 2567);
const WORLD_SIZE = 14142;
const TARGET_PELLETS = 8000;
const TARGET_VIRUSES = 30;
const TARGET_BOTS = 70;
const MAX_CELLS_PER_PLAYER = 16;
const MAX_CELL_MASS = 22500;
const SPLIT_MIN_MASS = 35;
const EJECT_MIN_MASS = 35;
const MASS_DECAY_RATE = 0.002; // 0.2 %/s above threshold
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
// Movement (impulse + damping + per-radius clamp).
const INPUT_MOVE_STRENGTH = 1200;
const DAMPING_PER_SECOND = 5.8;
// Cohesion.
const COHESION_STRENGTH = 4.5;
const COHESION_MAX_DISTANCE = 120.0;
const COHESION_COOLDOWN_FACTOR = 0.35;
// Separation.
const SEPARATION_STRENGTH = 34.0;
const MIN_GAP = 3.0;
// Attack spread.
const ATTACK_SPREAD_STRENGTH = 22.0;
const LAUNCH_OFFSET = 10.0;
const PROJECTILE_SPAWN_CLEARANCE = 6.0;
const LANE_WIDTH_BASE = 18.0;
const LANE_WIDTH_RADIUS_FACTOR = 0.72;
const LANE_FORWARD_DEPTH_FACTOR = 2.8;
// Per-radius speed clamp — values copied verbatim from
// lib/game/game_engine.dart GameConstants so server motion matches Offline
// Classic 1:1. Previously the server used 95 / 0.42 which made large cells
// ~21 % slower than Offline (visible "sluggish" feel online vs offline).
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
// Networking.
// 30 Hz is the proven sweet spot for this game. We tried 60 Hz but the
// per-tick pellet collision pass (O(players × cells × 8000 pellets)) saturated
// CPU and caused tick drops — which felt worse than the latency 30 Hz adds.
// To safely raise this, the resolveEatPellets / resolveCellVsCell loops need
// spatial hashing first; only then will the CPU budget allow 45–60 Hz.
const TICK_RATE = 30; // server simulation Hz
const TICK_MS = 1000 / TICK_RATE;
const SLOW_TICK_EVERY = 4; // 7.5 Hz pellet refresh per player
const VIEWPORT_RADIUS = 2200; // entities sent per player
const LEADERBOARD_SIZE = 10;
const STALE_PLAYER_MS = 20000;
const EJECT_OWNER_IMMUNITY_MS = 200;
// Palette (mirrors offline _palette).
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
function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
}
function radius(mass) {
    return Math.sqrt(Math.max(mass, 0) / Math.PI) * 10;
}
function rand(min, max) {
    return min + Math.random() * (max - min);
}
function pickPaletteColor() {
    return PALETTE[Math.floor(Math.random() * PALETTE.length)];
}
function maxSpeedForRadius(r) {
    const s = SPEED_SCALE_BASE *
        Math.pow(REFERENCE_RADIUS / (r < 1 ? 1 : r), SPEED_RADIUS_POWER);
    return clamp(s, MAX_LARGE_CELL_SPEED, MAX_SMALL_CELL_SPEED);
}
function mergeCooldownMsForRadius(r) {
    const secs = clamp(MERGE_COOLDOWN_BASE_S + r * MERGE_COOLDOWN_PER_RADIUS, MERGE_COOLDOWN_BASE_S, MERGE_COOLDOWN_MAX_S);
    return Math.round(secs * 1000);
}
let entitySeq = 0;
function newId(prefix) {
    return `${prefix}${++entitySeq}`;
}
// ─────────────────────────────────────────────────────── world state
const players = new Map();
const pellets = new Map();
const viruses = new Map();
const ejected = new Map();
let serverTick = 0;
let lastNowMs = Date.now();
// ─────────────────────────────────────────────────────── spawning
function randomWorldPos(margin = 200) {
    return {
        x: rand(margin, WORLD_SIZE - margin),
        y: rand(margin, WORLD_SIZE - margin),
    };
}
function safeSpawnPos(margin = 600) {
    for (let attempt = 0; attempt < 20; attempt++) {
        const p = randomWorldPos(margin);
        let safe = true;
        for (const other of players.values()) {
            if (other.dead)
                continue;
            for (const c of other.cells) {
                const dx = c.x - p.x, dy = c.y - p.y;
                if (dx * dx + dy * dy < 800 * 800) {
                    safe = false;
                    break;
                }
            }
            if (!safe)
                break;
        }
        if (safe)
            return p;
    }
    return randomWorldPos(margin);
}
function spawnPellet() {
    const p = randomWorldPos(40);
    return { id: newId("p"), x: p.x, y: p.y, color: pickPaletteColor() };
}
function spawnVirus() {
    const p = randomWorldPos(300);
    return {
        id: newId("v"),
        x: p.x,
        y: p.y,
        vx: 0,
        vy: 0,
        mass: VIRUS_MASS,
        feedCount: 0,
        lfX: 0,
        lfY: 0,
    };
}
function spawnCellForPlayer(p) {
    const pos = safeSpawnPos();
    const startMass = p.isBot ? 100 : 76;
    p.cells = [{
            id: newId("c"),
            ownerId: p.id,
            x: pos.x,
            y: pos.y,
            vx: 0,
            vy: 0,
            spX: 0,
            spY: 0,
            mass: startMass,
            color: p.color,
            freshSplit: false,
            mergeReadyAt: Date.now(),
        }];
    p.dead = false;
    p.deadAt = 0;
    p.spawnAt = Date.now();
    p.highestMass = startMass;
    p.input.dx = 0;
    p.input.dy = 0;
    p.input.attack = false;
}
function makeBot() {
    const id = newId("bot");
    const bot = {
        id,
        socket: null,
        isBot: true,
        name: BOT_NAMES[Math.floor(Math.random() * BOT_NAMES.length)],
        color: pickPaletteColor(),
        skinId: `bot_${id}`,
        cells: [],
        input: { dx: 0, dy: 0, attack: false, lastDir: { x: 1, y: 0 }, seq: 0 },
        dead: false,
        deadAt: 0,
        lastInputSeq: 0,
        lastSeenAt: Date.now(),
        spawnAt: Date.now(),
        highestMass: 100,
        aiDir: { x: 0, y: 0 },
        aiNextDecide: 0,
        aiNextSplit: 0,
        aiNextEject: 0,
        seenCells: new Set(),
        seenPellets: new Set(),
        seenViruses: new Set(),
        seenEjected: new Set(),
    };
    spawnCellForPlayer(bot);
    return bot;
}
// init world
for (let i = 0; i < TARGET_PELLETS; i++) {
    const p = spawnPellet();
    pellets.set(p.id, p);
}
for (let i = 0; i < TARGET_VIRUSES; i++) {
    const v = spawnVirus();
    viruses.set(v.id, v);
}
for (let i = 0; i < TARGET_BOTS; i++) {
    const b = makeBot();
    players.set(b.id, b);
}
// ─────────────────────────────────────────────────────── centre of mass
function centerOfMass(p) {
    if (p.cells.length === 0)
        return { x: WORLD_SIZE / 2, y: WORLD_SIZE / 2 };
    let cx = 0, cy = 0, tm = 0;
    for (const c of p.cells) {
        cx += c.x * c.mass;
        cy += c.y * c.mass;
        tm += c.mass;
    }
    if (tm <= 0)
        return { x: p.cells[0].x, y: p.cells[0].y };
    return { x: cx / tm, y: cy / tm };
}
function totalMass(p) {
    let m = 0;
    for (const c of p.cells)
        m += c.mass;
    return m;
}
// ─────────────────────────────────────────────────────── bot AI
function botDecide(p, now) {
    if (p.dead)
        return;
    if (now < p.aiNextDecide)
        return;
    p.aiNextDecide = now + BOT_DECIDE_CADENCE_MS + Math.random() * 250;
    const c = centerOfMass(p);
    const myMass = totalMass(p);
    if (myMass <= 0)
        return;
    let threatX = 0, threatY = 0, threatW = 0;
    let preyX = c.x, preyY = c.y, preyDist = Infinity;
    for (const other of players.values()) {
        if (other.id === p.id || other.dead)
            continue;
        for (const oc of other.cells) {
            const dx = oc.x - c.x, dy = oc.y - c.y;
            const d2 = dx * dx + dy * dy;
            if (d2 > BOT_SCAN_RADIUS * BOT_SCAN_RADIUS)
                continue;
            const d = Math.sqrt(d2);
            if (oc.mass > myMass * EAT_RATIO_WHOLE && d < 750) {
                const w = 1 - d / 750;
                threatX += (c.x - oc.x) * w;
                threatY += (c.y - oc.y) * w;
                threatW += w;
            }
            else if (myMass > oc.mass * EAT_RATIO_WHOLE && d < preyDist) {
                preyX = oc.x;
                preyY = oc.y;
                preyDist = d;
            }
        }
    }
    // Virus avoidance for big bots.
    if (myMass > 130 && p.cells.length < MAX_CELLS_PER_PLAYER) {
        for (const v of viruses.values()) {
            const dx = v.x - c.x, dy = v.y - c.y;
            const d = Math.hypot(dx, dy);
            if (d > 0 && d < BOT_VIRUS_AVOIDANCE) {
                const w = (1 - d / BOT_VIRUS_AVOIDANCE) * 0.7;
                threatX += (c.x - v.x) * w;
                threatY += (c.y - v.y) * w;
                threatW += w;
            }
        }
    }
    let tx, ty;
    if (threatW > 0.3) {
        tx = c.x + threatX;
        ty = c.y + threatY;
    }
    else if (isFinite(preyDist)) {
        tx = preyX;
        ty = preyY;
    }
    else {
        // chase nearest pellet
        let bd = BOT_PELLET_SCAN * BOT_PELLET_SCAN;
        let best = null;
        for (const pe of pellets.values()) {
            const dx = pe.x - c.x, dy = pe.y - c.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < bd) {
                bd = d2;
                best = pe;
            }
        }
        if (best) {
            tx = best.x;
            ty = best.y;
        }
        else {
            tx = c.x + rand(-300, 300);
            ty = c.y + rand(-300, 300);
        }
    }
    // Edge steering.
    const margin = 400;
    if (c.x < margin)
        tx += 400;
    if (c.x > WORLD_SIZE - margin)
        tx -= 400;
    if (c.y < margin)
        ty += 400;
    if (c.y > WORLD_SIZE - margin)
        ty -= 400;
    const dx = tx - c.x, dy = ty - c.y;
    const m = Math.hypot(dx, dy);
    if (m > 0.5) {
        p.aiDir.x = dx / m;
        p.aiDir.y = dy / m;
    }
    else {
        p.aiDir.x = 0;
        p.aiDir.y = 0;
    }
}
function botDecideSplit(p, now) {
    if (p.dead)
        return;
    if (now < p.aiNextSplit)
        return;
    if (p.cells.length >= 6) {
        p.aiNextSplit = now + 1500;
        return;
    }
    const myMass = totalMass(p);
    if (myMass < 60) {
        p.aiNextSplit = now + 800;
        return;
    }
    const c = centerOfMass(p);
    const myR = radius(myMass);
    for (const other of players.values()) {
        if (other.id === p.id || other.dead)
            continue;
        for (const oc of other.cells) {
            const dx = oc.x - c.x, dy = oc.y - c.y;
            const d = Math.hypot(dx, dy);
            if (myMass > oc.mass * 1.3 && d > myR * 1.1 && d < myR * 2.8) {
                tryDoSplit(p, p.aiDir.x, p.aiDir.y);
                p.aiNextSplit = now + 3000 + Math.random() * 5000;
                return;
            }
        }
    }
    p.aiNextSplit = now + 900;
}
function botDecideEject(p, now) {
    if (p.dead)
        return;
    if (now < p.aiNextEject)
        return;
    const myMass = totalMass(p);
    if (myMass < 140) {
        p.aiNextEject = now + 800;
        return;
    }
    const c = centerOfMass(p);
    let bigEnemy = false;
    for (const other of players.values()) {
        if (other.id === p.id || other.dead)
            continue;
        for (const oc of other.cells) {
            const dx = oc.x - c.x, dy = oc.y - c.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < 600 * 600 && oc.mass > myMass * 1.4) {
                bigEnemy = true;
                break;
            }
        }
        if (bigEnemy)
            break;
    }
    if (!bigEnemy) {
        p.aiNextEject = now + 600;
        return;
    }
    for (const v of viruses.values()) {
        const dx = v.x - c.x, dy = v.y - c.y;
        const d = Math.hypot(dx, dy);
        if (d < 20 || d > 450)
            continue;
        const ax = dx / d, ay = dy / d;
        const aligned = ax * p.aiDir.x + ay * p.aiDir.y;
        if (aligned > 0.45) {
            tryDoEject(p, p.aiDir.x, p.aiDir.y);
            p.aiNextEject = now + 1500 + Math.random() * 2000;
            return;
        }
    }
    p.aiNextEject = now + 700;
}
// ─────────────────────────────────────────────────────── physics
function applyInputForce(p, dt) {
    let dx, dy;
    if (p.isBot) {
        dx = p.aiDir.x;
        dy = p.aiDir.y;
    }
    else {
        dx = p.input.dx;
        dy = p.input.dy;
    }
    const mag = Math.hypot(dx, dy);
    if (mag < 0.05)
        return;
    // Agar.io mobile movement model — ported verbatim from
    // lib/game/game_engine.dart `_applyInputForce` so Online feels identical to
    // Offline Classic. Three pieces:
    //   1. Convergent target point at distance 1000 from CoM — every cell
    //      aims for the same world point so a multi-cell party converges.
    //   2. Acceleration = maxSpeed × damping × agility — gives heavy cells a
    //      heavier feel and light cells a snappier one (matches mobile Agar).
    //   3. Agility = pow(150/(m+50), 0.15) clamped [0.7, 1.5] — smooth mass
    //      → responsiveness curve.
    // Simple-impulse version was tried and felt sluggish vs Offline.
    const intensity = mag > 1 ? 1 : mag;
    const com = centerOfMass(p);
    const tx = com.x + (dx / mag) * 1000;
    const ty = com.y + (dy / mag) * 1000;
    for (const c of p.cells) {
        const tdx = tx - c.x, tdy = ty - c.y;
        const d = Math.hypot(tdx, tdy);
        if (d < 0.1)
            continue;
        const r = radius(c.mass);
        const maxSpeed = maxSpeedForRadius(r);
        const agilityRaw = Math.pow(150 / (c.mass + 50), 0.15);
        const agility = agilityRaw < 0.7 ? 0.7 : agilityRaw > 1.5 ? 1.5 : agilityRaw;
        const accel = maxSpeed * DAMPING_PER_SECOND * agility;
        c.vx += (tdx / d) * accel * intensity * dt;
        c.vy += (tdy / d) * accel * intensity * dt;
    }
}
function applyCohesion(p, dt) {
    if (p.cells.length < 2)
        return;
    const com = centerOfMass(p);
    let maxMass = 0;
    for (const c of p.cells)
        if (c.mass > maxMass)
            maxMass = c.mass;
    const now = Date.now();
    for (const c of p.cells) {
        if (Math.hypot(c.spX, c.spY) >= 1)
            continue;
        const dx = com.x - c.x, dy = com.y - c.y;
        const d = Math.hypot(dx, dy);
        if (d === 0)
            continue;
        let factor = now >= c.mergeReadyAt ? 1.0 : COHESION_COOLDOWN_FACTOR;
        if (maxMass > 500 && c.mass < maxMass * 0.2)
            factor *= 0.3;
        const accel = COHESION_STRENGTH * Math.min(d, COHESION_MAX_DISTANCE) * factor;
        c.vx += (dx / d) * accel * dt;
        c.vy += (dy / d) * accel * dt;
    }
}
function applySeparation(p, dt) {
    const cs = p.cells;
    if (cs.length < 2)
        return;
    const now = Date.now();
    for (let i = 0; i < cs.length; i++) {
        const a = cs[i];
        for (let j = i + 1; j < cs.length; j++) {
            const b = cs[j];
            if (now >= a.mergeReadyAt && now >= b.mergeReadyAt)
                continue;
            const dx = a.x - b.x, dy = a.y - b.y;
            const d = Math.hypot(dx, dy);
            const ar = radius(a.mass), br = radius(b.mass);
            const minDist = ar + br + MIN_GAP;
            if (d >= minDist)
                continue;
            if (d === 0) {
                a.x += 0.5;
                continue;
            }
            const overlap = minDist - d;
            const nx = dx / d, ny = dy / d;
            const totMass = a.mass + b.mass;
            // Velocity force — smooth, mass-weighted push.
            const fx = nx * overlap * SEPARATION_STRENGTH;
            const fy = ny * overlap * SEPARATION_STRENGTH;
            a.vx += fx * (b.mass / totMass) * dt;
            a.vy += fy * (b.mass / totMass) * dt;
            b.vx -= fx * (a.mass / totMass) * dt;
            b.vy -= fy * (a.mass / totMass) * dt;
            // Hard position correction — ported from offline MergeHandler. Cells
            // not yet allowed to merge MUST NOT overlap (Agar.io feel). Velocity
            // alone can't outrun a fast split impulse in one tick, so we resolve
            // the overlap directly here, mass-weighted so big cells barely move.
            // Removing this caused visible "glitches when split" because the
            // client (which DOES apply this via MergeHandler) ran ahead of the
            // server, then snapped back on each snapshot.
            a.x += nx * (overlap * (b.mass / totMass));
            a.y += ny * (overlap * (b.mass / totMass));
            b.x -= nx * (overlap * (a.mass / totMass));
            b.y -= ny * (overlap * (a.mass / totMass));
        }
    }
}
function applyAttackSpread(p, dt) {
    if (!p.input.attack)
        return;
    if (p.cells.length < 2)
        return;
    const dirRaw = p.input.lastDir;
    const amag = Math.hypot(dirRaw.x, dirRaw.y);
    if (amag === 0)
        return;
    const ux = dirRaw.x / amag, uy = dirRaw.y / amag;
    const px = -uy, py = ux;
    let main = p.cells[0];
    for (const c of p.cells)
        if (c.mass > main.mass)
            main = c;
    const mR = radius(main.mass);
    const laneW = LANE_WIDTH_BASE + mR * LANE_WIDTH_RADIUS_FACTOR;
    const laneD = mR * LANE_FORWARD_DEPTH_FACTOR;
    for (const c of p.cells) {
        if (c === main)
            continue;
        if (Math.hypot(c.spX, c.spY) >= 1)
            continue;
        const rx = c.x - main.x, ry = c.y - main.y;
        const fwd = rx * ux + ry * uy;
        const side = rx * px + ry * py;
        if (fwd <= 0 || fwd >= laneD)
            continue;
        if (Math.abs(side) >= laneW)
            continue;
        let sign;
        if (Math.abs(side) < 1) {
            // deterministic bias by id
            sign = (c.id.charCodeAt(c.id.length - 1) & 1) ? 1 : -1;
        }
        else
            sign = side >= 0 ? 1 : -1;
        const sidePush = ATTACK_SPREAD_STRENGTH * (laneW - Math.abs(side));
        c.vx += px * sign * sidePush * dt;
        c.vy += py * sign * sidePush * dt;
        c.vx += -ux * ATTACK_SPREAD_STRENGTH * 0.25 * dt;
        c.vy += -uy * ATTACK_SPREAD_STRENGTH * 0.25 * dt;
    }
}
function integrateCells(p, dt) {
    const damping = Math.exp(-DAMPING_PER_SECOND * dt);
    const splitFric = Math.pow(SPLIT_FRICTION_PER_FRAME, dt * 60);
    for (const c of p.cells) {
        if (Math.hypot(c.spX, c.spY) >= 1) {
            c.x += c.spX * dt;
            c.y += c.spY * dt;
            c.spX *= splitFric;
            c.spY *= splitFric;
            if (Math.hypot(c.spX, c.spY) < 1) {
                c.spX = 0;
                c.spY = 0;
            }
        }
        c.vx *= damping;
        c.vy *= damping;
        const r = radius(c.mass);
        const maxV = maxSpeedForRadius(r);
        const vMag = Math.hypot(c.vx, c.vy);
        if (vMag > maxV) {
            c.vx = c.vx * (maxV / vMag);
            c.vy = c.vy * (maxV / vMag);
        }
        c.x += c.vx * dt;
        c.y += c.vy * dt;
        if (c.mass > DECAY_THRESHOLD) {
            const nm = c.mass * Math.pow(1 - MASS_DECAY_RATE, dt);
            c.mass = nm < DECAY_THRESHOLD ? DECAY_THRESHOLD : nm;
        }
        // NOTE: wall-sticking velocity zero-out was an experimental addition;
        // it made multi-cell parties freeze against the boundary instead of
        // sliding. Plain clamp is what the working Desktop reference uses.
        const inset = r * 0.75;
        c.x = clamp(c.x, inset, WORLD_SIZE - inset);
        c.y = clamp(c.y, inset, WORLD_SIZE - inset);
    }
}
function updateLastDir(p) {
    const mag = Math.hypot(p.input.dx, p.input.dy);
    if (mag > 0.05) {
        p.input.lastDir.x = p.input.dx / mag;
        p.input.lastDir.y = p.input.dy / mag;
    }
}
// ─────────────────────────────────────────────────────── viruses
function updateViruses(dt) {
    const fric = Math.pow(0.96, dt * 60);
    for (const v of viruses.values()) {
        if (Math.hypot(v.vx, v.vy) > 1) {
            v.x += v.vx * dt;
            v.y += v.vy * dt;
            v.vx *= fric;
            v.vy *= fric;
        }
        const r = radius(v.mass);
        const inset = r * 0.5;
        v.x = clamp(v.x, inset, WORLD_SIZE - inset);
        v.y = clamp(v.y, inset, WORLD_SIZE - inset);
    }
}
// ─────────────────────────────────────────────────────── eject
function tryDoEject(p, dirX, dirY) {
    if (p.dead)
        return;
    const m = Math.hypot(dirX, dirY);
    const ux = m > 0.05 ? dirX / m : p.input.lastDir.x;
    const uy = m > 0.05 ? dirY / m : p.input.lastDir.y;
    const er = radius(EJECT_MASS);
    for (const c of p.cells) {
        if (c.mass < EJECT_MIN_MASS)
            continue;
        c.mass -= EJECT_COST;
        // small random spread (±6°, ±5 % speed)
        const ang = (Math.random() * 12 - 6) * (Math.PI / 180);
        const cs = Math.cos(ang), sn = Math.sin(ang);
        const fx = ux * cs - uy * sn;
        const fy = ux * sn + uy * cs;
        const sv = 0.95 + Math.random() * 0.1;
        const cr = radius(c.mass);
        let lx = c.x + fx * (cr + er + LAUNCH_OFFSET);
        let ly = c.y + fy * (cr + er + LAUNCH_OFFSET);
        // nudge out of friendly cells
        for (let iter = 0; iter < 30; iter++) {
            let blocked = false;
            for (const other of p.cells) {
                if (other === c)
                    continue;
                const dx = lx - other.x, dy = ly - other.y;
                const minD = radius(other.mass) + er + PROJECTILE_SPAWN_CLEARANCE;
                if (dx * dx + dy * dy < minD * minD) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked)
                break;
            lx += fx * 3;
            ly += fy * 3;
        }
        const id = newId("e");
        ejected.set(id, {
            id,
            ownerId: p.id,
            x: lx,
            y: ly,
            vx: fx * EJECT_VELOCITY_INITIAL * sv,
            vy: fy * EJECT_VELOCITY_INITIAL * sv,
            color: c.color,
            spawnedAt: Date.now(),
        });
        // NOTE: ejection recoil on the cell is intentionally NOT applied — the
        // earlier experimental recoil drifted cells sideways during rapid feed
        // (per-burst recoil accumulated faster than damping could absorb) and
        // client prediction couldn't mirror it without desync.
    }
}
function updateEjected(dt) {
    if (ejected.size === 0)
        return;
    const fric = Math.pow(EJECT_FRICTION_PER_FRAME, dt * 60);
    const er = radius(EJECT_MASS);
    for (const e of ejected.values()) {
        if (e.vx === 0 && e.vy === 0)
            continue;
        // Subtle feed magnet — matches offline `EjectHandler.update` so feed
        // "locks on" to nearby cells (Agar.io mobile feel). Cost is bounded:
        // typical ejected count ~50, players ~71, avg cells ~5 → ~18 k ops/tick
        // ≈ 0.5 M ops/sec which is negligible compared to pellet collision pass.
        let mfx = 0, mfy = 0;
        for (const p of players.values()) {
            if (p.dead)
                continue;
            for (const c of p.cells) {
                const dx = c.x - e.x, dy = c.y - e.y;
                const d = Math.hypot(dx, dy);
                if (d < 150 && d > 10) {
                    const strength = (1.0 - d / 150) * 800.0;
                    mfx += (dx / d) * strength;
                    mfy += (dy / d) * strength;
                }
            }
        }
        e.vx += mfx * dt;
        e.vy += mfy * dt;
        e.x += e.vx * dt;
        e.y += e.vy * dt;
        e.vx *= fric;
        e.vy *= fric;
        if (Math.hypot(e.vx, e.vy) < 1) {
            e.vx = 0;
            e.vy = 0;
        }
        if (e.x < er) {
            e.x = er;
            e.vx = 0;
        }
        else if (e.x > WORLD_SIZE - er) {
            e.x = WORLD_SIZE - er;
            e.vx = 0;
        }
        if (e.y < er) {
            e.y = er;
            e.vy = 0;
        }
        else if (e.y > WORLD_SIZE - er) {
            e.y = WORLD_SIZE - er;
            e.vy = 0;
        }
    }
}
// ─────────────────────────────────────────────────────── split
function tryDoSplit(p, dirX, dirY) {
    if (p.dead)
        return;
    const m = Math.hypot(dirX, dirY);
    const ux = m > 0.05 ? dirX / m : p.input.lastDir.x;
    const uy = m > 0.05 ? dirY / m : p.input.lastDir.y;
    const now = Date.now();
    const candidates = [...p.cells].sort((a, b) => b.mass - a.mass);
    for (const source of candidates) {
        if (p.cells.length >= MAX_CELLS_PER_PLAYER)
            break;
        if (source.mass < SPLIT_MIN_MASS)
            continue;
        const newMass = source.mass / 2;
        source.mass = newMass;
        const sR = radius(source.mass);
        const cd = mergeCooldownMsForRadius(sR);
        source.mergeReadyAt = now + cd;
        source.freshSplit = true;
        const radiusScale = clamp(Math.pow(sR / REFERENCE_RADIUS, 0.35), 1.0, 2.5);
        const id = newId("c");
        p.cells.push({
            id,
            ownerId: p.id,
            x: source.x,
            y: source.y,
            vx: 0,
            vy: 0,
            spX: ux * SPLIT_IMPULSE_INITIAL * radiusScale,
            spY: uy * SPLIT_IMPULSE_INITIAL * radiusScale,
            mass: newMass,
            color: source.color,
            freshSplit: true,
            mergeReadyAt: now + cd,
        });
    }
}
// ─────────────────────────────────────────────────────── collisions
function resolveEatPellets() {
    for (const p of players.values()) {
        if (p.dead)
            continue;
        for (const c of p.cells) {
            const r = radius(c.mass);
            const r2 = r * r;
            for (const [id, pe] of pellets) {
                const dx = pe.x - c.x, dy = pe.y - c.y;
                if (dx * dx + dy * dy < r2) {
                    if (c.mass < MAX_CELL_MASS)
                        c.mass += PELLET_MASS;
                    pellets.delete(id);
                }
            }
        }
    }
}
function resolveEatEjected() {
    if (ejected.size === 0)
        return;
    const now = Date.now();
    for (const p of players.values()) {
        if (p.dead)
            continue;
        for (const c of p.cells) {
            if (c.mass < 22)
                continue;
            const r = radius(c.mass);
            for (const [id, e] of ejected) {
                if (e.ownerId === c.ownerId && now - e.spawnedAt < EJECT_OWNER_IMMUNITY_MS)
                    continue;
                const er = radius(EJECT_MASS);
                // eatR matches Offline Classic: cell eats feed when its centre
                // overlaps with 60% of the cell radius. An earlier `r + er` made
                // cells appear to "vacuum" feed from a distance and desynced with
                // any client that predicted with the same Offline rule.
                const eatR = r - er * 0.4;
                const dx = e.x - c.x, dy = e.y - c.y;
                if (dx * dx + dy * dy < eatR * eatR) {
                    if (c.mass < MAX_CELL_MASS)
                        c.mass += EJECT_CONSUMED_MASS;
                    ejected.delete(id);
                }
            }
        }
    }
}
function resolveEjectedFeedsVirus() {
    if (ejected.size === 0)
        return;
    for (const [eId, e] of ejected) {
        for (const v of viruses.values()) {
            const dx = e.x - v.x, dy = e.y - v.y;
            const d = Math.hypot(dx, dy);
            if (d < radius(v.mass) + radius(EJECT_MASS) * 0.5) {
                v.mass += EJECT_MASS;
                v.feedCount++;
                const m = Math.hypot(e.vx, e.vy);
                if (m > 0) {
                    v.lfX = e.vx / m;
                    v.lfY = e.vy / m;
                }
                ejected.delete(eId);
                if (v.mass >= 200) {
                    v.feedCount = 0;
                    v.mass = VIRUS_MASS;
                    const dx0 = v.lfX === 0 && v.lfY === 0 ? 1 : v.lfX;
                    const dy0 = v.lfX === 0 && v.lfY === 0 ? 0 : v.lfY;
                    const id = newId("v");
                    viruses.set(id, {
                        id,
                        x: v.x + dx0 * (radius(v.mass) + 30),
                        y: v.y + dy0 * (radius(v.mass) + 30),
                        vx: dx0 * VIRUS_SHOT_INITIAL,
                        vy: dy0 * VIRUS_SHOT_INITIAL,
                        mass: VIRUS_MASS,
                        feedCount: 0,
                        lfX: 0,
                        lfY: 0,
                    });
                }
                break;
            }
        }
    }
}
function resolveCellVsCell() {
    const all = [];
    for (const p of players.values()) {
        if (p.dead)
            continue;
        for (const c of p.cells)
            all.push(c);
    }
    const dead = new Set();
    for (const a of all) {
        if (dead.has(a))
            continue;
        const ar = radius(a.mass);
        for (const b of all) {
            if (a === b || dead.has(b))
                continue;
            if (a.ownerId === b.ownerId)
                continue;
            if (a.mass <= b.mass)
                continue;
            const ratio = a.freshSplit ? EAT_RATIO_FRESH_SPLIT : EAT_RATIO_WHOLE;
            if (a.mass < b.mass * ratio)
                continue;
            const br = radius(b.mass);
            const eatR = ar - br * 0.4;
            const dx = b.x - a.x, dy = b.y - a.y;
            if (dx * dx + dy * dy < eatR * eatR) {
                if (a.mass < MAX_CELL_MASS)
                    a.mass = Math.min(MAX_CELL_MASS, a.mass + b.mass);
                dead.add(b);
            }
        }
    }
    if (dead.size === 0)
        return;
    for (const p of players.values()) {
        if (p.cells.length === 0)
            continue;
        p.cells = p.cells.filter(c => !dead.has(c));
        if (p.cells.length === 0 && !p.dead) {
            p.dead = true;
            p.deadAt = Date.now();
        }
    }
}
function resolveCellVsVirus() {
    const consumed = new Set();
    // Snapshot virus list because popVirus pushes new cells
    for (const p of players.values()) {
        if (p.dead)
            continue;
        for (const c of p.cells.slice()) {
            const cr = radius(c.mass);
            for (const v of viruses.values()) {
                if (consumed.has(v.id))
                    continue;
                const vr = radius(v.mass);
                if (cr <= vr * 1.15)
                    continue;
                const trigger = cr + vr * 0.2;
                const dx = v.x - c.x, dy = v.y - c.y;
                if (dx * dx + dy * dy < trigger * trigger) {
                    consumed.add(v.id);
                    popVirus(p, c, v);
                    break;
                }
            }
        }
    }
    for (const id of consumed)
        viruses.delete(id);
}
function popVirus(p, eater, _v) {
    const now = Date.now();
    if (p.cells.length >= MAX_CELLS_PER_PLAYER) {
        eater.mass = Math.min(MAX_CELL_MASS, eater.mass + VIRUS_MASS);
        return;
    }
    const available = MAX_CELLS_PER_PLAYER - p.cells.length;
    const totMass = eater.mass + VIRUS_MASS;
    const desired = totMass > 350 ? 16 : 8 + Math.floor(Math.random() * 5);
    const n = Math.min(Math.max(2, Math.min(desired, available + 1)), 16);
    const masses = [];
    if (totMass > 350) {
        let remaining = totMass;
        const main = totMass * (0.45 + Math.random() * 0.1);
        masses.push(main);
        remaining -= main;
        const medCount = 2 + Math.floor(Math.random() * 2);
        for (let i = 0; i < medCount && masses.length < n; i++) {
            const mm = totMass * (0.08 + Math.random() * 0.04);
            masses.push(mm);
            remaining -= mm;
        }
        const small = n - masses.length;
        if (small > 0) {
            const sm = remaining / small;
            for (let i = 0; i < small; i++)
                masses.push(sm);
        }
        else
            masses[0] += remaining;
    }
    else {
        const each = totMass / n;
        for (let i = 0; i < n; i++)
            masses.push(each);
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
            id: newId("c"),
            ownerId: p.id,
            x: eater.x,
            y: eater.y,
            vx: 0,
            vy: 0,
            spX: dx * SPLIT_IMPULSE_INITIAL * radiusScale,
            spY: dy * SPLIT_IMPULSE_INITIAL * radiusScale,
            mass: m,
            color: eater.color,
            freshSplit: true,
            mergeReadyAt: now + mergeCooldownMsForRadius(r),
        });
    }
}
// ─────────────────────────────────────────────────────── merge
function processMerges(p) {
    const now = Date.now();
    // Always clear stale freshSplit — even for single-cell players.
    // Without this, a cell that split and re-merged stays freshSplit=true
    // forever, requiring 1.33× mass to eat instead of 1.25×.
    for (const c of p.cells) {
        if (c.freshSplit && now >= c.mergeReadyAt)
            c.freshSplit = false;
    }
    if (p.cells.length < 2)
        return;
    outer: for (let i = 0; i < p.cells.length; i++) {
        for (let j = i + 1; j < p.cells.length; j++) {
            const a = p.cells[i], b = p.cells[j];
            if (now < a.mergeReadyAt || now < b.mergeReadyAt)
                continue;
            const ar = radius(a.mass), br = radius(b.mass);
            const dx = a.x - b.x, dy = a.y - b.y;
            const d = Math.hypot(dx, dy);
            if (d >= (ar + br) * MERGE_DISTANCE_FACTOR)
                continue;
            const keeper = a.mass >= b.mass ? a : b;
            const consumed = keeper === a ? b : a;
            const idx = keeper === a ? j : i;
            const total = keeper.mass + consumed.mass;
            keeper.x = (keeper.x * keeper.mass + consumed.x * consumed.mass) / total;
            keeper.y = (keeper.y * keeper.mass + consumed.y * consumed.mass) / total;
            keeper.vx = (keeper.vx * keeper.mass + consumed.vx * consumed.mass) / total;
            keeper.vy = (keeper.vy * keeper.mass + consumed.vy * consumed.mass) / total;
            keeper.mass = total;
            // Merged cell is whole again — clear freshSplit so it uses the normal
            // 1.25× eating ratio instead of the post-split 1.33× ratio.
            keeper.freshSplit = false;
            p.cells.splice(idx, 1);
            return processMerges(p);
        }
    }
}
// ─────────────────────────────────────────────────────── refill
function refillWorld() {
    while (pellets.size < TARGET_PELLETS) {
        const p = spawnPellet();
        pellets.set(p.id, p);
    }
    while (viruses.size < TARGET_VIRUSES) {
        const v = spawnVirus();
        viruses.set(v.id, v);
    }
    // bots respawn
    const now = Date.now();
    for (const p of players.values()) {
        if (!p.isBot)
            continue;
        if (p.dead && now - p.deadAt >= BOT_RESPAWN_DELAY_MS) {
            spawnCellForPlayer(p);
        }
    }
    // keep bot population near target
    let aliveBots = 0;
    for (const p of players.values())
        if (p.isBot && !p.dead)
            aliveBots++;
    if (aliveBots < TARGET_BOTS) {
        const b = makeBot();
        players.set(b.id, b);
    }
}
function buildLeaderboard() {
    const list = [];
    for (const p of players.values()) {
        if (p.dead)
            continue;
        const m = totalMass(p);
        if (m <= 0)
            continue;
        list.push({ id: p.id, name: p.name, mass: Math.round(m), isHuman: !p.isBot });
    }
    list.sort((a, b) => b.mass - a.mass);
    return list.slice(0, LEADERBOARD_SIZE);
}
// ─────────────────────────────────────────────────────── snapshot
function buildSnapshot(p, lb, sendSlow) {
    const com = centerOfMass(p);
    const r2 = VIEWPORT_RADIUS * VIEWPORT_RADIUS;
    const now = Date.now();
    // ── cells (every tick — small count) ──
    const currentCells = new Set();
    const addCells = [];
    const updCells = [];
    for (const other of players.values()) {
        if (other.dead)
            continue;
        for (const c of other.cells) {
            const dx = c.x - com.x, dy = c.y - com.y;
            if (dx * dx + dy * dy > r2 * 1.3)
                continue;
            currentCells.add(c.id);
            const payload = {
                id: c.id,
                x: Math.round(c.x * 10) / 10,
                y: Math.round(c.y * 10) / 10,
                m: Math.round(c.mass * 10) / 10,
            };
            if (!p.seenCells.has(c.id)) {
                payload.o = other.id;
                payload.n = other.name;
                payload.col = c.color;
                payload.sk = other.skinId;
                payload.h = other.isBot ? 0 : 1;
                payload.s = c.freshSplit ? 1 : 0;
                payload.mr = c.mergeReadyAt;
                addCells.push(payload);
                p.seenCells.add(c.id);
            }
            else {
                // freshSplit flag may flip mid-life — include it cheap.
                payload.s = c.freshSplit ? 1 : 0;
                updCells.push(payload);
            }
        }
    }
    const rmCells = [];
    for (const id of p.seenCells) {
        if (!currentCells.has(id)) {
            rmCells.push(id);
            p.seenCells.delete(id);
        }
    }
    // ── pellets (slow-tick refresh of additions; removals every tick) ──
    const addPellets = [];
    if (sendSlow) {
        for (const pe of pellets.values()) {
            const dx = pe.x - com.x, dy = pe.y - com.y;
            if (dx * dx + dy * dy > r2)
                continue;
            if (p.seenPellets.has(pe.id))
                continue;
            addPellets.push({
                id: pe.id,
                x: Math.round(pe.x),
                y: Math.round(pe.y),
                c: pe.color,
            });
            p.seenPellets.add(pe.id);
        }
    }
    const rmPellets = [];
    for (const id of p.seenPellets) {
        if (!pellets.has(id)) {
            rmPellets.push(id);
            p.seenPellets.delete(id);
        }
    }
    // ── viruses (slow-tick add, every-tick update for moving ones, removals) ──
    const addViruses = [];
    const updViruses = [];
    const currentViruses = new Set();
    for (const v of viruses.values()) {
        const dx = v.x - com.x, dy = v.y - com.y;
        if (dx * dx + dy * dy > r2 * 1.3)
            continue;
        currentViruses.add(v.id);
        if (!p.seenViruses.has(v.id)) {
            addViruses.push({
                id: v.id,
                x: Math.round(v.x * 10) / 10,
                y: Math.round(v.y * 10) / 10,
                m: Math.round(v.mass),
            });
            p.seenViruses.add(v.id);
        }
        else if (Math.hypot(v.vx, v.vy) > 1 || sendSlow) {
            updViruses.push({
                id: v.id,
                x: Math.round(v.x * 10) / 10,
                y: Math.round(v.y * 10) / 10,
                m: Math.round(v.mass),
            });
        }
    }
    const rmViruses = [];
    for (const id of p.seenViruses) {
        if (!currentViruses.has(id)) {
            rmViruses.push(id);
            p.seenViruses.delete(id);
        }
    }
    // ── ejected (every tick — fast moving) ──
    const addEjected = [];
    const updEjected = [];
    const currentEjected = new Set();
    for (const e of ejected.values()) {
        const dx = e.x - com.x, dy = e.y - com.y;
        if (dx * dx + dy * dy > r2 * 1.3)
            continue;
        currentEjected.add(e.id);
        if (!p.seenEjected.has(e.id)) {
            addEjected.push({
                id: e.id,
                x: Math.round(e.x * 10) / 10,
                y: Math.round(e.y * 10) / 10,
                c: e.color,
                o: e.ownerId,
            });
            p.seenEjected.add(e.id);
        }
        else {
            updEjected.push({
                id: e.id,
                x: Math.round(e.x * 10) / 10,
                y: Math.round(e.y * 10) / 10,
            });
        }
    }
    const rmEjected = [];
    for (const id of p.seenEjected) {
        if (!currentEjected.has(id)) {
            rmEjected.push(id);
            p.seenEjected.delete(id);
        }
    }
    return {
        type: "state",
        t: serverTick,
        now,
        ack: p.lastInputSeq,
        self: {
            id: p.id,
            dead: p.dead,
            cm: { x: Math.round(com.x * 10) / 10, y: Math.round(com.y * 10) / 10 },
            mass: Math.round(totalMass(p)),
        },
        addCells, updCells, rmCells,
        addPellets, rmPellets,
        addViruses, updViruses, rmViruses,
        addEjected, updEjected, rmEjected,
        leaderboard: lb,
        online: [...players.values()].filter(q => !q.isBot).length,
    };
}
function sendSnapshotTo(p, lb, sendSlow) {
    if (p.isBot || !p.socket || p.socket.readyState !== ws_1.WebSocket.OPEN)
        return;
    try {
        p.socket.send(JSON.stringify(buildSnapshot(p, lb, sendSlow)));
    }
    catch { /* ignore */ }
}
// ─────────────────────────────────────────────────────── main loop
setInterval(() => {
    const now = Date.now();
    let dt = (now - lastNowMs) / 1000;
    if (dt < 0)
        dt = 0;
    if (dt > 0.1)
        dt = 0.1;
    lastNowMs = now;
    serverTick++;
    // bot decisions
    for (const p of players.values()) {
        if (!p.isBot || p.dead)
            continue;
        botDecide(p, now);
        botDecideSplit(p, now);
        botDecideEject(p, now);
    }
    // physics: input force, cohesion, separation, attack spread, integrate
    for (const p of players.values()) {
        if (p.dead)
            continue;
        updateLastDir(p);
        applyInputForce(p, dt);
        applyCohesion(p, dt);
        applySeparation(p, dt);
        applyAttackSpread(p, dt);
        integrateCells(p, dt);
    }
    // NOTE: an experimental pellet magnet was removed — O(P×C) per tick
    // (8000 pellets × ~1100 cells = 8.8M ops/tick) destroyed server FPS.
    // Pellets are picked up via resolveEatPellets() on contact only.
    updateViruses(dt);
    updateEjected(dt);
    resolveEatPellets();
    resolveEatEjected();
    resolveEjectedFeedsVirus();
    resolveCellVsCell();
    resolveCellVsVirus();
    for (const p of players.values())
        processMerges(p);
    refillWorld();
    // highest mass
    for (const p of players.values()) {
        if (p.dead)
            continue;
        const m = totalMass(p);
        if (m > p.highestMass)
            p.highestMass = m;
    }
    const lb = buildLeaderboard();
    const sendSlow = serverTick % SLOW_TICK_EVERY === 0;
    for (const p of players.values()) {
        if (!p.isBot)
            sendSnapshotTo(p, lb, sendSlow);
    }
    // stale humans
    for (const [id, p] of players) {
        if (p.isBot)
            continue;
        if (now - p.lastSeenAt > STALE_PLAYER_MS) {
            try {
                p.socket?.close();
            }
            catch { /* ignore */ }
            players.delete(id);
        }
    }
}, TICK_MS);
// ─────────────────────────────────────────────────────── ws server
const http = (0, http_1.createServer)((_, res) => {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("Yazario Online Classic V2");
});
const wss = new ws_1.WebSocketServer({ server: http });
wss.on("connection", (ws) => {
    let player = null;
    const safeSend = (obj) => {
        if (ws.readyState !== ws_1.WebSocket.OPEN)
            return;
        try {
            ws.send(JSON.stringify(obj));
        }
        catch { /* ignore */ }
    };
    ws.on("message", (raw) => {
        let msg;
        try {
            msg = JSON.parse(raw.toString());
        }
        catch {
            return;
        }
        const type = msg?.type;
        if (type === "join") {
            if (player)
                return;
            const rawName = typeof msg.name === "string" ? msg.name : "";
            const name = rawName.trim().slice(0, 18) || "Player";
            const skinId = typeof msg.skin === "string" ? msg.skin.slice(0, 128) : "";
            const id = newId("h");
            player = {
                id,
                socket: ws,
                isBot: false,
                name,
                color: pickPaletteColor(),
                skinId,
                cells: [],
                input: { dx: 0, dy: 0, attack: false, lastDir: { x: 1, y: 0 }, seq: 0 },
                dead: false,
                deadAt: 0,
                lastInputSeq: 0,
                lastSeenAt: Date.now(),
                spawnAt: Date.now(),
                highestMass: 76,
                aiDir: { x: 0, y: 0 },
                aiNextDecide: 0,
                aiNextSplit: 0,
                aiNextEject: 0,
                seenCells: new Set(),
                seenPellets: new Set(),
                seenViruses: new Set(),
                seenEjected: new Set(),
            };
            spawnCellForPlayer(player);
            players.set(id, player);
            safeSend({
                type: "welcome",
                id,
                worldSize: WORLD_SIZE,
                tickRate: TICK_RATE,
                tickMs: TICK_MS,
                name: player.name,
            });
            return;
        }
        if (!player)
            return;
        player.lastSeenAt = Date.now();
        if (type === "input") {
            const dx = Number(msg.dx), dy = Number(msg.dy);
            const seq = Number(msg.seq);
            const attack = !!msg.attack;
            if (!Number.isFinite(dx) || !Number.isFinite(dy))
                return;
            player.input.dx = clamp(dx, -1, 1);
            player.input.dy = clamp(dy, -1, 1);
            player.input.attack = attack;
            if (Number.isFinite(seq) && seq > player.lastInputSeq) {
                player.lastInputSeq = seq;
            }
        }
        else if (type === "split") {
            const seq = Number(msg.seq);
            if (Number.isFinite(seq) && seq > player.lastInputSeq) {
                player.lastInputSeq = seq;
            }
            let dx = player.input.dx, dy = player.input.dy;
            const m = Math.hypot(dx, dy);
            if (m < 0.05) {
                dx = player.input.lastDir.x;
                dy = player.input.lastDir.y;
            }
            tryDoSplit(player, dx, dy);
        }
        else if (type === "eject") {
            const seq = Number(msg.seq);
            if (Number.isFinite(seq) && seq > player.lastInputSeq) {
                player.lastInputSeq = seq;
            }
            let dx = player.input.dx, dy = player.input.dy;
            const m = Math.hypot(dx, dy);
            if (m < 0.05) {
                dx = player.input.lastDir.x;
                dy = player.input.lastDir.y;
            }
            tryDoEject(player, dx, dy);
        }
        else if (type === "respawn") {
            if (player.dead)
                spawnCellForPlayer(player);
        }
        else if (type === "ping") {
            const t = Number(msg.t);
            safeSend({ type: "pong", t: Number.isFinite(t) ? t : 0, now: Date.now() });
        }
    });
    ws.on("close", () => {
        if (player) {
            players.delete(player.id);
            player = null;
        }
    });
    ws.on("error", () => { });
});
http.listen(PORT, () => {
    console.log(`[yazario-v2] Online Classic V2 server listening on :${PORT}`);
});
