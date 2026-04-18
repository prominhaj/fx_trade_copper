# FX Trade Copper

FX Trade Copper is a MetaTrader 5 trade copier EA with two jobs:

- copy trades from a master MT5 account to one or more slave MT5 accounts
- publish account analytics, PnL summaries, and trade history to a Redis-backed HTTP API for use in dashboards, admin panels, bots, CRMs, or reporting tools

It is designed for traders, account managers, and developers who want a lightweight MT5 copier without external DLLs, plus a clean way to push account data into Redis for other applications.

## Why FX Trade Copper

FX Trade Copper combines local MT5 trade copying with API-ready data export:

- MT5 master-slave copier for positions and pending orders
- broker symbol mapping with suffix and base-symbol matching
- startup controls to ignore old master trades or clear old copied trades
- copy schedules by weekday, time window, and advanced rules
- time-based lot multiplier windows and rule-based scaling
- secure HTTP export with auth header support
- account-level PnL summaries for today, last week, last month, and a custom date range
- recent trade history export for Redis ingestion
- account snapshot export with balance, equity, margin, positions, and pending orders

## Project Structure

This project now has a modular Redis export system:

- [fx_trade_copper.mq5](./fx_trade_copper.mq5)
  The main trade copier EA with master-slave sync and optional Redis HTTP export
- [fx_trade_copper_redis_exporter.mq5](./fx_trade_copper_redis_exporter.mq5)
  A Redis-only exporter EA for accounts where you want analytics and history export without trade copying
- [fx_trade_copper_redis_module.mqh](./fx_trade_copper_redis_module.mqh)
  The shared Redis HTTP module used by both EAs
- [redis_http_proxy](./redis_http_proxy)
  A reusable Node.js Fastify proxy that receives MT5 payloads and stores latest state plus history in Redis
- [docs/redis-http-proxy-setup.md](./docs/redis-http-proxy-setup.md)
  Step-by-step local setup guide for the proxy, Redis, and MT5 WebRequest configuration
- [docs/redis-vps-setup.md](./docs/redis-vps-setup.md)
  VPS deployment guide for same-host Redis, split-host Redis, and managed Redis setups

This makes the Redis system easier to maintain, test, and reuse across future EAs.

## How The Copier Works

The trade copier uses the MT5 `FILE_COMMON` shared folder:

- the master EA builds a snapshot of positions and pending orders
- the snapshot is written to `FXTradeCopper_<channel>.sync`
- the slave EA reads that file on a timer
- copied trades are tagged with a channel-aware comment so the EA can update or remove only its own trades

This works well when your MT5 terminals run under the same Windows user account, such as:

- multiple MT5 terminals on one PC
- multiple broker terminals on one VPS
- several MT5 installations under the same Windows profile

## How The Redis Export Works

MetaTrader 5 does not talk to Redis directly in this EA. Instead, FX Trade Copper sends JSON over HTTP or HTTPS to your API, and your API stores that data in Redis.

That design gives you:

- better security
- flexible auth
- easier scaling
- easier integration with web and mobile apps
- freedom to use Redis as cache, event store, analytics store, or API source
- one reusable proxy for local PC, local VPS, or remote VPS deployments

### Exported data

When Redis export is enabled, the EA can send:

- account identity and account state
- account ID and server
- balance, equity, margin, free margin, margin level, current profit
- open positions
- pending orders
- recent trade history from account deals
- PnL summary for:
  - today
  - last week as a rolling 7-day range
  - last month as a rolling 30-day range
  - custom date range from EA inputs

## Main Features

### Trade copier features

- master mode and slave mode
- copy positions
- copy pending orders
- copy stop loss and take profit
- copy pending-order expiration
- auto cleanup when the master removes a trade
- publish on timer and trade events

### Mapping and sizing features

- manual symbol mapping with `SymbolMappings`
- automatic broker symbol matching with `AutoMapByBaseSymbol`, including common prefix and suffix variants
- optional `CopyOnlySymbols` filter to copy only selected symbols
- base lot scaling with `VolumeMultiplier`
- time-based lot multiplier window
- advanced lot multiplier rules

### Scheduling features

- weekday filter
- daily copy time range
- daily copy stop window
- advanced `CopyScheduleRules`
- custom GMT offset for schedule evaluation

### Redis API export features

- configurable HTTP API base URL
- configurable endpoint path
- auth header support
- bearer token support
- option to block plain `http://` endpoints unless explicitly allowed
- export on interval
- export on trade events
- recent history window control
- custom date-range PnL export

## Inputs

### Core copier settings

