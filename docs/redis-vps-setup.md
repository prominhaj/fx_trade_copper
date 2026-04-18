# Redis VPS Setup Guide

This guide helps you run the FX Trade Copper Redis proxy in three practical ways:

1. proxy and Redis on the same VPS
2. proxy on one VPS and Redis on another VPS
3. proxy on a VPS with managed or hosted Redis

## Recommended Topology

For most users, the best starting setup is:

- one VPS for the proxy
- one Redis service on the same VPS
- one or more MT5 terminals posting to that proxy

This is simple, fast, and easy to support.

## Option 1: Same VPS For Proxy And Redis

Best for:

- one trader
- one team
- one small monitoring stack

### Steps

1. Install Docker and Docker Compose
2. Upload this project or only `redis_http_proxy/`
3. Create `.env`
4. Start the stack

Example `.env`:

```text
PROXY_HOST=0.0.0.0
PROXY_PORT=8080
REDIS_URL=redis://redis:6379
AUTH_MODE=token
AUTH_TOKEN=replace-this-token
ENABLE_READ_API=true
```

Run:

```bash
docker compose up -d --build
```

Use Nginx or Caddy in front for HTTPS.

## Option 2: Proxy VPS And Redis VPS

Best for:

- multiple MT5 VPS instances
- one shared Redis backend
- better isolation between application and data layers

### Steps

1. Deploy the proxy on VPS A
2. Deploy Redis on VPS B
3. Restrict Redis so only VPS A can connect
4. Set `REDIS_URL` in the proxy to the Redis host

Example:

```text
REDIS_URL=redis://:strongpassword@10.0.0.25:6379
```

If Redis is behind TLS:

```text
REDIS_URL=rediss://:strongpassword@redis.example.com:6380
```

## Option 3: Managed Redis Or Hosted Redis

Best for:

- teams that do not want to maintain Redis directly
- internet-facing dashboards
- multi-region or higher availability needs

Example:

```text
REDIS_URL=rediss://default:strongpassword@managed-redis.example.com:6380
```

## Security Checklist

Use this for production:

- put the proxy behind HTTPS
- keep Redis private if possible
- never expose Redis directly to the public internet
- use a strong token
- prefer `AUTH_MODE=hybrid` for internet-facing setups
- lock down firewall rules
- rotate secrets regularly

## Firewall Guidance

Allow:

- proxy port `8080` only from trusted MT5 hosts, reverse proxy, or private network
- Redis port `6379` only from the proxy host if Redis is separate

Block:

- public direct access to Redis

## Nginx Reverse Proxy Example

```nginx
server {
    listen 443 ssl http2;
    server_name redis-proxy.example.com;

    ssl_certificate /etc/letsencrypt/live/redis-proxy.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/redis-proxy.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## MT5 Setup For Remote Proxy

Set your EA:

```text
EnableRedisHttpExport=true
RedisHttpBaseUrl=https://redis-proxy.example.com
RedisHttpEndpointPath=/api/v1/mt5/redis-sync
RedisHttpAuthHeaderName=Authorization
RedisHttpAuthToken=replace-this-token
RedisHttpUseBearerToken=true
RedisHttpAllowInsecureHttp=false
```

And add this URL to MT5 WebRequest allow list:

```text
https://redis-proxy.example.com
```

## Redis Sizing Guidance

For light to medium usage:

- 1 vCPU
- 1 GB RAM
- append-only enabled
- history limits tuned to your workload

Start with:

```text
MAX_EVENT_ITEMS=1000
MAX_SNAPSHOT_ITEMS=500
MAX_DEAL_ITEMS=3000
```

Increase only if your dashboards or audit needs require deeper retention.

## Multi-VPS Workflow

A productive pattern is:

- MT5 terminals run on one or more VPS machines
- all terminals post to one HTTPS proxy
- the proxy writes to one Redis backend
- dashboards, bots, and internal apps read from Redis

This gives you:

- one ingestion point
- one auth layer
- one Redis schema
- easier monitoring
- easier scaling later

## Operational Checks

After deployment:

1. call `/health`
2. call `/ready`
3. send one MT5 export
4. confirm Redis keys exist
5. confirm deal history and PnL update after new trades

## Backup Guidance

If Redis stores business-critical history:

- enable persistence
- back up Redis data regularly
- consider also writing long-term trade history to PostgreSQL or another database

Redis is excellent for fast operational reads, but many teams still keep long-term archives elsewhere.
