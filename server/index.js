require("dotenv").config();
const crypto = require("crypto");
const fs = require("fs");
const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const admin = require("firebase-admin");

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
// Upstash Redis (REST, POST + JSON body)
// ═══════════════════════════════════════════════════════════

const UPSTASH_URL = process.env.UPSTASH_REDIS_REST_URL;
const UPSTASH_TOKEN = process.env.UPSTASH_REDIS_REST_TOKEN;

if (!UPSTASH_URL || !UPSTASH_TOKEN) {
  console.error("[ERROR] Missing UPSTASH Redis env vars!");
  process.exit(1);
}

// كل أمر يُرسل كمصفوفة في body عبر POST. الأخطاء تُرمى ولا تُرجع null.
async function redisCommand(...args) {
  const res = await fetch(UPSTASH_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${UPSTASH_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) {
    throw new Error(`Redis HTTP ${res.status}`);
  }
  const data = await res.json();
  if (data.error) {
    throw new Error(`Redis error: ${data.error}`);
  }
  return data.result;
}

const redis = {
  // get: يرجع null عند الخطأ (سلوك قديم محفوظ)
  async get(k) {
    const v = await redisCommand("GET", k);
    return v ?? null;
  },
  async getdel(k) {
    const v = await redisCommand("GETDEL", k);
    return v ?? null;
  },
  // getStrict: يرمي عند فشل القراءة — يُستخدم حيث يكون الخطأ خطيراً (التسجيل)
  async getStrict(k) {
    return (await redisCommand("GET", String(k))) || null;
  },
  // set(k, v, { ex, nx }) — nx: يكتب فقط إذا لم يكن موجوداً
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
// نثق بـ proxy واحد فقط (Render)، حتى لا يستطيع العميل تزوير X-Forwarded-For
app.set("trust proxy", Number(process.env.TRUST_PROXY || 1));
const server = http.createServer(app);
const wss = new WebSocketServer({
  server,
  path: "/signal",
  maxPayload: 1024 * 1024, // 1MB: أكبر من أي رسالة مشروعة (chunk ≈ 67KB)
});

// السيرفر خلف proxy واحد (منصة الاستضافة). بدون هذا السطر يأخذ req.ip قيمة
// x-forwarded-for التي يرسلها العميل نفسه، فيتجاوز كل حدود المحاولات.
app.set("trust proxy", 1);

// Express 4 لا يلتقط أخطاء الدوال async. هذا الغلاف يمرر أي رفض إلى معالج الأخطاء.
const wrapAsync = (fn) => (req, res, next) =>
  Promise.resolve(fn(req, res, next)).catch(next);
for (const method of ["get", "post", "delete"]) {
  const original = app[method].bind(app);
  app[method] = (path, ...handlers) =>
    original(
      path,
      ...handlers.map((h) => (h.constructor.name === "AsyncFunction" ? wrapAsync(h) : h))
    );
}

// يُستخدم لتغليف معالجات WebSocket: أي خطأ (مثل فشل Redis) يُسجَّل ولا يوقف السيرفر
function safeWs(fn) {
  return Promise.resolve()
    .then(fn)
    .catch((e) => console.error("[ws] handler error:", e && e.message));
}

process.on("unhandledRejection", (reason) => {
  console.error("[unhandledRejection]", reason && reason.message ? reason.message : reason);
});

app.use(express.json({ limit: "64kb" }));
app.use(express.static("public"));

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

// عدد الـ proxies الموثوقة أمام السيرفر (Render = 1). لا نثق بأول قيمة في
// x-forwarded-for لأن العميل يقدر يزوّرها؛ نأخذ القيمة التي أضافها الـ proxy.
const TRUSTED_PROXY_HOPS = parseInt(process.env.TRUSTED_PROXY_HOPS || "1", 10);

function clientIp(req) {
  // طلبات Express: req.ip يحترم trust proxy أعلاه.
  if (req.ip) return String(req.ip);
  // طلبات WebSocket (upgrade) لا تمر عبر Express، فنأخذ آخر عنوان أضافه الـ proxy
  // الموثوق (proxy واحد)، وليس أول قيمة يرسلها العميل.
  const xff = String(req.headers["x-forwarded-for"] || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (xff.length) return xff[xff.length - 1];
  return String(req.socket.remoteAddress || "unknown");
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
      try {
        bClient.ws.close();
      } catch (_) {}
    }
  }
}

// ═══════════════════════════════════════════════════════════
// Admin auth
// ═══════════════════════════════════════════════════════════

// مُعطَّل افتراضياً. فعّله بـ ADMIN_CLAIM_ENABLED=true لمرة واحدة فقط عند الإعداد الأول،
// ثم أزله. بدونه أول طالب كان يحصل على المفتاح الرئيسي للسيرفر.
app.post("/admin/claim", async (req, res) => {
  if (process.env.ADMIN_CLAIM_ENABLED !== "true") {
    return res.status(404).json({ error: "not_found" });
  }
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `claim:${ip}`, 5)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  // SET NX يمنع طلبين متزامنين من المرور معاً
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
    // الهيدر فقط: التوكن في الرابط يُسجَّل في لوجات الاستضافة وسجل المتصفح
    const provided = req.header("x-admin-token");
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

  // SET NX: إنشاء الحساب فقط إذا لم يكن موجوداً
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

  // حذف الجلسات المرتبطة بهذا الوالد وإغلاق اتصالاتها الحية
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

// يحاول الكود الخاطئ: يزيد عداد الفشل على الكود نفسه، ويحرقه بعد عدد محدد من المحاولات.
// عدد المحاولات مرتبط بالكود، فلا يمكن تخمينه إلا بعدد محدود قبل انتهاء صلاحيته.
async function recordPairingFailure(code, entry) {
  const failures = (entry.failures || 0) + 1;
  if (failures >= MAX_PAIRING_ATTEMPTS_PER_ACCOUNT) {
    // نحرق الكود فعلياً، وإلا يبقى صالحاً حتى تنتهي مدته مهما كثرت المحاولات
    await redis.del(`pairing:${code}`);
    return;
  }
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

  // GETDEL ذري: الكود يُستهلك مرة واحدة فقط حتى لو وصل طلبان معاً
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

app.post("/pairing/register", async (req, res) => {
  const ip = clientIp(req);

  if (!rateLimit(authAttempts, `pairing-register:${ip}`, 12)) {
    return res.status(429).json({
      error: "محاولات كثيرة. حاول لاحقًا.",
    });
  }
  const username = normalizeUsername(req.body && req.body.username);
  const password = req.body && req.body.password ? String(req.body.password) : "";
  const deviceName =
    req.body && req.body.device_name &&
    String(req.body.device_name).trim()
      ? String(req.body.device_name).trim()
      : "جهاز الطفل";

  if (!username || !password) {
    return res.status(400).json({ error: "لازم تدخل اسم المستخدم وكلمة المرور." });
  }
  if (password.length < 8) {
    return res.status(400).json({ error: "كلمة المرور لازم تكون 8 أحرف على الأقل." });
  }

  const parentRaw = await redis.get(`parent:credentials:${username}`);

  if (parentRaw) {
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

      // نقرأ الكود بدون حرقه أولاً، ونتحقق من ملكيته، ثم نحرقه ذرياً
      const peekRaw = await redis.get(`pairing:${code}`);
      if (!peekRaw) {
        return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
      }
      const peekEntry = parseStored(peekRaw);

      if (peekEntry.ownerToken !== parentEntry.parentToken) {
        // كود صحيح لكن لحساب آخر: نعدّ محاولة فاشلة على الكود، ولا نحرقه مباشرة
        await recordPairingFailure(code, peekEntry);
        return res.status(403).json({
          error: "هذا الكود من حساب والد مختلف. استخدم كوداً من حسابك.",
        });
      }

      // الكود صحيح ويخص هذا الوالد: نحرقه ذرياً الآن
      const burned = await redis.getdel(`pairing:${code}`);
      if (!burned) {
        return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
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
          source: "pairing",
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
          source: "pairing",
        })
      );
      await redis.sadd(`owner:${parentEntry.parentToken}:sessions`, sessionId);
      await redis.set(
        `child:last:${username}`,
        JSON.stringify({ sessionId, deviceToken, deviceName, linkedAt: Date.now() })
      );

      console.log(
        `[child] NEW device: user=${username} name=${deviceName} session=${sessionId.slice(0, 8)}...`
      );

      return res.json({
        data: { device_token: deviceToken, session_id: sessionId, device_name: deviceName },
      });
    }

    const lastRaw = await redis.get(`child:last:${username}`);
    if (lastRaw) {
      const lastData = parseStored(lastRaw);
      const sessRaw = await redis.get(`session:${lastData.sessionId}`);
      if (sessRaw) {
        console.log(
          `[child] RESTORE session: user=${username} session=${lastData.sessionId.slice(0, 8)}...`
        );
        return res.json({
          data: {
            device_token: lastData.deviceToken,
            session_id: lastData.sessionId,
            device_name: lastData.deviceName,
          },
        });
      }
      await redis.del(`child:last:${username}`);
    }

    return res.status(400).json({
      error: "أدخل الكود من تطبيق الوالد لربط هذا الجهاز بالحساب.",
    });
  }

  // ملاحظة: حسابات الأطفال المستقلة (بدون والد) تبقى تحت المفتاح credentials:
  // لحماية البيانات القديمة. لا تتعارض مع parent:credentials: لأن البادئة مختلفة.
  const credKey = `credentials:${username}`;
  const raw = await redis.get(credKey);

  if (raw) {
    const entry = parseStored(raw);
    const ok = await verifyPasswordAsync(password, entry.salt, entry.passwordHash);
    if (!ok) {
      return res.status(401).json({ error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
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
    return res.status(400).json({ error: "لازم كود من تطبيق الوالد لأول تسجيل دخول." });
  }

  const pairingRaw = await redis.get(`pairing:${code}`);
  if (!pairingRaw) {
    return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
  }
  const burned = await redis.getdel(`pairing:${code}`);
  if (!burned) {
    return res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
  }

  const pairingEntry = parseStored(burned);
  const ownerToken = pairingEntry.ownerToken;

  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = await hashPasswordAsync(password, salt);

  const sessionId = crypto.randomBytes(16).toString("hex");
  const deviceToken = crypto.randomBytes(24).toString("hex");

  const now = Date.now();

  await redis.set(
    `session:${sessionId}`,
    JSON.stringify({
      name: deviceName,
      createdAt: now,
      ownerToken,
      deviceToken,
      username,
      source: "pairing",
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
      source: "pairing",
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

  return res.json({
    data: { device_token: deviceToken, session_id: sessionId, device_name: deviceName },
  });
});

app.post("/pairing/unpair", async (req, res) => {
  const deviceToken = req.header("x-device-token") || "";
  const raw = await redis.get(`device:${deviceToken}`);
  if (!raw) return res.status(404).json({ error: "الجهاز غير مقترن." });

  const info = parseStored(raw);
  await redis.del(`device:${deviceToken}`);
  await redis.del(`session:${info.sessionId}`);
  await redis.srem(`owner:${info.ownerToken}:sessions`, info.sessionId);

  if (info.username) {
    await redis.del(`child:byowner:${info.username}`);
    await redis.del(`child:last:${info.username}`);
  }

  closeBroadcasterOf(info.sessionId);
  delete live[info.sessionId];
  res.json({ data: { unpaired: true } });
});

app.get("/camera/sessions", requireAdminToken, async (req, res) => {
  const requesterToken = req.ownerToken;
  try {
    const sessionIds = await redis.smembers(`owner:${requesterToken}:sessions`);
    const list = [];
    for (const sessionId of sessionIds) {
      const raw = await redis.get(`session:${sessionId}`);
      if (!raw) continue;
      const s = parseStored(raw);
      const liveSession = live[sessionId];
      list.push({
        session_id: sessionId,
        name: s.name,
        online: !!(liveSession && liveSession.broadcaster),
        viewers: liveSession ? liveSession.viewers.size : 0,
        created_at: s.createdAt,
        source: s.source || "pairing",
      });
    }
    list.sort((a, b) => b.created_at - a.created_at);
    res.json({ data: list });
  } catch (e) {
    console.error("[camera/sessions] error:", e.message);
    res.status(503).json({ error: "temporary_unavailable", retry: true });
  }
});

app.delete("/camera/sessions/:id", requireAdminToken, async (req, res) => {
  const sessionId = req.params.id;
  const raw = await redis.get(`session:${sessionId}`);
  if (!raw) return res.status(404).json({ error: "الجهاز غير موجود." });
  const s = parseStored(raw);
  if (s.ownerToken !== req.ownerToken) {
    return res.status(404).json({ error: "الجهاز غير موجود." });
  }

  closeBroadcasterOf(sessionId);
  delete live[sessionId];

  if (s.deviceToken) await redis.del(`device:${s.deviceToken}`);
  if (s.username) {
    await redis.del(`child:byowner:${s.username}`);
    await redis.del(`child:last:${s.username}`);
  }
  await redis.del(`session:${sessionId}`);
  await redis.srem(`owner:${s.ownerToken}:sessions`, sessionId);
  res.json({ data: { deleted: true } });
});

// ═══════════════════════════════════════════════════════════
// WEBSOCKET
// ═══════════════════════════════════════════════════════════

wss.on("connection", (ws, req) => {
  const ip = clientIp(req);
  if (!rateLimit(wsAttempts, ip, 30)) {
    console.log("[ws] rate limited", ip);
    try { ws.close(1013, "rate limited"); } catch (_) {}
    return;
  }

  const clientId = generateClientId();
  ws._clientId = clientId;
  clients[clientId] = {
    ws,
    sessionId: null,
    role: null,
    viewerKey: null,
    lastMessageAt: Date.now(),
  };

  ws.on("error", (e) => {
    console.error("[ws] socket error:", e && e.message ? e.message : e);
  });

  ws.isAlive = true;
  ws.on("pong", () => {
    ws.isAlive = true;
    const c = clients[clientId];
    if (c) c.lastMessageAt = Date.now();
  });

  ws.on("message", (raw) => safeWs(async () => {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) { return; }

    const client = clients[clientId];
    if (!client) return;
    client.lastMessageAt = Date.now();

    if (msg.type === "ping") {
      send(clientId, { type: "pong", timestamp: msg.timestamp || Date.now() });
      return;
    }

    if (msg.type === "client-log") {
      console.log(`[child-log] session=${client.sessionId || "?"} :: ${String(msg.message || "").slice(0, 300)}`);
      return;
    }

    if (msg.type === "wake") {
      const sessionId = safeText(msg.session, 64);
      const adminToken = safeText(msg.adminToken, 256);
      if (!sessionId || !adminToken) {
        send(clientId, { type: "wake-failed", reason: "bad_request" });
        return;
      }
      const rawSession = await redis.get(`session:${sessionId}`);
      if (!rawSession) {
        send(clientId, { type: "wake-failed", reason: "not_found" });
        return;
      }
      const sessionObj = parseStored(rawSession);
      if (!safeCompare(adminToken, sessionObj.ownerToken)) {
        send(clientId, { type: "wake-failed", reason: "not_authorized" });
        return;
      }
      const liveSession = live[sessionId];

      // 1) الكاميرا متصلة → wake عبر WebSocket
      if (liveSession && liveSession.broadcaster) {
        send(liveSession.broadcaster, {
          type: "wake",
          viewerId: computeViewerKey(sessionId, adminToken),
          name: "الوالد",
        });
        send(clientId, { type: "wake-sent", via: "ws" });
        return;
      }

      // 2) الكاميرا offline → FCM fallback
      if (!fcmAdmin) {
        send(clientId, { type: "wake-failed", reason: "fcm_disabled" });
        return;
      }

      const fcmToken = await redis.get(`session:${sessionId}:fcm`);
      if (!fcmToken) {
        send(clientId, { type: "wake-failed", reason: "no_fcm_token" });
        return;
      }

      try {
        await fcmAdmin.messaging().send({
          token: fcmToken,
          data: { action: "wake_camera", sessionId },
          android: { priority: "high", ttl: 60000 },
        });
        send(clientId, { type: "wake-sent", via: "fcm" });
        console.log(`[wake] FCM sent for ${sessionId.slice(0, 8)}`);
      } catch (e) {
        console.error("[wake] FCM send failed:", e.code || e.message);
        if (
          e.code === "messaging/registration-token-not-registered" ||
          e.code === "messaging/invalid-registration-token"
        ) {
          await redis.del(`session:${sessionId}:fcm`);
        }
        send(clientId, {
          type: "wake-failed",
          reason: "fcm_error",
          detail: e.code || e.message,
        });
      }
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
        const deviceInfo = parseStored(rawDevice);
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

        const fcmToken = safeText(msg.fcmToken, 4096);
        if (fcmToken) {
          await redis.set(`session:${boundSession}:fcm`, fcmToken);
          await redis.set(`device:${deviceToken}:fcm`, fcmToken);
          console.log(`[fcm] token saved for ${boundSession.slice(0, 8)}...`);
        }

        console.log(
          `[ws] broadcaster: client=${clientId} session=${boundSession.slice(0, 8)}...`
        );

        const sessionData = parseStored(rawSession);
        if (sessionData.ownerToken) {
          send(clientId, { type: "auth-ok", ownerToken: sessionData.ownerToken });
          console.log(`[ws] sent auth-ok to broadcaster ${clientId.slice(0, 8)}...`);
        }

        liveSession.viewers.forEach((info, viewerKey) => {
          send(clientId, {
            type: info.approved ? "viewer-joined" : "join-request",
            viewerId: viewerKey,
            name: info.name,
            source: info.source,
          });
          if (info.approved && info.currentClientId) {
            send(info.currentClientId, { type: "viewer-approved" });
            console.log(
              `[ws] notified viewer ${viewerKey.slice(0, 8)}... broadcaster is online`
            );
          }
        });
        return;
      }

      if (role === "viewer") {
        const adminToken = safeText(msg.adminToken, 256);
        const rawSession = await redis.get(`session:${session}`);
        const targetSession = rawSession ? parseStored(rawSession) : null;

        if (!targetSession || !safeCompare(adminToken, targetSession.ownerToken)) {
          send(clientId, { type: "auth-failed", reason: "not_authorized" });
          return;
        }

        const viewerKey = computeViewerKey(session, adminToken);
        client.sessionId = session;
        client.role = role;
        client.viewerKey = viewerKey;
        client.callerName = msg.name || "الوالد";

        const requestedSource =
          msg.requestedSource === "screen" ? "screen"
          : msg.requestedSource === "files" ? "files"
          : "camera";

        const liveSession = getLive(session);

        const approvedInRedis = await redis.get(`viewer:approved:${viewerKey}`);
        const wasApproved = approvedInRedis === "1";
        const autoApprove = requestedSource === "files";
        const finalApproved = wasApproved || autoApprove;

        liveSession.viewers.set(viewerKey, {
          name: client.callerName,
          approved: finalApproved,
          source: requestedSource,
          currentClientId: clientId,
        });

        console.log(
          `[ws] viewer: key=${viewerKey.slice(0, 8)}... session=${session.slice(0, 8)}... broadcaster=${!!liveSession.broadcaster} source=${requestedSource} wasApproved=${wasApproved}`
        );

        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, {
            type: finalApproved ? "viewer-joined" : "join-request",
            viewerId: viewerKey,
            name: client.callerName,
            source: requestedSource,
            adminToken: adminToken,
          });
          if (finalApproved) {
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
        if (client.role === "viewer" && client.viewerKey) {
          const v = liveSession.viewers.get(client.viewerKey);
          if (v && v.currentClientId === clientId) {
            v.currentClientId = null;
          }
          if (liveSession.broadcaster) {
            send(liveSession.broadcaster, {
              type: "viewer-left",
              viewerId: client.viewerKey,
            });
          }
        } else if (
          client.role === "broadcaster" &&
          liveSession.broadcaster === clientId
        ) {
          liveSession.broadcaster = null;
          for (const [viewerKey] of liveSession.viewers) {
            sendToViewer(liveSession, viewerKey, { type: "broadcaster-left" });
          }
          console.log(
            `[ws] broadcaster left (graceful) — kept ${liveSession.viewers.size} viewers waiting`
          );
        }
        if (!liveSession.broadcaster && liveSession.viewers.size === 0) {
          delete live[sessionId];
        }
      }
      client.sessionId = null;
      client.role = null;
      client.viewerKey = null;
      try { client.ws.close(1000, "left"); } catch (_) {}
      return;
    }

    if (msg.type === "viewer-status") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) return;
      if (!liveSession.viewers.get(msg.target)) return;
      sendToViewer(liveSession, msg.target, {
        type: "viewer-status",
        status: String(msg.status || ""),
      });
      return;
    }

    if (msg.type === "approve-viewer") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) return;
      const viewerInfo = liveSession.viewers.get(msg.target);
      if (!viewerInfo) return;
      viewerInfo.approved = true;

      await redis.set(`viewer:approved:${msg.target}`, "1");

      sendToViewer(liveSession, msg.target, { type: "viewer-approved" });
      console.log(`[ws] viewer approved PERMANENTLY: ${String(msg.target).slice(0, 8)}...`);
      return;
    }

    if (msg.type === "reject-viewer") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) return;
      const viewerInfo = liveSession.viewers.get(msg.target);
      liveSession.viewers.delete(msg.target);

      await redis.del(`viewer:approved:${msg.target}`);

      if (viewerInfo && viewerInfo.currentClientId) {
        send(viewerInfo.currentClientId, { type: "join-rejected" });
        const t = clients[viewerInfo.currentClientId];
        if (t) { try { t.ws.close(); } catch (_) {} }
      }
      console.log(`[ws] viewer rejected: ${String(msg.target).slice(0, 8)}...`);
      return;
    }

    if (msg.type === "offer") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) return;
      const viewerInfo = liveSession.viewers.get(msg.viewerId);
      if (!viewerInfo || !viewerInfo.approved) return;
      sendToViewer(liveSession, msg.viewerId, {
        type: "offer",
        sdp: msg.sdp,
        from: clientId,
      });
      return;
    }

    if (msg.type === "answer") {
      const liveSession = live[client.sessionId];
      if (
        client.role === "viewer" &&
        client.viewerKey &&
        liveSession &&
        liveSession.broadcaster
      ) {
        send(liveSession.broadcaster, {
          type: "answer",
          sdp: msg.sdp,
          from: client.viewerKey,
          viewerId: client.viewerKey,
        });
      }
      return;
    }

    if (msg.type === "ice") {
      const liveSession = client.sessionId ? live[client.sessionId] : null;
      if (!liveSession) return;

      if (client.role === "viewer" && client.viewerKey) {
        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, {
            type: "ice",
            candidate: msg.candidate,
            from: client.viewerKey,
          });
        }
      } else if (client.role === "broadcaster") {
        const viewerInfo = liveSession.viewers.get(msg.target);
        if (viewerInfo && viewerInfo.currentClientId) {
          send(viewerInfo.currentClientId, {
            type: "ice",
            candidate: msg.candidate,
            from: clientId,
          });
        }
      }
      return;
    }

    if (msg.type === "request-restart-ice") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "viewer" ||
        !client.viewerKey ||
        !liveSession ||
        !liveSession.broadcaster
      ) return;
      console.log(`[ws] restart-ice requested by ${client.viewerKey.slice(0, 8)}...`);
      send(liveSession.broadcaster, {
        type: "request-restart-ice",
        viewerId: client.viewerKey,
      });
      return;
    }

    if (msg.type === "switch-camera" || msg.type === "toggle-mic") {
      const liveSession = live[client.sessionId];
      if (client.role !== "viewer" || !client.viewerKey || !liveSession || !liveSession.broadcaster) return;
      const vInfo = liveSession.viewers.get(client.viewerKey);
      if (!vInfo || !vInfo.approved) return; // مشاهد لم يوافق عليه الطفل لا يتحكم بالجهاز
      send(liveSession.broadcaster, { type: msg.type });
      return;
    }

    if (
      msg.type === "permission-request" ||
      msg.type === "file-browser-list" ||
      msg.type === "file-browser-download" ||
      msg.type === "file-transfer-cancel"
    ) {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "viewer" ||
        !client.viewerKey ||
        !liveSession ||
        !liveSession.broadcaster
      ) return;
      const viewerInfo = liveSession.viewers.get(client.viewerKey);
      if (!viewerInfo || !viewerInfo.approved) return;

      if (msg.type === "file-transfer-cancel") {
        send(liveSession.broadcaster, {
          type: "file-transfer-cancel",
          requestId: msg.requestId,
          viewerId: client.viewerKey,
        });
      } else {
        send(liveSession.broadcaster, { ...msg, viewerId: client.viewerKey });
      }
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
      ) return;
      const target = String(msg.target || "");
      const viewerInfo = liveSession.viewers.get(target);
      if (!viewerInfo || !viewerInfo.currentClientId) return;
      const { target: _, ...rest } = msg;
      send(viewerInfo.currentClientId, rest);
      return;
    }

    if (
      msg.type === "file-transfer-start" ||
      msg.type === "file-transfer-chunk" ||
      msg.type === "file-transfer-end" ||
      msg.type === "file-transfer-cancel"
    ) {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) return;
      const target = String(msg.target || "");
      const viewerInfo = liveSession.viewers.get(target);
      if (!viewerInfo || !viewerInfo.currentClientId) return;
      const { target: _, ...rest } = msg;
      send(viewerInfo.currentClientId, rest);
      return;
    }

    if (msg.type === "kick") {
      const liveSession = live[client.sessionId];
      if (
        client.role === "broadcaster" &&
        liveSession &&
        liveSession.broadcaster === clientId
      ) {
        const viewerInfo = liveSession.viewers.get(msg.target);
        if (viewerInfo && viewerInfo.currentClientId) {
          send(viewerInfo.currentClientId, { type: "kicked" });
          const t = clients[viewerInfo.currentClientId];
          if (t) { try { t.ws.close(); } catch (_) {} }
        }
      }
      return;
    }
  }));

  ws.on("close", (code) => {
    console.log(`[ws] close role=${clients[clientId]?.role} code=${code}`);
    const client = clients[clientId];
    if (client && client.sessionId && live[client.sessionId]) {
      const liveSession = live[client.sessionId];
      if (client.role === "broadcaster" && liveSession.broadcaster === clientId) {
        liveSession.broadcaster = null;
        for (const [viewerKey] of liveSession.viewers) {
          sendToViewer(liveSession, viewerKey, { type: "broadcaster-left" });
        }
        console.log(
          `[ws] broadcaster disconnected — kept ${liveSession.viewers.size} viewers waiting`
        );
      }
      if (client.role === "viewer" && client.viewerKey) {
        const v = liveSession.viewers.get(client.viewerKey);
        if (v && v.currentClientId === clientId) {
          v.currentClientId = null;
          const sid = client.sessionId;
          const vk = client.viewerKey;
          setTimeout(() => {
            const ls = live[sid];
            if (!ls) return;
            const vv = ls.viewers.get(vk);
            if (vv && vv.currentClientId === null) {
              ls.viewers.delete(vk);
            }
          }, 3 * 60 * 1000);
        }
        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, {
            type: "viewer-left",
            viewerId: client.viewerKey,
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
      console.log("[ws] terminate: idle", client.role);
      return ws.terminate();
    }
    if (ws.isAlive === false) {
      console.log("[ws] terminate: no pong");
      return ws.terminate();
    }
    ws.isAlive = false;
    try { ws.ping(); } catch (_) {}
  });
}, HEARTBEAT_INTERVAL);