| Input | Purpose |
| --- | --- |
| `Mode` | `MODE_MASTER` or `MODE_SLAVE` |
| `ChannelId` | Shared channel name used by master and slave |
| `SymbolMappings` | Optional manual symbol map, for example `XAUUSD=XAUUSDm;EURUSD=EURUSDm`. Default is blank so the EA can auto-detect common broker suffix and prefix variants such as `XAUUSD.m`, `XAUUSDm`, `.cr`, or `mXAUUSD`. |
| `CopyOnlySymbols` | Optional allow-list of symbols to copy, for example `XAUUSD;EURUSD;US30`. Matches master or slave broker symbols. Leave blank to copy all symbols. |
| `MagicNumber` | Magic number used for copied slave trades |
| `VolumeMultiplier` | Base multiplier for copied lot size |
| `TimerIntervalMs` | Timer frequency for copier polling |
| `PublishOnTradeEvents` | Publish master snapshot when the account changes |
| `VerboseLogs` | Enable detailed Journal and Experts logging |

### Copy controls

| Input | Purpose |
| --- | --- |
| `CopyPositions` | Copy market positions |
| `CopyPendingOrders` | Copy pending orders |
| `CopyStopLoss` | Copy SL |
| `CopyTakeProfit` | Copy TP |
| `CopyExpirations` | Copy pending-order expiration |

### Slave startup controls

| Input | Purpose |
| --- | --- |
| `SyncExistingMasterTradesOnSlaveStart` | If `false`, ignore master trades that already existed before the slave started |
| `ClearCopiedTradesOnSlaveStart` | If `true`, clear older copied trades for the same channel on startup |

### Copy schedule controls

| Input | Purpose |
| --- | --- |
| `EnableSlaveTimeSchedule` | Enable copy filters by day and time |
| `ScheduleGmtOffsetHours` | GMT offset used for schedule evaluation |
| `UseSimpleWeekdayFilter` | Enable weekday on or off filter |
| `FollowSunday` to `FollowSaturday` | Per-day copy allow flags |
| `UseSimpleTimeRange` | Enable one simple copy window |
| `SimpleCopyStartTime` / `SimpleCopyEndTime` | Copy window in `HH:MM` |
| `UseSimpleCopyStopWindow` | Enable stop-copy window |
| `StopCopySunday` to `StopCopySaturday` | Per-day stop-window flags |
| `SimpleCopyStopStartTime` / `SimpleCopyStopEndTime` | Stop window in `HH:MM` |
| `CopyScheduleRules` | Advanced copy rules in `window=action` format |

### Lot multiplier controls

| Input | Purpose |
| --- | --- |
| `UseSimpleLotMultiplierWindow` | Enable one time-based lot window |
| `LotMultiplierSunday` to `LotMultiplierSaturday` | Per-day flags for the lot window |
| `SimpleLotMultiplierStartTime` / `SimpleLotMultiplierEndTime` | Lot window in `HH:MM` |
| `SimpleLotTimeMultiplier` | Multiplier inside the lot window |
| `LotMultiplierScheduleRules` | Advanced lot rules in `window=multiplier` format |

### Redis HTTP export controls

| Input | Purpose |
| --- | --- |
| `EnableRedisHttpExport` | Turn Redis HTTP export on or off |
| `RedisHttpBaseUrl` | Base URL of your API, for example `https://api.example.com` |
| `RedisHttpEndpointPath` | Endpoint path appended to the base URL |
| `RedisHttpTimeoutMs` | HTTP timeout in milliseconds |
| `RedisHttpPublishIntervalSec` | Export interval in seconds |
| `RedisHttpPublishOnTradeEvents` | Queue a new export when the account trade state changes |
| `RedisHttpAuthHeaderName` | Header name for auth, for example `Authorization` or `X-API-Key` |
| `RedisHttpAuthToken` | Auth token value |
| `RedisHttpUseBearerToken` | If `true`, sends `Bearer <token>` |
| `RedisHttpAllowInsecureHttp` | Allow plain `http://` endpoints for trusted local development only |
| `RedisHttpIncludeOpenPositions` | Include live open positions in the payload |
| `RedisHttpIncludePendingOrders` | Include pending orders in the payload |
| `RedisHttpIncludeTradeHistory` | Include recent deal history |
| `RedisHttpTradeHistoryDays` | Lookback window for exported trade history |
| `RedisHttpMaxDealsPerPush` | Maximum number of deals exported per request |
| `RedisHttpCustomFromDate` | Custom PnL range start in `YYYY-MM-DD` |
| `RedisHttpCustomToDate` | Custom PnL range end in `YYYY-MM-DD` |

## Schedule Rule Format

### Copy schedule rule format

```text
<day list and time window>=COPY|SKIP
```

Examples:

```text
MON,TUE,WED,THU,FRI 08:00-17:00=COPY
SAT,SUN=SKIP
22:00-02:00=SKIP
```

### Lot multiplier rule format

