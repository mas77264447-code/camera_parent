require("dotenv").config();
const crypto = require("crypto");
const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");

const UPSTASH_URL = process.env.UPSTASH_REDIS_REST_URL;
const UPSTASH_TOKEN = process.env.UPSTASH_REDIS_REST_TOKEN;

if (!UPSTASH_URL || !UPSTASH_TOKEN) {
  console.error("[ERROR] Missing UPSTASH Redis env vars!");
  process.exit(1);
}

const redis = {
  async get(k) {
    try {
      const res = await fetch(`${UPSTASH_URL}/get/${k}`, {
        headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` },
      });
      const data = await res.json();
      return data.result || null;
    } catch (e) {
      console.error(`[Redis GET Error] ${k}:`, e.message);
      return null;
    }
  },
  async set(k, v, opts) {
    try {
      const value = typeof v === "string" ? v : JSON.stringify(v);
      let url = `${UPSTASH_URL}/set/${k}/${encodeURIComponent(value)}`;
      if (opts?.ex) url += `/EX/${opts.ex}`;
      const res = await fetch(url, {
        headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` },
      });
      const data = await res.json();
      return data.result ? "OK" : null;
    } catch (e) {
      console.error(`[Redis SET Error] ${k}:`, e.message);
      return null;
    }
  },
  async del(k) {
    try {
      const res = await fetch(`${UPSTASH_URL}/del/${k}`, {
        headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` },
      });
      const data = await res.json();
      return data.result ? 1 : 0;
    } catch (e) {
      return 0;
    }
  },
  async sadd(key, member) {
    try {
      const res = await fetch(
        `${UPSTASH_URL}/sadd/${key}/${encodeURIComponent(member)}`,
        { headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` } }
      );
      const data = await res.json();
      return data.result ? 1 : 0;
    } catch (e) {
      return 0;
    }
  },
  async srem(key, member) {
    try {
      const res = await fetch(
        `${UPSTASH_URL}/srem/${key}/${encodeURIComponent(member)}`,
        { headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` } }
      );
      const data = await res.json();
      return data.result ? 1 : 0;
    } catch (e) {
      return 0;
    }
  },
  async smembers(key) {
    try {
      const res = await fetch(`${UPSTASH_URL}/smembers/${key}`, {
        headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` },
      });
      const data = await res.json();
      return Array.isArray(data.result) ? data.result : [];
    } catch (e) {
      return [];
    }
  },
};

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/signal" });

app.use(express.json({ limit: "64kb" }));
app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS");
  res.header(
    "Access-Control-Allow-Headers",
    "Content-Type, X-Admin-Token, X-Device-Token"
  );
  next();
});

async function getOrCreateAdminToken() {
  if (process.env.ADMIN_TOKEN) return process.env.ADMIN_TOKEN;
  const existing = await redis.get("admin:token");
  if (existing) return existing;
  const generated = crypto.randomBytes(32).toString("hex");
  await redis.set("admin:token", generated);
  return generated;
}

let ADMIN_TOKEN = null;

const RATE_WINDOW_MS = 60 * 1000;
const authAttempts = new Map();
const wsAttempts = new Map();

function clientIp(req) {
  return String(
    req.headers["x-forwarded-for"] || req.socket.remoteAddress || "unknown"
  )
    .split(",")[0]
    .trim();
}

function rateLimit(map, key, limit) {
  const now = Date.now();
  const item = map.get(key);
  if (!item || now - item.startedAt >= RATE_WINDOW_MS) {
    map.set(key, { startedAt: now, count: 1 });
    return true;
  }
  item.count += 1;
  return item.count <= limit;
}

function safeText(value, max = 256) {
  return String(value ?? "").trim().slice(0, max);
}

function safeCompare(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function hashPasswordAsync(password, salt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, (err, hash) => {
      if (err) reject(err);
      else resolve(hash.toString("hex"));
    });
  });
}

async function verifyPasswordAsync(password, salt, expectedHash) {
  try {
    const candidate = await hashPasswordAsync(password, salt);
    const a = Buffer.from(candidate, "hex");
    const b = Buffer.from(expectedHash, "hex");
    if (a.length !== b.length) return false;
    return crypto.timingSafeEqual(a, b);
  } catch (e) {
    return false;
  }
}

