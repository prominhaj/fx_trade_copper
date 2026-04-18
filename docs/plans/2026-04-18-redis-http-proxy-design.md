# Redis HTTP Proxy Design

**Date:** 2026-04-18

## Goal

Add a reusable Redis HTTP proxy that accepts MT5 JSON exports from the FX Trade Copper EAs and stores them in Redis with:

- always-updated latest account state
- open positions and pending orders
- trade history snapshots
- PnL summaries for today, last week, last month, and custom ranges
- event-style records for auditing and downstream automation

## Approved Direction

- One shared Node.js proxy for local and VPS deployment
- Hybrid Redis model:
  latest-state keys for fast reads and event/history structures for analytics
- Dual auth path:
  simple bearer or API key auth now, with optional signed-request mode for harder internet-facing deployments later

## Architecture

The MT5 EAs remain thin publishers. They continue to send JSON over HTTP or HTTPS using `WebRequest()`. A new proxy service validates the request, normalizes the payload, writes it into Redis, and exposes optional health endpoints for operations.

This keeps MetaTrader focused on trading and lets the proxy own Redis structure, idempotency, retention, and future integrations.

## Data Model

### Latest-state keys

These keys are overwritten on each successful ingest:

- `mt5:{account_id}:summary`
- `mt5:{account_id}:channel:{channel_id}:summary`
- `mt5:{account_id}:positions`
- `mt5:{account_id}:orders`
- `mt5:{account_id}:pnl`
- `mt5:{account_id}:meta`

These keys are optimized for dashboards, bots, admin panels, and quick account health checks.

### Event and history structures

These are appended over time:

- `mt5:{account_id}:events`
- `mt5:{account_id}:history:deals`
- `mt5:{account_id}:history:snapshots`

These structures support auditing, replay, reporting, and future analytics jobs.

## Proxy Responsibilities

- authenticate incoming requests
- validate payload shape
- calculate stable Redis key names
- write latest state atomically
- append event and history records
- trim history lists to configured limits
- expose health and readiness endpoints

## Deployment Modes

### Local developer machine

- Node.js proxy runs locally
- Redis runs locally via Docker or native install
- MT5 points `RedisHttpBaseUrl` to local proxy

### Single VPS

- proxy and Redis run on the same VPS
- MT5 terminals on one or more VPS instances post to that proxy

### Split VPS

- proxy runs on one VPS or app host
- Redis runs on another VPS or managed Redis service
- connection uses password and optional TLS

## Security

Phase 1 will support:

- bearer token auth
- custom API key header auth
- optional IP allow-list configuration in the proxy

Phase 2 can add request signing if needed without breaking the current EA contract.

## Tech Choices

- Fastify for HTTP server and schema validation
- node-redis for Redis access
- Docker Compose for local or VPS deployment
- Markdown setup guides for operators

## Sources

- Fastify getting started: https://fastify.dev/docs/latest/Guides/Getting-Started/
- node-redis guide: https://redis.io/docs/latest/develop/clients/nodejs/
- Redis official Docker image: https://hub.docker.com/_/redis
