require("dotenv").config();
const crypto = require("crypto");
const fs = require("fs");
const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const admin = require("firebase-admin");
const { startKeepAlive, attachHeartbeat } = require("./keepalive");

// ═══════════════════════════════════════════════════════════
// Firebase Admin (FCM wake)
// ═══════════════════════════════════════════════════════════

let fcmAdmin = null;

function initFcm() {
  const secretPath =
    process.env.GOOGLE_APPLICATION_CREDENTIALS || "/etc/secrets/firebase-admin.json";

  if (fs.existsSync(secretPath)) {
    try {
      const serviceAccount = JSON.parse(fs.readFileSync(secretPath, "utf8"));
      fcmAdmin = admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
      });
      console.log("[fcm] ✅ Firebase Admin initialized (Secret File)");
      return;
    } catch (e) {
      console.error("[fcm] Secret File parse failed:", e.message);
    }
  }

  if (
    process.env.FIREBASE_PROJECT_ID &&
    process.env.FIREBASE_CLIENT_EMAIL &&
    process.env.FIREBASE_PRIVATE_KEY
  ) {
    try {
      fcmAdmin = admin.initializeApp({
        credential: admin.credential.cert({
          projectId: process.env.FIREBASE_PROJECT_ID,
          clientEmail: process.env.FIREBASE_CLIENT_EMAIL,
          privateKey: process.env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, "\n"),
        }),
      });
      console.log("[fcm] ✅ Firebase Admin initialized (Env Vars)");
      return;
    } catch (e) {
      console.error("[fcm] Env Vars init failed:", e.message);
    }
  }

  console.warn("[fcm] ⚠️ credentials missing — FCM disabled");
}

initFcm();

// ═══════════════════════════════════════════════════════════
// Upstash Redis
// ═══════════════════════════════════════════════════════════

const UPSTASH_URL = process.env.UPSTASH_REDIS_REST_URL;
const UPSTASH_TOKEN = process.env.UPSTASH_REDIS_REST_TOKEN;

if (!UPSTASH_URL || !UPSTASH_TOKEN) {
  console.error("[ERROR] Missing UPSTASH Redis env vars!");
  process.exit(1);
}

async function redisCommand(...args) {
  const res = await fetch(UPSTASH_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${UPSTASH_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`Redis HTTP ${res.status}`);
  const data = await res.json();
  if (data.error) throw new Error(`Redis error: ${data.error}`);
  return data.result;
}

const redis = {
  async get(k) {
    const v = await redisCommand("GET", k);
    return v ?? null;
  },
  async getdel(k) {
    const v = await redisCommand("GETDEL", k);
    return v ?? null;
  },
  async set(k, v, opts) {
    const value = typeof v === "string" ? v : JSON.stringify(v);
    const args = ["SET", k, value];
    if (opts?.ex) args.push("EX", String(opts.ex));
    const result = await redisCommand(...args);
    return result === "OK" ? "OK" : null;
  },
  async del(k) {
    return Number(await redisCommand("DEL", k));
  },
  async sadd(key, member) {
    return Number(await redisCommand("SADD", key, member));
  },
  async srem(key, member) {
    return Number(await redisCommand("SREM", key, member));
  },
  async smembers(key) {
    const result = await redisCommand("SMEMBERS", key);
    return Array.isArray(result) ? result : [];
  },
};

// ═══════════════════════════════════════════════════════════
// Express + WebSocket
// ═══════════════════════════════════════════════════════════

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/signal" });

// ✅ Heartbeat لمنع قطع WebSocket
attachHeartbeat(wss);

app.use(express.json({ limit: "64kb" }));
app.use(express.static("public"));

// ✅ نقطة نهاية الصحة
app.get("/health", (req, res) => {
  res.status(200).json({ ok: true, uptime: process.uptime(), ts: Date.now() });
});

const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || "")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

app.use((req, res, next) => {
  if (ALLOWED_ORIGINS.length === 0) {
    res.header("Access-Control-Allow-Origin", "*");
  } else {
    const origin = req.headers.origin;
    if (origin && ALLOWED_ORIGINS.includes(origin)) {
      res.header("Access-Control-Allow-Origin", origin);
      res.header("Vary", "Origin");
    }
  }
  res.header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS");
  res.header(
    "Access-Control-Allow-Headers",
    "Content-Type, X-Admin-Token, X-Device-Token"
  );
  next();
});

// ═══════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════

let ADMIN_TOKEN = null;