app.post("/admin/claim", async (req, res) => {
  const claimed = await redis.get("admin:claimed");
  if (claimed) {
    return res
      .status(403)
      .json({ error: "تم ربط هذا السيرفر بحساب والد بالفعل." });
  }
  await redis.set("admin:claimed", String(Date.now()));
  res.json({ data: { admin_token: ADMIN_TOKEN } });
});

app.post("/admin/verify", (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `verify:${ip}`, 10)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const token = (req.body && req.body.admin_token) || "";
  if (token && safeCompare(token, ADMIN_TOKEN)) {
    res.json({ data: { valid: true } });
  } else {
    res.status(403).json({ error: "توكن غير صحيح." });
  }
});

async function isValidOwnerToken(token) {
  if (typeof token !== "string" || token.length === 0) return false;
  if (safeCompare(token, ADMIN_TOKEN)) return true;
  const owner = await redis.get(`parenttoken:${token}`);
  return !!owner;
}

async function requireAdminToken(req, res, next) {
  const provided = req.query.token || req.header("x-admin-token");
  if (await isValidOwnerToken(provided)) {
    req.ownerToken = provided;
    return next();
  }
  res.status(403).send("غير مصرح لك بالدخول هنا.");
}

const clients = {};
const live = {};

function generateClientId() {
  let id;
  do {
    id = crypto.randomBytes(9).toString("hex");
  } while (clients[id]);
  return id;
}

function inSameSession(client, targetId) {
  const sid = client && client.sessionId;
  if (!sid) return false;
  const ls = live[sid];
  if (!ls) return false;
  if (ls.broadcaster === targetId) return true;
  return ls.viewers.has(targetId);
}

function getLive(sessionId) {
  if (!live[sessionId]) {
    live[sessionId] = { broadcaster: null, viewers: new Map() };
  }
  return live[sessionId];
}

function send(clientId, data) {
  const c = clients[clientId];
  if (c && c.ws.readyState === 1) {
    c.ws.send(JSON.stringify(data));
  }
}

function generatePairingCode() {
  return String(crypto.randomInt(100000, 1000000));
}

const PAIRING_CODE_TTL_SECONDS = 5 * 60;

function normalizeUsername(u) {
  return String(u || "").trim().toLowerCase();
}

