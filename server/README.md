# Yazario Online Classic — server

Authoritative WebSocket server for Online Classic mode. Single global world,
TypeScript + `ws`. Runs on port `2567` by default (override via `PORT`).

## Deploy

```bash
cd server
npm install
npm run build
npm start
# or, on the VPS, run under pm2 / systemd:
pm2 start dist/index.js --name yazario
```

Client connects to `ws://<host>:2567`.

## Protocol

Client → server:
- `{type:"join", name, skin}`
- `{type:"input", dx, dy}` (values in [-1, 1])
- `{type:"split"}`
- `{type:"respawn"}`
- `{type:"ping", t}`

Server → client:
- `{type:"connected", id, mapWidth, mapHeight, tickRate, name}`
- `{type:"state", serverTime, self, players, pellets, viruses, leaderboard, online}`
- `{type:"pong", t}`

All gameplay is server-authoritative — clients only render and send inputs.
