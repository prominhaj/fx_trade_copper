function cleanPart(value, fallback = "default") {
  const normalized = String(value ?? "").trim();
  if (!normalized) {
    return fallback;
  }

  return normalized.replace(/[^a-zA-Z0-9:_-]/g, "_");
}

export function buildRedisKeys(prefix, accountId, channelId) {
  const root = cleanPart(prefix, "mt5");
  const account = cleanPart(accountId, "unknown");
  const channel = cleanPart(channelId, "default");
  const accountRoot = `${root}:account:${account}`;

  return {
    root,
    accountRoot,
    accountsSet: `${root}:accounts`,
    channelAccounts: `${root}:channel:${channel}:accounts`,
    summary: `${accountRoot}:summary`,
    terminal: `${accountRoot}:terminal`,
    copySettings: `${accountRoot}:copy_settings`,
    pnl: `${accountRoot}:pnl`,
    positions: `${accountRoot}:positions`,
    orders: `${accountRoot}:orders`,
    tradeHistoryLatest: `${accountRoot}:trade_history:latest`,
    latestPayload: `${accountRoot}:payload:latest`,
    meta: `${accountRoot}:meta`,
    events: `${accountRoot}:events`,
    snapshots: `${accountRoot}:history:snapshots`,
    dealsByTicket: `${accountRoot}:history:deals:by_ticket`,
    dealsIndex: `${accountRoot}:history:deals:index`
  };
}