app.post("/parent/register", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-register:${ip}`, 10)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = normalizeUsername(req.body && req.body.username);
  const password = String((req.body && req.body.password) || "");

  if (username.length < 3) {
    return res
      .status(400)
      .json({ error: "اسم المستخدم لازم 3 أحرف على الأقل." });
  }
  if (password.length < 8) {
    return res
      .status(400)
      .json({ error: "كلمة المرور لازم 8 أحرف على الأقل." });
  }

  const credKey = `parent:credentials:${username}`;
  const existing = await redis.get(credKey);
  if (existing) {
    return res.status(409).json({ error: "اسم المستخدم مستخدم بالفعل." });
  }

  const parentToken = crypto.randomBytes(32).toString("hex");
  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = await hashPasswordAsync(password, salt);

  await redis.set(
    credKey,
    JSON.stringify({
      salt,
      passwordHash,
      parentToken,
      username,
      createdAt: Date.now(),
    })
  );

  await redis.set(`parenttoken:${parentToken}`, username);

  console.log(`[parent] new account: ${username}`);

  return res.json({
    data: { admin_token: parentToken, username },
  });
});

app.post("/parent/login", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-login:${ip}`, 20)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = normalizeUsername(req.body && req.body.username);
  const password = String((req.body && req.body.password) || "");

  if (!username || !password) {
    return res
      .status(400)
      .json({ error: "لازم تدخل اسم المستخدم وكلمة المرور." });
  }

  const credKey = `parent:credentials:${username}`;
  const raw = await redis.get(credKey);
  if (!raw) {
    return res
      .status(401)
      .json({ error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
  }

  const entry = typeof raw === "string" ? JSON.parse(raw) : raw;
  const ok = await verifyPasswordAsync(password, entry.salt, entry.passwordHash);
  if (!ok) {
    return res
      .status(401)
      .json({ error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
  }

  await redis.set(`parenttoken:${entry.parentToken}`, username);

  console.log(`[parent] login: ${username}`);
  return res.json({
    data: { admin_token: entry.parentToken, username },
  });
});

app.post("/parent/reset-password", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-reset:${ip}`, 5)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }

  const username = normalizeUsername(req.body && req.body.username);
  const newPassword = String((req.body && req.body.new_password) || "");
  const adminToken = String((req.body && req.body.admin_token) || "");

  if (!adminToken || !safeCompare(adminToken, ADMIN_TOKEN)) {
    return res.status(403).json({ error: "التوكن الإداري غير صحيح." });
  }
  if (username.length < 3) {
    return res.status(400).json({ error: "اسم المستخدم غير صالح." });
  }
  if (newPassword.length < 8) {
    return res
      .status(400)
      .json({ error: "كلمة المرور الجديدة لازم 8 أحرف على الأقل." });
  }

  const credKey = `parent:credentials:${username}`;
  const existing = await redis.get(credKey);
  if (!existing) {
    return res.status(404).json({ error: "الحساب غير موجود." });
  }

  const entry = typeof existing === "string" ? JSON.parse(existing) : existing;
  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = await hashPasswordAsync(newPassword, salt);

  await redis.set(
    credKey,
    JSON.stringify({
      salt,
      passwordHash,
      parentToken: entry.parentToken,
      username,
      createdAt: entry.createdAt || Date.now(),
      updatedAt: Date.now(),
    })
  );

  console.log(`[parent] password reset: ${username}`);
  return res.json({ data: { success: true, username } });
});

app.post("/parent/delete", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-delete:${ip}`, 5)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }

  const username = normalizeUsername(req.body && req.body.username);
  const adminToken = String((req.body && req.body.admin_token) || "");

  if (!adminToken || !safeCompare(adminToken, ADMIN_TOKEN)) {
    return res.status(403).json({ error: "التوكن الإداري غير صحيح." });
  }
  if (username.length < 3) {
    return res.status(400).json({ error: "اسم المستخدم غير صالح." });
  }

  const credKey = `parent:credentials:${username}`;
  const raw = await redis.get(credKey);
  if (!raw) {
    return res.status(404).json({ error: "الحساب غير موجود." });
  }

  const entry = typeof raw === "string" ? JSON.parse(raw) : raw;

  if (entry.parentToken) {
    await redis.del(`parenttoken:${entry.parentToken}`);
  }
  await redis.del(credKey);
  await redis.del(`child:byowner:${username}`);

  console.log(`[parent] account deleted: ${username}`);
  return res.json({ data: { deleted: true, username } });
});

app.post("/pairing/create", requireAdminToken, async (req, res) => {
  let code = generatePairingCode();
  for (let i = 0; i < 5; i++) {
    const exists = await redis.get(`pairing:${code}`);
    if (!exists) break;
    code = generatePairingCode();
  }
  await redis.set(
    `pairing:${code}`,
    JSON.stringify({ ownerToken: req.ownerToken }),
    { ex: PAIRING_CODE_TTL_SECONDS }
  );
  res.json({
    data: { code, expires_in_seconds: PAIRING_CODE_TTL_SECONDS },
  });
});

app.post("/pairing/claim", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `claim-pairing:${ip}`, 12)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();
  const deviceName =
    (req.body && req.body.device_name && String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";

  const raw = await redis.get(`pairing:${code}`);
  if (!raw) {
    return res
      .status(400)
      .json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
  }
  await redis.del(`pairing:${code}`);

  const entry = typeof raw === "string" ? JSON.parse(raw) : raw;
  const ownerToken = entry.ownerToken;

  const sessionId = crypto.randomBytes(16).toString("hex");
  const deviceToken = crypto.randomBytes(24).toString("hex");

  await redis.set(
    `session:${sessionId}`,
    JSON.stringify({
      name: deviceName,
      createdAt: Date.now(),
      ownerToken,
      deviceToken,
    })
  );
  await redis.set(
    `device:${deviceToken}`,
    JSON.stringify({
      sessionId,
      ownerToken,
      deviceName,
      pairedAt: Date.now(),
    })
  );
  await redis.sadd(`owner:${ownerToken}:sessions`, sessionId);

  res.json({
    data: {
      device_token: deviceToken,
      session_id: sessionId,
      device_name: deviceName,
    },
  });
});

