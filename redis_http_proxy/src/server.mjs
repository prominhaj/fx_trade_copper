import crypto from "node:crypto";
import Fastify from "fastify";
import { createClient } from "redis";
import { loadConfig } from "./config.mjs";
import { storePayload, readChannelAccounts, readLatestAccountState, readLatestDeals } from "./store.mjs";

const config = loadConfig();

const fastify = Fastify({
  logger: config.logRequests
});

fastify.decorateRequest("rawBody", "");

fastify.addContentTypeParser(
  ["application/json", "application/*+json"],
  { parseAs: "string" },
  (request, body, done) => {
    request.rawBody = body;
    try {
      done(null, JSON.parse(body));
    } catch (error) {
      error.statusCode = 400;
      done(error);
    }
  }
);

const redis = createClient({
  url: config.redisUrl
});

redis.on("error", (error) => {
  fastify.log.error({ err: error }, "Redis client error");
});

function extractHeader(request, name) {
  return String(request.headers[name] ?? "").trim();
}

function isTokenAuthValid(request) {
  if (!config.authToken) {
    return config.authMode === "off";
  }

  const headerValue = extractHeader(request, config.authHeaderName);
  if (!headerValue) {
    return false;
  }

  const lowered = config.authHeaderName === "authorization";
  if (lowered) {
    const bearerValue = `bearer ${config.authToken}`;
    return headerValue.toLowerCase() === bearerValue || headerValue === config.authToken;
  }

  return headerValue === config.authToken;
}

function isSignatureAuthValid(request) {
  if (!config.signingSecret) {
    return false;
  }

  const timestampHeader = extractHeader(request, config.timestampHeaderName);
  const signatureHeader = extractHeader(request, config.signatureHeaderName);
  if (!timestampHeader || !signatureHeader || !request.rawBody) {
    return false;
  }

  const requestTimestamp = Number.parseInt(timestampHeader, 10);
  const currentTimestamp = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(requestTimestamp)) {
    return false;
  }

  if (Math.abs(currentTimestamp - requestTimestamp) > config.maxSignatureAgeSec) {
    return false;
  }

  const canonical = `${timestampHeader}.${request.rawBody}`;
  const expected = crypto.createHmac("sha256", config.signingSecret).update(canonical).digest("hex");
  const provided = signatureHeader.startsWith("sha256=") ? signatureHeader.slice(7) : signatureHeader;

  try {
    return crypto.timingSafeEqual(Buffer.from(expected, "utf8"), Buffer.from(provided, "utf8"));
  } catch {
    return false;
  }
}

async function requireAuth(request, reply) {
  if (config.authMode === "off") {
    return;
  }

  const tokenValid = isTokenAuthValid(request);
  const signatureValid = isSignatureAuthValid(request);

  let allowed = false;
  if (config.authMode === "token") {
    allowed = tokenValid;
  } else if (config.authMode === "signature") {
    allowed = signatureValid;
  } else if (config.authMode === "hybrid") {
    allowed = tokenValid || signatureValid;
  }

  if (!allowed) {
    return reply.code(401).send({
      ok: false,
      error: "Unauthorized"
    });
  }
}

const payloadSchema = {
  body: {
    type: "object",
    required: ["protocol_version", "ea_name", "ea_version", "mode", "channel_id", "timestamp", "account"],
    properties: {
      protocol_version: { type: "string" },
      ea_name: { type: "string" },
      ea_version: { type: "string" },
      mode: { type: "string" },
      channel_id: { type: "string" },
      timestamp: { anyOf: [{ type: "integer" }, { type: "number" }] },
      timestamp_text: { type: "string" },
      account: {
        type: "object",
        required: ["login"],
        properties: {
          login: { anyOf: [{ type: "integer" }, { type: "number" }, { type: "string" }] }
        },
        additionalProperties: true
      },
      terminal: { type: "object", additionalProperties: true },
      copy_settings: { type: "object", additionalProperties: true },
      pnl: { type: "object", additionalProperties: true },
      open_positions: { type: "array" },
      pending_orders: { type: "array" },
      trade_history: { type: "array" }
    },
    additionalProperties: true
  }
};

fastify.get("/health", async () => ({
  ok: true,
  service: config.appName,
  timestamp: new Date().toISOString()
}));

fastify.get("/ready", async (_request, reply) => {
  try {
    await redis.ping();
    return {
      ok: true,
      redis: "ready"
    };
  } catch (error) {
    reply.code(503);
    return {
      ok: false,
      redis: "unavailable",
      error: error.message
    };
  }
});

fastify.post(
  "/api/v1/mt5/redis-sync",
  {
    schema: payloadSchema,
    preHandler: requireAuth
  },
  async (request, reply) => {
    const result = await storePayload(redis, config, request.body);
    reply.code(202).send({
      ok: true,
      stored: true,
      account_id: result.accountId,
      channel_id: result.channelId,
      counts: result.counts
    });
  }
);

if (config.enableReadApi) {
  fastify.get(
    "/api/v1/accounts/:accountId/latest",
    {
      preHandler: requireAuth
    },
    async (request) => {
      return readLatestAccountState(redis, config, request.params.accountId);
    }
  );

  fastify.get(
    "/api/v1/accounts/:accountId/deals",
    {
      preHandler: requireAuth
    },
    async (request) => {
      const limit = Number.parseInt(String(request.query.limit ?? "100"), 10) || 100;
      return {
        account_id: request.params.accountId,
        deals: await readLatestDeals(redis, config, request.params.accountId, limit)
      };
    }
  );

  fastify.get(
    "/api/v1/channels/:channelId/accounts",
    {
      preHandler: requireAuth
    },
    async (request) => {
      return {
        channel_id: request.params.channelId,
        accounts: await readChannelAccounts(redis, config, request.params.channelId)
      };
    }
  );
}

fastify.setErrorHandler((error, _request, reply) => {
  const statusCode = error.statusCode && error.statusCode >= 400 ? error.statusCode : 500;
  reply.code(statusCode).send({
    ok: false,
    error: error.message
  });
});

async function start() {
  await redis.connect();
  await fastify.listen({
    host: config.host,
    port: config.port
  });
}

start().catch((error) => {
  fastify.log.error({ err: error }, "Unable to start Redis HTTP proxy");
  process.exit(1);
});