async function getOrCreateAdminToken() {
  if (process.env.ADMIN_TOKEN) return process.env.ADMIN_TOKEN;
  const existing = await redis.get("admin:token");
  if (existing) return existing;
  const generated = crypto.randomBytes(32).toString("hex");
  await redis.set("admin:token", generated);
  return generated;
}

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

function safeCompare(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function parseStored(raw) {
  return typeof raw === "string" ? JSON.parse(raw) : raw;
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

function computeViewerKey(sessionId, adminToken) {
  return crypto
    .createHash("sha256")
    .update(`${sessionId}|${adminToken}`)
    .digest("hex")
    .slice(0, 32);
}

function normalizeUsername(u) {
  return String(u || "").trim().toLowerCase();
}

function generatePairingCode() {
  return String(crypto.randomInt(100000, 1000000));
}

const PAIRING_CODE_TTL_SECONDS = 5 * 60;
const MAX_PAIRING_ATTEMPTS_PER_ACCOUNT = 5;

const clients = {};
const live = {};

function generateClientId() {
  let id;
  do {
    id = crypto.randomBytes(9).toString("hex");
  } while (clients[id]);
  return id;
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

function sendToViewer(liveSession, viewerKey, data) {
  const v = liveSession.viewers.get(viewerKey);
  if (v && v.currentClientId) {
    send(v.currentClientId, data);
  }
}

function closeBroadcasterOf(sessionId) {
  const liveSession = live[sessionId];
  if (liveSession && liveSession.broadcaster) {
    const bClient = clients[liveSession.broadcaster];
    if (bClient) {
      try { bClient.ws.close(); } catch (_) {}
    }
  }
}

// ═══════════════════════════════════════════════════════════
// Admin auth
// ═══════════════════════════════════════════════════════════

app.post("/admin/claim", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `claim:${ip}`, 5)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const locked = await redisCommand("SET", "admin:claimed", String(Date.now()), "NX");
  if (locked !== "OK") {
    return res.status(403).json({ error: "تم ربط هذا السيرفر بحساب والد بالفعل." });
  }
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
  try {
    const provided = req.query.token || req.header("x-admin-token");
    if (await isValidOwnerToken(provided)) {
      req.ownerToken = provided;
      return next();
    }
    res.status(403).send("غير مصرح لك بالدخول هنا.");
  } catch (e) {
    console.error("[auth] error:", e.message);
    res.status(503).json({ error: "temporary_unavailable", retry: true });
  }
}

// ═══════════════════════════════════════════════════════════
// PARENT ACCOUNT
// ═══════════════════════════════════════════════════════════

app.post("/parent/register", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-register:${ip}`, 10)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = normalizeUsername(req.body && req.body.username);
  const password = String((req.body && req.body.password) || "");

  if (username.length < 3) {
    return res.status(400).json({ error: "اسم المستخدم لازم 3 أحرف على الأقل." });
  }
  if (password.length < 8) {
    return res.status(400).json({ error: "كلمة المرور لازم 8 أحرف على الأقل." });
  }

  const credKey = `parent:credentials:${username}`;
  const parentToken = crypto.randomBytes(32).toString("hex");
  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = await hashPasswordAsync(password, salt);

  const created = await redisCommand(
    "SET",
    credKey,
    JSON.stringify({ salt, passwordHash, parentToken, username, createdAt: Date.now() }),
    "NX"
  );
  if (created !== "OK") {
    return res.status(409).json({ error: "اسم المستخدم مستخدم بالفعل." });
  }

  await redis.set(`parenttoken:${parentToken}`, username);
  console.log(`[parent] new account: ${username}`);

  return res.json({ data: { admin_token: parentToken, username } });
});

app.post("/parent/login", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-login:${ip}`, 20)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = normalizeUsername(req.body && req.body.username);
  const password = String((req.body && req.body.password) || "");

  if (!username || !password) {
    return res.status(400).json({ error: "لازم تدخل اسم المستخدم وكلمة المرور." });
  }

  const raw = await redis.get(`parent:credentials:${username}`);
  if (!raw) {
    return res.status(401).json({ error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
  }

  const entry = parseStored(raw);
  const ok = await verifyPasswordAsync(password, entry.salt, entry.passwordHash);
  if (!ok) {
    return res.status(401).json({ error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
  }

  await redis.set(`parenttoken:${entry.parentToken}`, username);
  console.log(`[parent] login: ${username}`);
  return res.json({ data: { admin_token: entry.parentToken, username } });
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
    return res.status(400).json({ error: "كلمة المرور الجديدة لازم 8 أحرف على الأقل." });
  }

  const credKey = `parent:credentials:${username}`;
  const raw = await redis.get(credKey);
  if (!raw) {
    return res.status(404).json({ error: "الحساب غير موجود." });
  }

  const entry = parseStored(raw);
  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = await hashPasswordAsync(newPassword, salt);

  await redis.set(
    credKey,
    JSON.stringify({ ...entry, salt, passwordHash, updatedAt: Date.now() })
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

  const entry = parseStored(raw);
  const ownerToken = entry.parentToken;

  if (ownerToken) {
    const sessionIds = await redis.smembers(`owner:${ownerToken}:sessions`);
    for (const sessionId of sessionIds) {
      const rawSession = await redis.get(`session:${sessionId}`);
      if (rawSession) {
        const s = parseStored(rawSession);
        if (s.deviceToken) await redis.del(`device:${s.deviceToken}`);
        if (s.username) {
          await redis.del(`child:byowner:${s.username}`);
          await redis.del(`child:last:${s.username}`);
        }
      }
      closeBroadcasterOf(sessionId);
      delete live[sessionId];
      await redis.del(`session:${sessionId}`);
    }
    await redis.del(`owner:${ownerToken}:sessions`);
    await redis.del(`parenttoken:${ownerToken}`);
  }
  await redis.del(credKey);

  console.log(`[parent] account deleted: ${username}`);
  return res.json({ data: { deleted: true, username } });
});

// ═══════════════════════════════════════════════════════════
// PAIRING
// ═══════════════════════════════════════════════════════════

app.post("/pairing/create", requireAdminToken, async (req, res) => {
  let code = generatePairingCode();
  for (let i = 0; i < 5; i++) {
    const exists = await redis.get(`pairing:${code}`);
    if (!exists) break;
    code = generatePairingCode();
  }
  await redis.set(
    `pairing:${code}`,
    JSON.stringify({ ownerToken: req.ownerToken, failures: 0 }),
    { ex: PAIRING_CODE_TTL_SECONDS }
  );
  res.json({ data: { code, expires_in_seconds: PAIRING_CODE_TTL_SECONDS } });
});

async function recordPairingFailure(code, entry) {
  const failures = (entry.failures || 0) + 1;
  if (failures >= MAX_PAIRING_ATTEMPTS_PER_ACCOUNT) return;
  await redis.set(
    `pairing:${code}`,
    JSON.stringify({ ...entry, failures }),
    { ex: PAIRING_CODE_TTL_SECONDS }
  );
}

app.post("/pairing/claim", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `claim-pairing:${ip}`, 12)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();
  const deviceName =
    (req.body && req.body.device_name && String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";

  if (!/^\d{6}$/.test(code)) {
    return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
  }

  const raw = await redis.getdel(`pairing:${code}`);
  if (!raw) {
    return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
  }

  const entry = parseStored(raw);
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
      source: "web",
    })
  );
  await redis.set(
    `device:${deviceToken}`,
    JSON.stringify({
      sessionId,
      ownerToken,
      deviceName,
      pairedAt: Date.now(),
      source: "web",
    })
  );
  await redis.sadd(`owner:${ownerToken}:sessions`, sessionId);

  res.json({
    data: { device_token: deviceToken, session_id: sessionId, device_name: deviceName },
  });
});