app.post("/pairing/register", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `register:${ip}`, 12)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = (
    req.body && req.body.username ? String(req.body.username).trim() : ""
  ).toLowerCase();
  const password = req.body && req.body.password ? String(req.body.password) : "";
  const deviceName =
    (req.body && req.body.device_name && String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();

  if (!username || !password) {
    return res.status(400).json({ error: "لازم تدخل اسم المستخدم وكلمة المرور." });
  }
  if (password.length < 8) {
    return res
      .status(400)
      .json({ error: "كلمة المرور لازم تكون 8 أحرف على الأقل." });
  }

  const parentKey = `parent:credentials:${username}`;
  const parentRaw = await redis.get(parentKey);

  if (parentRaw) {
    const parentEntry =
      typeof parentRaw === "string" ? JSON.parse(parentRaw) : parentRaw;
    const ok = await verifyPasswordAsync(
      password,
      parentEntry.salt,
      parentEntry.passwordHash
    );
    if (!ok) {
      return res.status(401).json({
        error:
          "هذا الاسم محجوز لحساب والد. تأكد من كلمة المرور أو استخدم اسمًا آخر.",
      });
    }

    const existingChild = await redis.get(`child:byowner:${username}`);
    if (existingChild) {
      const childData =
        typeof existingChild === "string"
          ? JSON.parse(existingChild)
          : existingChild;
      console.log(`[child] existing linked session returned: ${username}`);
      return res.json({
        data: {
          device_token: childData.deviceToken,
          session_id: childData.sessionId,
          device_name: childData.deviceName,
        },
      });
    }

    const sessionId = crypto.randomBytes(16).toString("hex");
    const deviceToken = crypto.randomBytes(24).toString("hex");

    await redis.set(
      `session:${sessionId}`,
      JSON.stringify({
        name: deviceName,
        createdAt: Date.now(),
        ownerToken: parentEntry.parentToken,
        deviceToken,
        username,
      })
    );
    await redis.set(
      `device:${deviceToken}`,
      JSON.stringify({
        sessionId,
        ownerToken: parentEntry.parentToken,
        deviceName,
        pairedAt: Date.now(),
        username,
      })
    );
    await redis.sadd(
      `owner:${parentEntry.parentToken}:sessions`,
      sessionId
    );
    await redis.set(
      `child:byowner:${username}`,
      JSON.stringify({
        sessionId,
        deviceToken,
        deviceName,
        linkedAt: Date.now(),
      })
    );

    console.log(`[child] auto-linked to parent account: ${username}`);

    return res.json({
      data: {
        device_token: deviceToken,
        session_id: sessionId,
        device_name: deviceName,
      },
    });
  }

  const credKey = `credentials:${username}`;
  const raw = await redis.get(credKey);

  if (raw) {
    const entry = typeof raw === "string" ? JSON.parse(raw) : raw;
    const ok = await verifyPasswordAsync(
      password,
      entry.salt,
      entry.passwordHash
    );
    if (!ok) {
      return res
        .status(401)
        .json({ error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
    }
    return res.json({
      data: {
        device_token: entry.deviceToken,
        session_id: entry.sessionId,
        device_name: entry.deviceName,
      },
    });
  }

  if (!code) {
    return res
      .status(400)
      .json({ error: "لازم كود من تطبيق الوالد لأول تسجيل دخول." });
  }

  const pairingRaw = await redis.get(`pairing:${code}`);
  if (!pairingRaw) {
    return res
      .status(400)
      .json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
  }
  await redis.del(`pairing:${code}`);

  const pairingEntry =
    typeof pairingRaw === "string" ? JSON.parse(pairingRaw) : pairingRaw;
  const ownerToken = pairingEntry.ownerToken;

  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = await hashPasswordAsync(password, salt);

  const sessionId = crypto.randomBytes(16).toString("hex");
  const deviceToken = crypto.randomBytes(24).toString("hex");

  await redis.set(
    `session:${sessionId}`,
    JSON.stringify({
      name: deviceName,
      createdAt: Date.now(),
      ownerToken,
      deviceToken,
      username,
    })
  );
  await redis.set(
    `device:${deviceToken}`,
    JSON.stringify({
      sessionId,
      ownerToken,
      deviceName,
      pairedAt: Date.now(),
      username,
    })
  );
  await redis.sadd(`owner:${ownerToken}:sessions`, sessionId);
  await redis.set(
    credKey,
    JSON.stringify({
      salt,
      passwordHash,
      sessionId,
      deviceToken,
      deviceName,
      createdAt: Date.now(),
    })
  );

  res.json({
    data: {
      device_token: deviceToken,
      session_id: sessionId,
      device_name: deviceName,
    },
  });
});

app.post("/pairing/unpair", async (req, res) => {
  const deviceToken = req.header("x-device-token") || "";
  const raw = await redis.get(`device:${deviceToken}`);
  if (!raw) return res.status(404).json({ error: "الجهاز غير مقترن." });

  const info = typeof raw === "string" ? JSON.parse(raw) : raw;
  await redis.del(`device:${deviceToken}`);
  await redis.del(`session:${info.sessionId}`);
  await redis.srem(`owner:${info.ownerToken}:sessions`, info.sessionId);

  if (info.username) {
    await redis.del(`child:byowner:${info.username}`);
  }

  const liveSession = live[info.sessionId];
  if (liveSession && liveSession.broadcaster) {
    const bClient = clients[liveSession.broadcaster];
    if (bClient) {
      try {
        bClient.ws.close();
      } catch (e) {}
    }
  }
  delete live[info.sessionId];
  res.json({ data: { unpaired: true } });
});

app.get("/camera/sessions", requireAdminToken, async (req, res) => {
  const requesterToken = req.query.token || req.header("x-admin-token");
  const sessionIds =
    (await redis.smembers(`owner:${requesterToken}:sessions`)) || [];
  const list = [];
  for (const sessionId of sessionIds) {
    const raw = await redis.get(`session:${sessionId}`);
    if (!raw) continue;
    const s = typeof raw === "string" ? JSON.parse(raw) : raw;
    const liveSession = live[sessionId];
    list.push({
      session_id: sessionId,
      name: s.name,
      online: !!(liveSession && liveSession.broadcaster),
      viewers: liveSession ? liveSession.viewers.size : 0,
      created_at: s.createdAt,
    });
  }
  list.sort((a, b) => b.created_at - a.created_at);
  res.json({ data: list });
});

app.delete("/camera/sessions/:id", requireAdminToken, async (req, res) => {
  const requesterToken = req.query.token || req.header("x-admin-token");
  const sessionId = req.params.id;
  const raw = await redis.get(`session:${sessionId}`);
  if (!raw) return res.status(404).json({ error: "الجهاز غير موجود." });
  const s = typeof raw === "string" ? JSON.parse(raw) : raw;
  if (s.ownerToken !== requesterToken) {
    return res.status(404).json({ error: "الجهاز غير موجود." });
  }

  const liveSession = live[sessionId];
  if (liveSession && liveSession.broadcaster) {
    const bClient = clients[liveSession.broadcaster];
    if (bClient) {
      try {
        bClient.ws.close();
      } catch (e) {}
    }
  }
  delete live[sessionId];

  if (s.deviceToken) await redis.del(`device:${s.deviceToken}`);
  if (s.username) await redis.del(`child:byowner:${s.username}`);
  await redis.del(`session:${sessionId}`);
  await redis.srem(`owner:${s.ownerToken}:sessions`, sessionId);
  res.json({ data: { deleted: true } });
});

wss.on("connection", (ws, req) => {
  const ip = clientIp(req);
  if (!rateLimit(wsAttempts, ip, 30)) {
    try {
      ws.close(1013, "rate limited");
    } catch (_) {}
    return;
  }

  const clientId = generateClientId();
  ws._clientId = clientId;
  clients[clientId] = {
    ws,
    sessionId: null,
    role: null,
    lastMessageAt: Date.now(),
  };

  ws.isAlive = true;
  ws.on("pong", () => {
    ws.isAlive = true;
    const c = clients[clientId];
    if (c) c.lastMessageAt = Date.now();
  });

  ws.on("message", async (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (e) {
      return;
    }

    const client = clients[clientId];
    if (!client) return;
    client.lastMessageAt = Date.now();

    if (msg.type === "ping") {
      send(clientId, { type: "pong", timestamp: msg.timestamp || Date.now() });
      return;
    }

    if (msg.type === "register") {
      const { role, session } = msg;

      if (role === "broadcaster") {
        const deviceToken = safeText(msg.deviceToken, 128);
        const rawDevice = await redis.get(`device:${deviceToken}`);
        if (!rawDevice) {
          send(clientId, { type: "auth-failed", reason: "device_not_paired" });
          return;
        }

        const deviceInfo =
          typeof rawDevice === "string" ? JSON.parse(rawDevice) : rawDevice;
        const rawSession = await redis.get(`session:${deviceInfo.sessionId}`);
        if (!rawSession) {
          send(clientId, { type: "auth-failed", reason: "device_not_paired" });
          return;
        }

        const boundSession = deviceInfo.sessionId;
        client.sessionId = boundSession;
        client.role = role;
        const liveSession = getLive(boundSession);
        liveSession.broadcaster = clientId;

        console.log(
          `[ws] broadcaster: client=${clientId} session=${boundSession} name=${deviceInfo.deviceName}`
        );

        liveSession.viewers.forEach((info, viewerId) => {
          if (info.approved) {
            send(clientId, {
              type: "viewer-joined",
              viewerId,
              name: info.name,
              source: info.source,
            });
          } else {
            send(clientId, {
              type: "join-request",
              viewerId,
              name: info.name,
              source: info.source,
            });
          }
        });
        return;
      }

      if (role === "viewer") {
        const adminToken = safeText(msg.adminToken, 256);
        const rawSession = await redis.get(`session:${session}`);
        const targetSession = rawSession
          ? typeof rawSession === "string"
            ? JSON.parse(rawSession)
            : rawSession
          : null;

        if (!targetSession || !safeCompare(adminToken, targetSession.ownerToken)) {
          console.log(`[ws] viewer auth-failed: client=${clientId}`);
          send(clientId, { type: "auth-failed", reason: "not_authorized" });
          return;
        }

        client.sessionId = session;
        client.role = role;
        client.callerName = msg.name || "الوالد";

        const requestedSource =
          msg.requestedSource === "screen"
            ? "screen"
            : msg.requestedSource === "files"
            ? "files"
            : "camera";

        // ✅ viewers من نوع files: موافقة تلقائية
        const autoApprove = requestedSource === "files";
        const liveSession = getLive(session);

        liveSession.viewers.set(clientId, {
          name: client.callerName,
          approved: autoApprove,
          source: requestedSource,
        });

        console.log(
          `[ws] viewer: client=${clientId} session=${session} broadcaster=${!!liveSession.broadcaster} source=${requestedSource} autoApprove=${autoApprove}`
        );

        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, {
            type: autoApprove ? "viewer-joined" : "join-request",
            viewerId: clientId,
            name: client.callerName,
            source: requestedSource,
          });
          // ✅ إشعار الوالد بالموافقة
          if (autoApprove) {
            send(clientId, { type: "viewer-approved" });
          }
        } else {
          send(clientId, { type: "await-approval" });
        }
        return;
      }
      return;
    }

    if (msg.type === "leave-viewer" || msg.type === "leave-broadcaster") {
      const sessionId = client.sessionId;
      const liveSession = sessionId ? live[sessionId] : null;
      if (liveSession) {
        if (client.role === "viewer") {
          liveSession.viewers.delete(clientId);
          if (liveSession.broadcaster) {
            send(liveSession.broadcaster, {
              type: "viewer-left",
              viewerId: clientId,
            });
          }
        } else if (
          client.role === "broadcaster" &&
          liveSession.broadcaster === clientId
        ) {
          liveSession.broadcaster = null;
          for (const [viewerId] of liveSession.viewers) {
            send(viewerId, { type: "broadcaster-left" });
          }
          liveSession.viewers.clear();
        }
        if (!liveSession.broadcaster && liveSession.viewers.size === 0) {
          delete live[sessionId];
        }
      }
      client.sessionId = null;
      client.role = null;
      try {
        client.ws.close(1000, "left");
      } catch (_) {}
      return;
    }

    if (msg.type === "approve-viewer") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      )
        return;
      const viewerInfo = liveSession.viewers.get(msg.target);
      if (!viewerInfo) return;
      viewerInfo.approved = true;
      // ✅ إشعار الوالد بأنه تمت الموافقة
      send(msg.target, { type: "viewer-approved" });
      console.log(`[ws] viewer approved: ${msg.target}`);
      return;
    }

    if (msg.type === "reject-viewer") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      )
        return;
      liveSession.viewers.delete(msg.target);
      send(msg.target, { type: "join-rejected" });
      const target = clients[msg.target];
      if (target) {
        try {
          target.ws.close();
        } catch (e) {}
      }
      return;
    }

    if (msg.type === "offer") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      )
        return;
      const viewerInfo = liveSession.viewers.get(msg.viewerId);
      if (!viewerInfo) return;
      send(msg.viewerId, { type: "offer", sdp: msg.sdp, from: clientId });
      return;
    }

    if (msg.type === "answer") {
      const liveSession = live[client.sessionId];
      if (
        client.role === "viewer" &&
        liveSession &&
        liveSession.broadcaster &&
        liveSession.viewers.has(clientId)
      ) {
        send(liveSession.broadcaster, {
          type: "answer",
          sdp: msg.sdp,
          viewerId: clientId,
        });
      }
      return;
    }

    if (msg.type === "ice") {
      if (!inSameSession(client, msg.target)) return;
      send(msg.target, {
        type: "ice",
        candidate: msg.candidate,
        from: clientId,
      });
      return;
    }

    if (msg.type === "switch-camera") {
      if (client.role !== "viewer" || !inSameSession(client, msg.target)) return;
      send(msg.target, { type: "switch-camera" });
      return;
    }

    // ✅ Wake command
    if (msg.type === "wake") {
      const liveSession = live[client.sessionId];
      if (
        client.role === "viewer" &&
        liveSession &&
        liveSession.broadcaster
      ) {
        send(liveSession.broadcaster, {
          type: "wake",
          viewerId: clientId,
          name: client.callerName,
        });
        send(clientId, { type: "wake-sent" });
        console.log(`[ws] wake sent: viewer=${clientId}`);
      } else {
        send(clientId, {
          type: "wake-failed",
          reason: "broadcaster-offline",
        });
        console.log(`[ws] wake failed: viewer=${clientId}`);
      }
      return;
    }

    if (msg.type === "toggle-mic") {
      if (client.role !== "viewer" || !inSameSession(client, msg.target)) return;
      send(msg.target, { type: "toggle-mic" });
      return;
    }

    // ✅ File / Gallery messages
    if (
      msg.type === "permission-request" ||
      msg.type === "file-browser-list" ||
      msg.type === "file-browser-download"
    ) {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "viewer" ||
        !liveSession ||
        !liveSession.broadcaster
      )
        return;

      const viewerInfo = liveSession.viewers.get(clientId);
      if (!viewerInfo || !viewerInfo.approved) return;

      const payload = { ...msg, viewerId: clientId };
      send(liveSession.broadcaster, payload);
      return;
    }

    if (
      msg.type === "permission-response" ||
      msg.type === "file-browser-list-response"
    ) {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      )
        return;
      const target = String(msg.target || "");
      const viewerInfo = liveSession.viewers.get(target);
      if (!viewerInfo) return;
      const { target: _, ...rest } = msg;
      send(target, rest);
      return;
    }

    if (
      msg.type === "file-transfer-start" ||
      msg.type === "file-transfer-chunk" ||
      msg.type === "file-transfer-end"
    ) {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      )
        return;
      const target = String(msg.target || "");
      const viewerInfo = liveSession.viewers.get(target);
      if (!viewerInfo) return;
      const { target: _, ...rest } = msg;
      send(target, rest);
      return;
    }

    if (msg.type === "kick") {
      const liveSession = live[client.sessionId];
      if (
        client.role === "broadcaster" &&
        liveSession &&
        liveSession.broadcaster === clientId
      ) {
        const target = clients[msg.target];
        if (target) {
          send(msg.target, { type: "kicked" });
          try {
            target.ws.close();
          } catch (e) {}
        }
      }
      return;
    }
  });

  ws.on("close", () => {
    const client = clients[clientId];
    if (client && client.sessionId && live[client.sessionId]) {
      const liveSession = live[client.sessionId];
      if (
        client.role === "broadcaster" &&
        liveSession.broadcaster === clientId
      ) {
        liveSession.broadcaster = null;
        for (const [viewerId] of liveSession.viewers) {
          send(viewerId, { type: "broadcaster-left" });
        }
        liveSession.viewers.clear();
      }
      if (client.role === "viewer") {
        liveSession.viewers.delete(clientId);
        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, {
            type: "viewer-left",
            viewerId: clientId,
          });
        }
      }
      if (!liveSession.broadcaster && liveSession.viewers.size === 0) {
        delete live[client.sessionId];
      }
    }
    delete clients[clientId];
  });
});

