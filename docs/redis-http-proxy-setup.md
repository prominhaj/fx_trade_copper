# Redis HTTP Proxy Setup

This guide shows how to run the FX Trade Copper Redis HTTP proxy on your local PC or VPS so your MT5 EA can keep Redis updated with:

- real-time account summary
- open positions
- pending orders
- trade history
- PnL ranges

## What This Proxy Does

The EA does not connect to Redis directly. It sends JSON to the proxy, and the proxy writes the data into Redis.

That gives you:

- safer auth handling
- stable Redis key naming
- one ingestion point for multiple MT5 terminals
- a simple path for dashboards, bots, CRMs, and admin tools

## Folder Layout

Proxy files live in:

```text
redis_http_proxy/
```

Main files:

- `package.json`
- `src/server.mjs`
- `src/store.mjs`
- `.env.example`
- `Dockerfile`
- `docker-compose.yml`

## Option 1: Run Locally With Node.js

### Requirements

- Node.js 20 or newer
- Redis running locally or reachable over the network

### 1. Open the proxy folder

```powershell
cd .\redis_http_proxy
```

### 2. Create your environment file

```powershell
Copy-Item .env.example .env
```

Edit `.env` and set at least:

```text
REDIS_URL=redis://127.0.0.1:6379
AUTH_TOKEN=change-this-token
```

### 3. Install dependencies

If PowerShell allows `npm`:

```powershell
npm install
```

If PowerShell script policy blocks `npm`, use:

```powershell
npm.cmd install
```

### 4. Start the proxy

```powershell
npm start
```

If needed:

```powershell
npm.cmd start
```

### 5. Test health endpoints

```text
GET http://127.0.0.1:8080/health
GET http://127.0.0.1:8080/ready
```

Expected:

- `/health` returns `ok: true`
- `/ready` returns `redis: "ready"`

## Option 2: Run With Docker Compose

This is the easiest way to run the proxy and Redis together on a local machine or VPS.

### 1. Prepare environment

```powershell
cd .\redis_http_proxy
Copy-Item .env.example .env
```

Edit `.env` and set:

```text
REDIS_URL=redis://redis:6379
AUTH_TOKEN=change-this-token
```

### 2. Start the stack

```powershell
docker compose up -d --build
```

### 3. Check containers

```powershell
docker compose ps
```

### 4. Test the proxy

```text
GET http://127.0.0.1:8080/health
GET http://127.0.0.1:8080/ready
```

## MT5 EA Configuration

In your EA inputs, use:

```text
EnableRedisHttpExport=true
RedisHttpBaseUrl=http://127.0.0.1:8080
RedisHttpEndpointPath=/api/v1/mt5/redis-sync
RedisHttpAuthHeaderName=Authorization
RedisHttpAuthToken=change-this-token
RedisHttpUseBearerToken=true
RedisHttpAllowInsecureHttp=true
```

If your proxy is public behind HTTPS:

```text
RedisHttpBaseUrl=https://your-domain.example.com
RedisHttpAllowInsecureHttp=false
```

## MT5 WebRequest Allow List

In MetaTrader 5:

- go to `Tools -> Options -> Expert Advisors`
- enable `Allow WebRequest for listed URL`
- add your base URL exactly

Examples:

```text
http://127.0.0.1:8080
https://your-domain.example.com
```

## Redis Data Model

The proxy writes two kinds of data:

### Latest-state keys

- `mt5:account:<login>:summary`
- `mt5:account:<login>:terminal`
- `mt5:account:<login>:copy_settings`
- `mt5:account:<login>:pnl`
- `mt5:account:<login>:positions`
- `mt5:account:<login>:orders`
- `mt5:account:<login>:trade_history:latest`
- `mt5:account:<login>:payload:latest`
- `mt5:account:<login>:meta`

### History and event structures

- `mt5:account:<login>:events`
- `mt5:account:<login>:history:snapshots`
- `mt5:account:<login>:history:deals:index`
- `mt5:account:<login>:history:deals:by_ticket`

This hybrid layout is fast for dashboards and still useful for auditing.

## Read APIs For Quick Testing

If `ENABLE_READ_API=true`, the proxy also exposes:

- `GET /api/v1/accounts/<login>/latest`
- `GET /api/v1/accounts/<login>/deals?limit=100`
- `GET /api/v1/channels/<channel_id>/accounts`

These endpoints use the same auth rules as the ingest endpoint.

## Auth Modes

Set `AUTH_MODE` in `.env`:

- `off`
- `token`
- `signature`
- `hybrid`

Recommended default:

```text
AUTH_MODE=token
AUTH_HEADER_NAME=authorization
AUTH_TOKEN=change-this-token
```

For a hardened internet-facing setup:

```text
AUTH_MODE=hybrid
AUTH_TOKEN=change-this-token
SIGNING_SECRET=replace-with-a-long-secret
```

## Useful Redis Commands

See latest account summary:

```powershell
redis-cli GET mt5:account:433459541:summary
```

See latest PnL:

```powershell
redis-cli GET mt5:account:433459541:pnl
```

See known accounts for a channel:

```powershell
redis-cli SMEMBERS mt5:channel:default:accounts
```

## Troubleshooting

### Proxy starts but MT5 cannot post

Check:

- the base URL is in MT5 WebRequest allow list
- the auth token matches
- `RedisHttpAllowInsecureHttp=true` only when using plain HTTP locally
- firewall rules allow the proxy port

### `/ready` fails

Check:

- `REDIS_URL`
- Redis container or service is running
- the Redis password or TLS settings are correct

### Data is updating but history duplicates

The proxy deduplicates deals by ticket and maintains a sorted index of deal tickets. If your broker changes historical deal content, the latest version for the same ticket overwrites the previous stored JSON.