// ═══════════════════════════════════════════════════════════
// PAIRING REGISTER (إكمال القسم المفقود)
// ═══════════════════════════════════════════════════════════

app.post("/pairing/register", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `register:${ip}`, 12)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = normalizeUsername(req.body && req.body.username);
  const password = req.body && req.body.password ? String(req.body.password) : "";
  const deviceName =
    (req.body && req.body.device_name && String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();

  if (!username || !password) {
    return res.status(400).json({ error: "لازم تدخل اسم المستخدم وكلمة المرور." });
  }
  if (password.length < 8) {
    return res.status(400).json({ error: "كلمة المرور لازم تكون 8 أحرف على الأقل." });
  }

  const parentRaw = await redis.get(`parent:credentials:${username}`);

  if (parentRaw) {
    // ═══ الحالة 1: المستخدم والد موجود ═══
    const parentEntry = parseStored(parentRaw);
    const ok = await verifyPasswordAsync(password, parentEntry.salt, parentEntry.passwordHash);
    if (!ok) {
      return res.status(401).json({
        error: "هذا الاسم محجوز لحساب والد. تأكد من كلمة المرور أو استخدم اسمًا آخر.",
      });
    }

    if (code) {
      if (!/^\d{6}$/.test(code)) {
        return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
      }

      const peekRaw = await redis.get(`pairing:${code}`);
      if (!peekRaw) {
        return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
      }
      const peekEntry = parseStored(peekRaw);

      if (peekEntry.ownerToken !== parentEntry.parentToken) {
        await recordPairingFailure(code, peekEntry);
        return res.status(403).json({
          error: "هذا الكود من حساب والد مختلف. استخدم كوداً من حسابك.",
        });
      }

      const burned = await redis.getdel(`pairing:${code}`);
      if (!burned) {
        return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
      }
    }

    // إنشاء جلسة لهذا الوالد
    const sessionId = crypto.randomBytes(16).toString("hex");
    const deviceToken = crypto.randomBytes(24).toString("hex");

    await redis.set(
      `session:${sessionId}`,
      JSON.stringify({
        name: deviceName,
        username,
        createdAt: Date.now(),
        ownerToken: parentEntry.parentToken,
        deviceToken,
        source: "app",
      })
    );
    await redis.set(
      `device:${deviceToken}`,
      JSON.stringify({
        sessionId,
        ownerToken: parentEntry.parentToken,
        deviceName,
        pairedAt: Date.now(),
        source: "app",
      })
    );
    await redis.sadd(`owner:${parentEntry.parentToken}:sessions`, sessionId);

    console.log(`[pairing] parent device registered: ${username} / ${deviceName}`);
    return res.json({
      data: {
        device_token: deviceToken,
        session_id: sessionId,
        device_name: deviceName,
        admin_token: parentEntry.parentToken,
      },
    });
  }

  // ═══ الحالة 2: حساب طفل جديد (username غير محجوز) ═══
  // إنشاء بيانات اعتماد للطفل
  const childSalt = crypto.randomBytes(16).toString("hex");
  const childPasswordHash = await hashPasswordAsync(password, childSalt);

  const childCredKey = `child:credentials:${username}`;
  const childCreated = await redisCommand(
    "SET",
    childCredKey,
    JSON.stringify({
      salt: childSalt,
      passwordHash: childPasswordHash,
      username,
      createdAt: Date.now(),
    }),
    "NX"
  );

  if (childCreated !== "OK") {
    return res.status(409).json({ error: "اسم المستخدم مستخدم بالفعل. جرّب اسماً آخر." });
  }

  // إذا أرسل كود ربط، نحاول ربط الطفل بحساب والد
  let ownerToken = null;
  if (code) {
    if (!/^\d{6}$/.test(code)) {
      return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
    }
    const rawCode = await redis.getdel(`pairing:${code}`);
    if (!rawCode) {
      return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
    }
    const codeEntry = parseStored(rawCode);
    ownerToken = codeEntry.ownerToken;
  }

  const sessionId = crypto.randomBytes(16).toString("hex");
  const deviceToken = crypto.randomBytes(24).toString("hex");

  await redis.set(
    `session:${sessionId}`,
    JSON.stringify({
      name: deviceName,
      username,
      createdAt: Date.now(),
      ownerToken,
      deviceToken,
      source: "app",
    })
  );
  await redis.set(
    `device:${deviceToken}`,
    JSON.stringify({
      sessionId,
      ownerToken,
      deviceName,
      pairedAt: Date.now(),
      source: "app",
    })
  );

  if (ownerToken) {
    await redis.sadd(`owner:${ownerToken}:sessions`, sessionId);
    await redis.set(`child:byowner:${username}`, ownerToken);
  }
  await redis.set(`child:last:${username}`, Date.now());

  console.log(`[pairing] child registered: ${username} / ${deviceName}`);

  return res.json({
    data: {
      device_token: deviceToken,
      session_id: sessionId,
      device_name: deviceName,
      owner_token: ownerToken,
    },
  });
});