```text
<day list and time window>=<multiplier>
```

Examples:

```text
MON,TUE,WED,THU,FRI 01:00-12:00=2.0
FRI 13:00-18:00=0.5
```

Supported syntax:

- day names: `SUN`, `MON`, `TUE`, `WED`, `THU`, `FRI`, `SAT`
- daily aliases: `ALL`, `ANY`, `EVERYDAY`, `DAILY`
- multiple days separated by commas
- time window format `HH:MM-HH:MM`
- overnight windows are supported, such as `22:00-02:00`

## Quick Start

### 1. Attach the master EA

- open the source account chart in MT5
- attach `fx_trade_copper`
- set `Mode=MODE_MASTER`
- set a shared `ChannelId`
- set the symbol mapping you want to publish

### 2. Attach the slave EA

- open the destination account chart in MT5
- attach `fx_trade_copper`
- set `Mode=MODE_SLAVE`
- use the same `ChannelId`
- leave `SymbolMappings` blank for normal suffix or prefix brokers, or set it only when your broker uses truly different names
- configure lot sizing and schedule rules if needed

### 3. Enable trading on the slave

- turn on the MT5 `AutoTrading` button
- enable `Allow Algo Trading` in the EA properties
- make sure the account is not using investor password only

### 4. Test with a small trade

- place one small trade on the master
- confirm the slave receives it
- check `Experts` and `Journal` tabs if nothing happens

## Which EA To Use

### Use `fx_trade_copper.mq5`

Use the main EA when you need:

- trade copying
- slave scheduling
- lot multiplier logic
- Redis export from the same copier EA

### Use `fx_trade_copper_redis_exporter.mq5`

Use the Redis-only exporter when you need:

- account analytics export only
- trade history export only
- Redis snapshots from an account without copier logic
- a lighter EA for dashboards, monitoring, and reporting

## Redis HTTP Export Setup

### 1. Enable WebRequest in MT5

`WebRequest()` only works if the URL is allowed in MetaTrader 5.

In MT5:

- go to `Tools -> Options -> Expert Advisors`
- enable WebRequest for the API base URL
- add the same URL you use in `RedisHttpBaseUrl`

Example:

```text
https://api.example.com
```

### 2. Example EA configuration

```text
EnableRedisHttpExport=true
RedisHttpBaseUrl=https://api.example.com
RedisHttpEndpointPath=/api/v1/mt5/redis-sync
RedisHttpTimeoutMs=5000
RedisHttpPublishIntervalSec=60
RedisHttpPublishOnTradeEvents=true
RedisHttpAuthHeaderName=Authorization
RedisHttpAuthToken=your-secret-token
RedisHttpUseBearerToken=true
RedisHttpAllowInsecureHttp=false
RedisHttpIncludeOpenPositions=true
RedisHttpIncludePendingOrders=true
RedisHttpIncludeTradeHistory=true
RedisHttpTradeHistoryDays=35
RedisHttpMaxDealsPerPush=200
RedisHttpCustomFromDate=2026-04-01
RedisHttpCustomToDate=2026-04-18
```

### 3. Auth header behavior

If you use bearer tokens:

```http
Authorization: Bearer your-secret-token
```

If you use an API key header instead:

```text
RedisHttpAuthHeaderName=X-API-Key
RedisHttpAuthToken=your-secret-token
RedisHttpUseBearerToken=false
```

### 4. Recommended production setup

- use `https://`, not `http://`
- keep `RedisHttpAllowInsecureHttp=false`
- terminate TLS on your API or reverse proxy
- validate the auth token server-side
- rate limit the endpoint
- store payloads in Redis under account and channel keys
- optionally persist trade history to PostgreSQL or another database for long-term reporting

### 5. Use the bundled Redis proxy

This repository now includes a ready-to-run Redis HTTP proxy in [redis_http_proxy](./redis_http_proxy).

Use these guides:

- local and Docker setup: [docs/redis-http-proxy-setup.md](./docs/redis-http-proxy-setup.md)
- VPS and hosted Redis setup: [docs/redis-vps-setup.md](./docs/redis-vps-setup.md)

## Example API Contract

The EA sends a `POST` request to:

```text
<RedisHttpBaseUrl><RedisHttpEndpointPath>
```

Example:

```text
https://api.example.com/api/v1/mt5/redis-sync
```

Suggested request body fields:

- `protocol_version`
- `ea_name`
- `ea_version`
- `mode`
- `channel_id`
- `timestamp`
- `account`
- `terminal`
- `copy_settings`
- `pnl`
- `open_positions`
- `pending_orders`
- `trade_history`

### Example payload excerpt

