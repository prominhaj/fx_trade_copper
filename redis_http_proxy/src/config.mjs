function parseBoolean(value, fallback = false) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }

  const normalized = String(value).trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }
  return fallback;
}

function parseInteger(value, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function loadConfig(env = process.env) {
  const authMode = String(env.AUTH_MODE ?? "token").trim().toLowerCase();
  const allowedAuthModes = new Set(["off", "token", "signature", "hybrid"]);

  return {
    appName: "FX Trade Copper Redis Proxy",
    host: String(env.PROXY_HOST ?? "0.0.0.0").trim(),
    port: parseInteger(env.PROXY_PORT, 8080),
    logRequests: parseBoolean(env.PROXY_LOG_REQUESTS, true),
    redisUrl: String(env.REDIS_URL ?? "redis://127.0.0.1:6379").trim(),
    redisKeyPrefix: String(env.REDIS_KEY_PREFIX ?? "mt5").trim() || "mt5",
    latestTtlSec: parseInteger(env.LATEST_TTL_SEC, 0),
    maxEventItems: parseInteger(env.MAX_EVENT_ITEMS, 1000),
    maxSnapshotItems: parseInteger(env.MAX_SNAPSHOT_ITEMS, 500),
    maxDealItems: parseInteger(env.MAX_DEAL_ITEMS, 3000),
    authMode: allowedAuthModes.has(authMode) ? authMode : "token",
    authHeaderName: String(env.AUTH_HEADER_NAME ?? "authorization").trim().toLowerCase(),
    authToken: String(env.AUTH_TOKEN ?? "").trim(),
    signatureHeaderName: String(env.SIGNATURE_HEADER_NAME ?? "x-ftc-signature").trim().toLowerCase(),
    timestampHeaderName: String(env.TIMESTAMP_HEADER_NAME ?? "x-ftc-timestamp").trim().toLowerCase(),
    signingSecret: String(env.SIGNING_SECRET ?? "").trim(),
    maxSignatureAgeSec: parseInteger(env.MAX_SIGNATURE_AGE_SEC, 300),
    enableReadApi: parseBoolean(env.ENABLE_READ_API, true)
  };
}