const HEARTBEAT_INTERVAL = 10000;
const WS_IDLE_TIMEOUT = 35000;

const heartbeatInterval = setInterval(() => {
  const now = Date.now();
  wss.clients.forEach((ws) => {
    const clientId = ws._clientId || null;
    const client = clientId ? clients[clientId] : null;

    if (client && now - client.lastMessageAt > WS_IDLE_TIMEOUT) {
      return ws.terminate();
    }
    if (ws.isAlive === false) return ws.terminate();
    ws.isAlive = false;
    try {
      ws.ping();
    } catch (_) {}
  });
}, HEARTBEAT_INTERVAL);

wss.on("close", () => clearInterval(heartbeatInterval));

let _warnedNoPrivateTurn = false;

function getIceServers() {
  const stunServers = [
    { urls: "stun:stun.l.google.com:19302" },
    { urls: "stun:stun1.l.google.com:19302" },
    { urls: "stun:stun2.l.google.com:19302" },
    { urls: "stun:stun3.l.google.com:19302" },
    { urls: "stun:stun4.l.google.com:19302" },
  ];

  const turnUrls = (process.env.TURN_URLS || "").trim();
  if (turnUrls) {
    const username = process.env.TURN_USERNAME || "";
    const credential = process.env.TURN_CREDENTIAL || "";
    const urls = turnUrls
      .split(",")
      .map((u) => u.trim())
      .filter(Boolean);
    return [
      ...stunServers,
      ...urls.map((urls_) => ({ urls: urls_, username, credential })),
    ];
  }

  if (!_warnedNoPrivateTurn) {
    _warnedNoPrivateTurn = true;
    console.warn("[camera-parent] مفيش TURN_URLS - fallback openrelay");
  }

  return [
    ...stunServers,
    {
      urls: "turn:openrelay.metered.ca:80",
      username: "openrelayproject",
      credential: "openrelayproject",
    },
    {
      urls: "turn:openrelay.metered.ca:443",
      username: "openrelayproject",
      credential: "openrelayproject",
    },
    {
      urls: "turn:openrelay.metered.ca:443?transport=tcp",
      username: "openrelayproject",
      credential: "openrelayproject",
    },
  ];
}