```json
{
  "protocol_version": "2",
  "ea_name": "FX Trade Copper",
  "ea_version": "3.10",
  "mode": "SLAVE",
  "channel_id": "default",
  "timestamp": 1776476400,
  "account": {
    "login": 433459541,
    "server": "Exness-MT5Trial7",
    "currency": "USD",
    "balance": 383.68,
    "equity": 385.17
  },
  "pnl": {
    "today": {
      "net": 14.25
    },
    "last_week": {
      "net": 72.10
    },
    "last_month": {
      "net": 218.40
    },
    "custom": {
      "net": 91.60
    }
  }
}
```

## Suggested Redis Key Design

The bundled proxy stores Redis data in a hybrid layout with latest-state keys and history structures.

Practical examples:

```text
mt5:account:<login>:summary
mt5:account:<login>:terminal
mt5:account:<login>:copy_settings
mt5:account:<login>:pnl
mt5:account:<login>:positions
mt5:account:<login>:orders
mt5:account:<login>:trade_history:latest
mt5:account:<login>:events
mt5:account:<login>:history:snapshots
mt5:account:<login>:history:deals:index
mt5:account:<login>:history:deals:by_ticket
mt5:channel:<channel_id>:accounts
```

This makes it easy for:

- dashboards
- reporting apps
- admin tools
- Telegram or Discord bots
- risk monitors
- trade history APIs

## Example App Use Cases

Once your API stores the EA payload in Redis, other apps can:

- show real-time account balance and equity
- show daily, weekly, and monthly PnL
- display trade history by account ID
- monitor open positions across many accounts
- build performance leaderboards
- build manager views for copied accounts
- trigger alerts when margin or equity drops

## Important Notes

- Redis export works in either master or slave mode
- each running EA exports the data of the account it is attached to
- the custom date range is exported from the dates configured in the EA inputs
- the EA does not query Redis directly; it publishes to your API
- `WebRequest()` is not available in the MT5 strategy tester
- if the API base URL is not listed in MT5 allowed WebRequest URLs, the export will fail

## Troubleshooting

### Copier issues

Common reasons the slave does not copy:

- master and slave have different `ChannelId`
- symbol mappings do not match broker symbols
- slave `AutoTrading` is off
- `Allow Algo Trading` is disabled
- the account is read-only or investor-password only
- copy schedule is blocking the current time
- old master trades were intentionally ignored on startup

### Redis export issues

Common reasons Redis export does not work:

- `EnableRedisHttpExport=false`
- `RedisHttpBaseUrl` is empty
- the MT5 allowed WebRequest URL list does not include your API base URL
- the API returns `401`, `403`, or `500`
- the auth header name or token is wrong
- `https://` is required but the URL is `http://`
- custom dates are invalid

Useful log messages:

- `Redis HTTP export enabled...`
- `Redis HTTP export failed...`
- `Redis HTTP export returned status ...`
- `Redis HTTP export connection restored.`
- `Volume adjusted on ...`
- `Slave trading blocked...`
- `Slave copy skipped...`

## Build And Deploy

This repository includes [build_install.ps1](./build_install.ps1), which:

- finds the `.mq5` source file
- compiles it with MetaEditor
- stores the final compiled `.ex5` in the local `build` folder
- copies the compiled `.ex5` into detected MT5 `MQL5\Experts` folders

### Build artifact layout

The `build/` folder is now flat and contains only the compiled EA files:

Example:

```text
build/fx_trade_copper.ex5
build/fx_trade_copper_redis_exporter.ex5
```

Compile logs are written beside the project files, for example:

```text
metaeditor-fx_trade_copper.log
metaeditor-fx_trade_copper_redis_exporter.log
```

Run it from PowerShell:

```powershell
.\build_install.ps1
```

Or target a specific source file:

```powershell
.\build_install.ps1 -File .\fx_trade_copper.mq5
```

Compile the Redis-only exporter:

```powershell
.\build_install.ps1 -File .\fx_trade_copper_redis_exporter.mq5
```

If PowerShell blocks local script execution, run it with:

```powershell
powershell -ExecutionPolicy Bypass -File .\build_install.ps1 -File .\fx_trade_copper.mq5
```

If MT5 terminal deployment fails because of Windows file permissions, the build artifacts in the local `build` folder are still created and can be copied manually.

## Version

Current EA version: `3.12`

## MQL5 References

The Redis export uses official MQL5 APIs such as `WebRequest()`, `HistorySelect()`, and `HistoryDealGetDouble()`:

- https://www.mql5.com/en/docs/network/webrequest
- https://www.mql5.com/en/docs/trading/historyselect
- https://www.mql5.com/en/docs/trading/historydealgetdouble
- https://www.mql5.com/en/docs/constants/tradingconstants/dealproperties

## License

Copyright 2024-2026, FX Trade Copper  
https://www.allanmaug.com
