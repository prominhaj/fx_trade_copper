import { buildRedisKeys } from "./redis-keys.mjs";

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function toJson(value) {
  return JSON.stringify(value ?? null);
}

function accountTimestamp(payload) {
  const timestamp = Number(payload?.timestamp ?? 0);
  if (Number.isFinite(timestamp) && timestamp > 0) {
    return timestamp;
  }
  return Math.floor(Date.now() / 1000);
}

function buildSummary(payload) {
  const account = asObject(payload.account);
  return {
    ...account,
    protocol_version: payload.protocol_version ?? "2",
    ea_name: payload.ea_name ?? "",
    ea_version: payload.ea_version ?? "",
    mode: payload.mode ?? "",
    channel_id: payload.channel_id ?? "",
    timestamp: accountTimestamp(payload),
    timestamp_text: payload.timestamp_text ?? ""
  };
}

function buildMeta(payload, positions, orders, tradeHistory, receivedAtIso) {
  return {
    login: String(payload?.account?.login ?? ""),
    channel_id: String(payload?.channel_id ?? ""),
    mode: String(payload?.mode ?? ""),
    protocol_version: String(payload?.protocol_version ?? "2"),
    ea_name: String(payload?.ea_name ?? ""),
    ea_version: String(payload?.ea_version ?? ""),
    server: String(payload?.account?.server ?? ""),
    balance: String(payload?.account?.balance ?? ""),
    equity: String(payload?.account?.equity ?? ""),
    last_timestamp: String(accountTimestamp(payload)),
    last_timestamp_text: String(payload?.timestamp_text ?? ""),
    received_at: receivedAtIso,
    position_count: String(positions.length),
    order_count: String(orders.length),
    trade_history_count: String(tradeHistory.length)
  };
}

async function trimDealHistory(client, keys, maxDealItems) {
  if (maxDealItems < 1) {
    return;
  }

  const total = await client.zCard(keys.dealsIndex);
  if (total <= maxDealItems) {
    return;
  }

  const overflow = total - maxDealItems;
  const oldTickets = await client.zRange(keys.dealsIndex, 0, overflow - 1);
  const multi = client.multi();
  multi.zRemRangeByRank(keys.dealsIndex, 0, overflow - 1);
  if (oldTickets.length > 0) {
    multi.hDel(keys.dealsByTicket, oldTickets);
  }
  await multi.exec();
}

export async function storePayload(client, config, payload) {
  const account = asObject(payload.account);
  const accountId = String(account.login ?? "").trim();
  if (!accountId) {
    throw new Error("Payload is missing account.login");
  }

  const channelId = String(payload.channel_id ?? "default").trim() || "default";
  const keys = buildRedisKeys(config.redisKeyPrefix, accountId, channelId);
  const positions = asArray(payload.open_positions);
  const orders = asArray(payload.pending_orders);
  const tradeHistory = asArray(payload.trade_history);
  const pnl = asObject(payload.pnl);
  const terminal = asObject(payload.terminal);
  const copySettings = asObject(payload.copy_settings);
  const summary = buildSummary(payload);
  const receivedAtIso = new Date().toISOString();
  const meta = buildMeta(payload, positions, orders, tradeHistory, receivedAtIso);
  const nowTimestamp = accountTimestamp(payload);
  const event = {
    type: "account_snapshot_received",
    account_id: accountId,
    channel_id: channelId,
    mode: summary.mode,
    timestamp: nowTimestamp,
    received_at: receivedAtIso,
    position_count: positions.length,
    order_count: orders.length,
    trade_history_count: tradeHistory.length
  };
  const snapshotEntry = {
    account_id: accountId,
    channel_id: channelId,
    timestamp: nowTimestamp,
    received_at: receivedAtIso,
    payload
  };

  const latestKeys = [
    keys.summary,
    keys.terminal,
    keys.copySettings,
    keys.pnl,
    keys.positions,
    keys.orders,
    keys.tradeHistoryLatest,
    keys.latestPayload,
    keys.meta
  ];

  const multi = client.multi();
  multi.sAdd(keys.accountsSet, accountId);
  multi.sAdd(keys.channelAccounts, accountId);
  multi.set(keys.summary, toJson(summary));
  multi.set(keys.terminal, toJson(terminal));
  multi.set(keys.copySettings, toJson(copySettings));
  multi.set(keys.pnl, toJson(pnl));
  multi.set(keys.positions, toJson(positions));
  multi.set(keys.orders, toJson(orders));
  multi.set(keys.tradeHistoryLatest, toJson(tradeHistory));
  multi.set(keys.latestPayload, toJson(payload));
  multi.hSet(keys.meta, meta);
  multi.lPush(keys.events, toJson(event));
  multi.lTrim(keys.events, 0, Math.max(config.maxEventItems - 1, 0));
  multi.lPush(keys.snapshots, toJson(snapshotEntry));
  multi.lTrim(keys.snapshots, 0, Math.max(config.maxSnapshotItems - 1, 0));

  if (config.latestTtlSec > 0) {
    for (const key of latestKeys) {
      multi.expire(key, config.latestTtlSec);
    }
  }

  for (const deal of tradeHistory) {
    const ticket = String(deal?.ticket ?? "").trim();
    if (!ticket) {
      continue;
    }
    const score = Number(deal?.time ?? nowTimestamp);
    multi.hSet(keys.dealsByTicket, ticket, toJson(deal));
    multi.zAdd(keys.dealsIndex, [{ score: Number.isFinite(score) ? score : nowTimestamp, value: ticket }]);
  }

  await multi.exec();
  await trimDealHistory(client, keys, config.maxDealItems);

  return {
    accountId,
    channelId,
    keys,
    counts: {
      positions: positions.length,
      orders: orders.length,
      tradeHistory: tradeHistory.length
    }
  };
}

export async function readLatestAccountState(client, config, accountId) {
  const keys = buildRedisKeys(config.redisKeyPrefix, accountId, "default");
  const [summary, terminal, copySettings, pnl, positions, orders, tradeHistory] = await client.mGet([
    keys.summary,
    keys.terminal,
    keys.copySettings,
    keys.pnl,
    keys.positions,
    keys.orders,
    keys.tradeHistoryLatest
  ]);

  const hashMeta = await client.hGetAll(keys.meta);

  return {
    summary: summary ? JSON.parse(summary) : null,
    terminal: terminal ? JSON.parse(terminal) : null,
    copy_settings: copySettings ? JSON.parse(copySettings) : null,
    pnl: pnl ? JSON.parse(pnl) : null,
    open_positions: positions ? JSON.parse(positions) : [],
    pending_orders: orders ? JSON.parse(orders) : [],
    trade_history: tradeHistory ? JSON.parse(tradeHistory) : [],
    meta: Object.keys(hashMeta).length > 0 ? hashMeta : null
  };
}

export async function readLatestDeals(client, config, accountId, limit) {
  const keys = buildRedisKeys(config.redisKeyPrefix, accountId, "default");
  const size = Math.max(1, Math.min(limit, config.maxDealItems));
  const tickets = await client.zRange(keys.dealsIndex, 0, size - 1, { REV: true });
  if (tickets.length === 0) {
    return [];
  }

  const values = await client.hmGet(keys.dealsByTicket, tickets);
  return values
    .filter((value) => typeof value === "string" && value.length > 0)
    .map((value) => JSON.parse(value));
}

export async function readChannelAccounts(client, config, channelId) {
  const keys = buildRedisKeys(config.redisKeyPrefix, "placeholder", channelId);
  return client.sMembers(keys.channelAccounts);
}