// ═══════════════════════════════════════════════════════════
// WEBSOCKET SIGNALING
// ═══════════════════════════════════════════════════════════

wss.on("connection", async (ws, req) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    const sessionId = url.searchParams.get("session");
    const role = url.searchParams.get("role"); // "broadcaster" | "viewer"
    const token = url.searchParams.get("token") || "";
    const ip = clientIp(req);

    if (!rateLimit(wsAttempts, `ws:${ip}`, 60)) {
      ws.close(1008, "rate_limited");
      return;
    }

    if (!sessionId || !role) {
      ws.close(1008, "missing_params");
      return;
    }

    if (role !== "broadcaster" && role !== "viewer") {
      ws.close(1008, "invalid_role");
      return;
    }

    const rawSession = await redis.get(`session:${sessionId}`);
    if (!rawSession) {
      ws.close(1008, "invalid_session");
      return;
    }
    const session = parseStored(rawSession);

    const isBroadcaster = role === "broadcaster";
    const expectedToken = isBroadcaster ? session.deviceToken : session.ownerToken;
    if (!expectedToken || !safeCompare(token, expectedToken)) {
      ws.close(1008, "unauthorized");
      return;
    }

    const clientId = generateClientId();
    clients[clientId] = { ws, sessionId, role, ip };
    const liveSession = getLive(sessionId);

    if (isBroadcaster) {
      // إغلاق أي broadcaster سابق على نفس الجلسة
      if (liveSession.broadcaster && liveSession.broadcaster !== clientId) {
        try { clients[liveSession.broadcaster]?.ws?.close(); } catch (_) {}
      }
      liveSession.broadcaster = clientId;
      console.log(`[ws] 🎥 broadcaster connected: session=${sessionId}`);

      for (const [vk] of liveSession.viewers) {
        sendToViewer(liveSession, vk, { type: "broadcaster-online" });
      }
    } else {
      const viewerKey = computeViewerKey(sessionId, session.ownerToken);
      liveSession.viewers.set(viewerKey, {
        currentClientId: clientId,
        lastSeen: Date.now(),
      });
      console.log(`[ws] 👁 viewer connected: session=${sessionId}`);

      if (liveSession.broadcaster) {
        send(clientId, { type: "broadcaster-online" });
      } else {
        send(clientId, { type: "broadcaster-offline" });
      }
    }

    ws.on("message", (data) => {
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }

      if (isBroadcaster) {
        for (const [vk] of liveSession.viewers) {
          sendToViewer(liveSession, vk, msg);
        }
      } else {
        const viewerKey = computeViewerKey(sessionId, session.ownerToken);
        const v = liveSession.viewers.get(viewerKey);
        if (v) v.lastSeen = Date.now();
        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, msg);
        }
      }
    });

    ws.on("close", () => {
      delete clients[clientId];

      if (isBroadcaster) {
        if (liveSession.broadcaster === clientId) {
          liveSession.broadcaster = null;
          console.log(`[ws] 🎥 broadcaster disconnected: session=${sessionId}`);
          for (const [vk] of liveSession.viewers) {
            sendToViewer(liveSession, vk, { type: "broadcaster-offline" });
          }
        }
      } else {
        const viewerKey = computeViewerKey(sessionId, session.ownerToken);
        const v = liveSession.viewers.get(viewerKey);
        if (v && v.currentClientId === clientId) {
          liveSession.viewers.delete(viewerKey);
        }
        console.log(`[ws] 👁 viewer disconnected: session=${sessionId}`);
      }
    });

    ws.on("error", (err) => {
      console.warn(`[ws] error: ${err.message}`);
    });
  } catch (e) {
    console.error("[ws] connection error:", e.message);
    try { ws.close(1011, "server_error"); } catch (_) {}
  }
});