wss.on("close", () => clearInterval(heartbeatInterval));

// ═══════════════════════════════════════════════════════════
// ICE / TURN
// ═══════════════════════════════════════════════════════════

let _warnedNoPrivateTurn = false;

// ✅ TURN عبر Metered API (حساب مجاني: 20GB/شهر). عيّن في Render:
//   METERED_APP=اسم_تطبيقك   (الجزء قبل .metered.live)
//   METERED_API_KEY=مفتاحك
// يجلب بيانات اعتماد حقيقية ويخزّنها 30 دقيقة.
let _meteredCache = { at: 0, servers: null };

async function fetchMeteredServers() {
  const app_ = (process.env.METERED_APP || "").trim();
  const key = (process.env.METERED_API_KEY || "").trim();
  if (!app_ || !key || typeof fetch !== "function") return null;
  if (_meteredCache.servers && Date.now() - _meteredCache.at < 30 * 60 * 1000) {
    return _meteredCache.servers;
  }
  try {
    const r = await fetch(
      `https://${app_}.metered.live/api/v1/turn/credentials?apiKey=${encodeURIComponent(key)}`
    );
    if (!r.ok) throw new Error("HTTP " + r.status);
    const list = await r.json();
    if (Array.isArray(list) && list.length) {
      _meteredCache = { at: Date.now(), servers: list };
      return list;
    }
  } catch (e) {
    console.error("[ice] metered fetch failed:", e && e.message ? e.message : e);
  }
  return _meteredCache.servers; // آخر نسخة ناجحة إن وجدت
}

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
    console.warn("[camera-parent] مفيش TURN_URLS ولا METERED_* - fallback openrelay العام (غير مضمون)");
  }

  return [
    ...stunServers,
    { urls: "turn:openrelay.metered.ca:80", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443?transport=tcp", username: "openrelayproject", credential: "openrelayproject" },
  ];
}

