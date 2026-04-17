# Trade Copier Upgrade Plan

## Goal

Upgrade the EA from a single shared-file copier into a channel-aware copier that:

- copies only live positions
- never copies pending or limit orders
- supports multiple slave accounts safely
- can run through a TCP relay for lower-latency fan-out
- keeps a file transport fallback for simple local deployments

## Design

### 1. Channel-based routing

Each EA instance now uses a `ChannelId`. The master publishes snapshots into one channel, and any slave subscribed to the same channel consumes them. This isolates copier groups cleanly and makes multi-slave deployments simple.

### 2. Dynamic symbol mapping

The old two-symbol input model is replaced with `SymbolMappings`, for example:

`XAUUSD.ecn=GOLD;USDJPY.ecn=USDJPY`

That lets one master drive many symbols without recompiling the EA.

### 3. Position-only protocol

The protocol only serializes open positions. Pending orders are not serialized and therefore are never copied. Each copied trade is tagged with a compact channel hash in the order comment so the slave can update and close only its own mirrored trades.

### 4. Socket relay

The relay keeps the latest snapshot per channel and broadcasts updates to all connected slaves on that channel. This makes one master -> many slave accounts practical without forcing every slave to poll a shared file.

### 5. File fallback

If socket deployment is not ready, both master and slave can still use `TRANSPORT_FILE`. The filename is channel-specific so several copier channels can coexist on one machine.

## Deployment Notes

1. Start `socket_relay.ps1` on the relay host.
2. In MT5, add the relay host to `Tools > Options > Expert Advisors`.
3. Set the master EA to `MODE_MASTER`, same `ChannelId`, and matching `SymbolMappings`.
4. Set each slave EA to `MODE_SLAVE`, same `ChannelId`, same `SymbolMappings`, and a slave-side `MagicNumber`.
5. Use different channels for separate copy groups.

## Known Assumptions

- One channel is expected to have one logical master source at a time.
- The slave account should support the broker execution mode for copied market orders.
- Netting accounts can merge positions by symbol, so hedging accounts are the safer choice for exact mirroring.
