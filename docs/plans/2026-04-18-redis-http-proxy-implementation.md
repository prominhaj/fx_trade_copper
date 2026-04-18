# Redis HTTP Proxy Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a reusable Redis HTTP proxy for FX Trade Copper so MT5 EAs can publish real-time account data into Redis for dashboards, bots, and reporting tools.

**Architecture:** The EAs will continue posting JSON snapshots to an HTTP endpoint. A Fastify service will validate the payload, authenticate the request, and write both latest-state keys and append-only history structures into Redis. Docker assets and markdown guides will support local and VPS deployments from the same codebase.

**Tech Stack:** Node.js, Fastify, node-redis, Docker Compose, Markdown documentation

---

### Task 1: Create the proxy workspace

**Files:**
- Create: `redis_http_proxy/package.json`
- Create: `redis_http_proxy/src/server.mjs`
- Create: `redis_http_proxy/src/config.mjs`
- Create: `redis_http_proxy/src/redis-keys.mjs`
- Create: `redis_http_proxy/src/store.mjs`

**Step 1: Scaffold the Node.js package**

Create a minimal ESM package with scripts for `dev` and `start`, and dependencies for Fastify plus Redis.

**Step 2: Add configuration loading**

Read environment variables for:

- HTTP port and host
- auth mode and tokens
- Redis connection URL
- history trim limits
- optional TLS and request logging

**Step 3: Add Redis key helpers**

Generate stable key names for summary, positions, orders, PnL, metadata, events, deals, and snapshots.

### Task 2: Implement request handling and Redis writes

**Files:**
- Modify: `redis_http_proxy/src/server.mjs`
- Modify: `redis_http_proxy/src/store.mjs`

**Step 1: Add health endpoints**

Implement `GET /health` and `GET /ready`.

**Step 2: Add ingest endpoint**

Implement `POST /api/v1/mt5/redis-sync` with:

- schema validation
- bearer or API key auth
- Redis write pipeline

**Step 3: Store latest-state keys**

Write latest account summary, positions, orders, PnL, and metadata.

**Step 4: Append audit records**

Append snapshot, event, and history list entries with trim behavior.

### Task 3: Add deployment assets

**Files:**
- Create: `redis_http_proxy/.env.example`
- Create: `redis_http_proxy/.dockerignore`
- Create: `redis_http_proxy/Dockerfile`
- Create: `redis_http_proxy/docker-compose.yml`

**Step 1: Add Dockerfile**

Create a production-ready container for the proxy.

**Step 2: Add Compose stack**

Provide a simple local stack with proxy, Redis, and optional Redis Insight notes.

### Task 4: Document setup for users

**Files:**
- Create: `docs/redis-http-proxy-setup.md`
- Create: `docs/redis-vps-setup.md`
- Modify: `README.md`

**Step 1: Write proxy setup guide**

Explain local setup, environment variables, MT5 WebRequest configuration, and how to test the proxy.

**Step 2: Write VPS deployment guide**

Explain same-VPS Redis, remote Redis, firewall, TLS, and auth guidance.

**Step 3: Update root README**

Link the new proxy module and setup docs from the main project guide.

### Task 5: Verify the result

**Files:**
- Verify: `redis_http_proxy/**`
- Verify: `docs/*.md`
- Verify: `README.md`

**Step 1: Inspect the generated structure**

Confirm that the proxy files and setup docs exist in the expected locations.

**Step 2: Validate the package manifest**

Check `package.json` and environment examples for consistency.

**Step 3: Summarize usage**

Provide concise steps for running the proxy locally and on a VPS.