// ═══════════════════════════════════════════════════════════
// Wake endpoints
// ═══════════════════════════════════════════════════════════

app.post("/wake/request", async (req, res) => {
  const sessionId = String((req.body && req.body.sessionId) || "");
  const adminToken = String((req.body && req.body.adminToken) || "");

  if (!sessionId || !adminToken) {
    return res.status(400).json({ ok: false, error: "missing_params" });
  }

  try {
    const rawSession = await redis.get(`session:${sessionId}`);
    if (!rawSession) {
      return res.status(404).json({ ok: false, error: "session_not_found" });
    }

    const session = parseStored(rawSession);
    if (!safeCompare(adminToken, session.ownerToken)) {
      console.warn(`[wake] unauthorized: session=${sessionId}`);
      return res.status(403).json({ ok: false, error: "not_authorized" });
    }

    await redis.set(`wake:${sessionId}`, String(Date.now()), { ex: 300 });
    console.log(`[wake] requested: session=${sessionId} by=${adminToken.substring(0, 8)}...`);

    return res.json({ ok: true, sessionId, expiresIn: 300 });
  } catch (e) {
    console.error("[wake] error:", e.message);
    return res.status(500).json({ ok: false, error: "server_error" });
  }
});

app.get("/wake/check", async (req, res) => {
  const deviceToken = String(req.query.token || "");
  if (!deviceToken) {
    return res.json({ wake: false, reason: "no_token" });
  }

  try {
    const rawDevice = await redis.get(`device:${deviceToken}`);
    if (!rawDevice) {
      return res.json({ wake: false, reason: "unknown_device" });
    }

    const device = parseStored(rawDevice);
    const sessionId = device.sessionId || device.session_id || device.session;
    if (!sessionId) {
      return res.json({ wake: false, reason: "no_session" });
    }

    const wake = await redis.get(`wake:${sessionId}`);
    if (wake) {
      await redis.del(`wake:${sessionId}`);
      console.log(`[wake] delivered: device=${deviceToken.substring(0, 8)}... session=${sessionId}`);
      return res.json({ wake: true, sessionId });
    }

    return res.json({ wake: false, reason: "no_pending" });
  } catch (e) {
    console.error("[wake/check] error:", e.message);
    return res.json({ wake: false, reason: "error" });
  }
});

// ═══════════════════════════════════════════════════════════
// Misc
// ═══════════════════════════════════════════════════════════

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

app.get("/fcm-status", requireAdminToken, (req, res) => {
  res.json({ fcm_enabled: !!fcmAdmin });
});

app.get("/", (req, res) => {
  res.send("Camera Parent server is running.");
});

const PORT = process.env.PORT || 8080;

(async () => {
  try {
    ADMIN_TOKEN = await getOrCreateAdminToken();
    console.log(`[camera-parent] ✅ ADMIN_TOKEN set (len=${ADMIN_TOKEN.length})`);
    console.log("[camera-parent] ✅ Upstash Redis connected");
    server.listen(PORT, () => {
      console.log(`✅ Server running on port ${PORT}`);
    });
  } catch (e) {
    console.error("[startup] failed:", e.message);
    process.exit(1);
  }
})();

setInterval(() => {
  const cutoff = Date.now() - RATE_WINDOW_MS;
  for (const [k, v] of authAttempts) if (v.startedAt < cutoff) authAttempts.delete(k);
  for (const [k, v] of wsAttempts) if (v.startedAt < cutoff) wsAttempts.delete(k);
}, RATE_WINDOW_MS).unref();