// ═══════════════════════════════════════════════════════════
// START SERVER
// ═══════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════
// ICE / TURN
// ═══════════════════════════════════════════════════════════

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
    const urls = turnUrls.split(",").map((u) => u.trim()).filter(Boolean);
    return [
      ...stunServers,
      ...urls.map((u) => ({ urls: u, username, credential })),
    ];
  }

  if (!_warnedNoPrivateTurn) {
    _warnedNoPrivateTurn = true;
    console.warn("[camera-parent] TURN_URLS not set - using public openrelay fallback");
  }

  return [
    ...stunServers,
    { urls: "turn:openrelay.metered.ca:80", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443?transport=tcp", username: "openrelayproject", credential: "openrelayproject" },
  ];
}

app.get("/ice-servers", (req, res) => {
  res.json({ data: getIceServers() });
});

const PORT = process.env.PORT || 3000;

(async () => {
  try {
    ADMIN_TOKEN = await getOrCreateAdminToken();
    console.log(`[camera-parent] ✅ ADMIN_TOKEN set (len=${ADMIN_TOKEN.length})`);
    console.log("[camera-parent] ✅ Upstash Redis connected");
  } catch (e) {
    console.error("[startup] ❌ Failed to init ADMIN_TOKEN:", e.message);
    process.exit(1);
  }

  server.listen(PORT, "0.0.0.0", () => {
    console.log(`✅ Server running on port ${PORT}`);
    startKeepAlive();
  });
})();