app.get("/ice-servers", (req, res) => {
  res.json({ data: getIceServers() });
});

app.get("/stats", requireAdminToken, (req, res) => {
  const now = Date.now();
  const clientDetails = Object.entries(clients).map(([id, c]) => ({
    id,
    role: c.role,
    sessionId: c.sessionId ? c.sessionId.slice(0, 8) + "..." : null,
    idleSeconds: Math.round((now - (c.lastMessageAt || now)) / 1000),
    wsState: c.ws?.readyState,
  }));
  res.json({
    totalClients: Object.keys(clients).length,
    activeSessions: Object.keys(live).length,
    clients: clientDetails,
    uptimeSeconds: Math.round(process.uptime()),
    timestamp: new Date().toISOString(),
  });
});

app.get("/", (req, res) => {
  res.send("Camera Parent server is running.");
});

const PORT = process.env.PORT || 8080;

(async () => {
  ADMIN_TOKEN = await getOrCreateAdminToken();
  console.log(`[camera-parent] ✅ ADMIN_TOKEN set (len=${ADMIN_TOKEN.length})`);
  console.log("[camera-parent] ✅ Upstash Redis connected");
  server.listen(PORT, () => {
    console.log(`✅ Server running on port ${PORT}`);
  });
})();

setInterval(() => {
  const cutoff = Date.now() - RATE_WINDOW_MS;
  for (const [k, v] of authAttempts)
    if (v.startedAt < cutoff) authAttempts.delete(k);
  for (const [k, v] of wsAttempts)
    if (v.startedAt < cutoff) wsAttempts.delete(k);
}, RATE_WINDOW_MS).unref();