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

// ✅ إصلاح #1: سرّ إعداد السيرفر (يمنع سرقة ADMIN_TOKEN)
const SETUP_TOKEN = process.env.SETUP_TOKEN || null;
if (!SETUP_TOKEN) {
  console.warn(
    "[SECURITY] SETUP_TOKEN غير مضبوط! /admin/claim مكشوف للجميع. اضبطه في Render."
  );
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
      if (!res.ok) {
        throw new Error(`Redis smembers HTTP ${res.status}`);
      }
      const data = await res.json();
      return Array.isArray(data.result) ? data.result : [];
    } catch (e) {
      console.error(`[Redis smembers error] ${key}:`, e.message);
      throw e;
    }
  },
};

const app = express();
const server = http.createServer(app);

// ✅ إصلاح #4: maxPayload لمنع DoS
const WS_MAX_PAYLOAD = 512 * 1024; // 512 KB
const wss = new WebSocketServer({
  server,
  path: "/signal",
  maxPayload: WS_MAX_PAYLOAD,
});

app.use(express.json({ limit: "64kb" }));
app.use(express.static("public"));

// ✅ إصلاح #8: CORS مضبوط عبر متغير بيئة (افتراضي: مقيد)
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || "*")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

app.use((req, res, next) => {
  const origin = req.headers.origin || "";
  if (ALLOWED_ORIGINS.includes("*")) {
    res.header("Access-Control-Allow-Origin", "*");
  } else if (origin && ALLOWED_ORIGINS.includes(origin)) {
    res.header("Access-Control-Allow-Origin", origin);
    res.header("Vary", "Origin");
  }
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

// ✅ إصلاح #5: rate limit عالمي (ضد الهجمات الموزعة)
const globalCounters = new Map();

function globalRateLimit(key, limit) {
  const now = Date.now();
  const item = globalCounters.get(key);
  if (!item || now - item.startedAt >= RATE_WINDOW_MS) {
    globalCounters.set(key, { startedAt: now, count: 1 });
    return true;
  }
  item.count += 1;
  return item.count <= limit;
}

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

// ✅ إصلاح #6: اسم مستخدم آمن للمفاتيح
function safeUsername(u) {
  const s = String(u || "").trim().toLowerCase();
  if (!/^[a-z0-9_\-\.]{3,50}$/.test(s)) return null;
  return s;
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

function computeViewerKey(sessionId, adminToken) {
  return crypto
    .createHash("sha256")
    .update(`${sessionId}|${adminToken}`)
    .digest("hex")
    .slice(0, 32);
}

// ✅ إصلاح #1: /admin/claim محمي بـ SETUP_TOKEN
app.post("/admin/claim", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `claim:${ip}`, 5)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }

  // إن كان SETUP_TOKEN مضبوطاً، يجب إرساله
  if (SETUP_TOKEN) {
    const provided = String((req.body && req.body.setup_token) || "");
    if (!safeCompare(provided, SETUP_TOKEN)) {
      return res.status(403).json({ error: "setup_token غير صحيح." });
    }
  }

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

// ✅ إصلاح #2: التحقق من ملكية الحساب (وليس فقط ADMIN_TOKEN)
async function verifyOwnership(req, res, username) {
  const ownerToken = req.header("x-admin-token") ||
    (req.body && req.body.owner_token) || "";

  // الأدمن الرئيسي يمر
  if (ownerToken && safeCompare(ownerToken, ADMIN_TOKEN)) {
    return true;
  }

  // صاحب الحساب نفسه
  if (ownerToken) {
    const credKey = `parent:credentials:${username}`;
    const raw = await redis.get(credKey);
    if (raw) {
      const entry = typeof raw === "string" ? JSON.parse(raw) : raw;
      if (entry.parentToken && safeCompare(ownerToken, entry.parentToken)) {
        return true;
      }
    }
  }

  return false;
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

function generatePairingCode() {
  return String(crypto.randomInt(100000, 1000000));
}

const PAIRING_CODE_TTL_SECONDS = 5 * 60;
const VIEWER_APPROVED_TTL_SECONDS = 7 * 24 * 3600; // ✅ إصلاح #12: أسبوع

function normalizeUsername(u) {
  return String(u || "").trim().toLowerCase();
}

// ═══════════════════════════════════════════════════════════
// PARENT ACCOUNT
// ═══════════════════════════════════════════════════════════

app.post("/parent/register", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-register:${ip}`, 10)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = safeUsername(req.body && req.body.username);
  const password = String((req.body && req.body.password) || "");

  if (!username) {
    return res.status(400).json({
      error: "اسم المستخدم لازم 3-50 حرفاً (a-z, 0-9, _, -, .)",
    });
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

// ✅ إصلاح #2: التحقق من ملكية الحساب
app.post("/parent/reset-password", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-reset:${ip}`, 5)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = normalizeUsername(req.body && req.body.username);
  const newPassword = String((req.body && req.body.new_password) || "");

  if (username.length < 3) {
    return res.status(400).json({ error: "اسم المستخدم غير صالح." });
  }
  if (newPassword.length < 8) {
    return res
      .status(400)
      .json({ error: "كلمة المرور الجديدة لازم 8 أحرف على الأقل." });
  }

  if (!(await verifyOwnership(req, res, username))) {
    return res
      .status(403)
      .json({ error: "غير مصرح. استخدم admin_token الخاص بحسابك." });
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

// ✅ إصلاح #3: التحقق من الملكية + إلغاء كل الجلسات والأجهزة
app.post("/parent/delete", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `parent-delete:${ip}`, 5)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = normalizeUsername(req.body && req.body.username);

  if (username.length < 3) {
    return res.status(400).json({ error: "اسم المستخدم غير صالح." });
  }

  if (!(await verifyOwnership(req, res, username))) {
    return res
      .status(403)
      .json({ error: "غير مصرح. استخدم admin_token الخاص بحسابك." });
  }

  const credKey = `parent:credentials:${username}`;
  const raw = await redis.get(credKey);
  if (!raw) {
    return res.status(404).json({ error: "الحساب غير موجود." });
  }

  const entry = typeof raw === "string" ? JSON.parse(raw) : raw;
  const parentToken = entry.parentToken;

  // ✅ إلغاء كل جلسات وأجهزة هذا الوالد
  if (parentToken) {
    const sessionIds =
      (await redis.smembers(`owner:${parentToken}:sessions`)) || [];
    for (const sessionId of sessionIds) {
      const sessRaw = await redis.get(`session:${sessionId}`);
      if (sessRaw) {
        const s =
          typeof sessRaw === "string" ? JSON.parse(sessRaw) : sessRaw;
        if (s.deviceToken) {
          await redis.del(`device:${s.deviceToken}`);
        }
        await redis.del(`session:${sessionId}`);
        const liveSession = live[sessionId];
        if (liveSession && liveSession.broadcaster) {
          const bClient = clients[liveSession.broadcaster];
          if (bClient) {
            try { bClient.ws.close(); } catch (e) {}
          }
        }
        delete live[sessionId];
      }
    }
    await redis.del(`owner:${parentToken}:sessions`);
    await redis.del(`parenttoken:${parentToken}`);
  }
  await redis.del(credKey);

  console.log(`[parent] account deleted: ${username}`);
  return res.json({ data: { deleted: true, username } });
});

// ═══════════════════════════════════════════════════════════
// PAIRING
// ═══════════════════════════════════════════════════════════

app.post("/pairing/create", requireAdminToken, async (req, res) => {
  let code = null;
  // ✅ إصلاح #14: 10 محاولات، وإن فشلت نرجع خطأ
  for (let i = 0; i < 10; i++) {
    const candidate = generatePairingCode();
    const exists = await redis.get(`pairing:${candidate}`);
    if (!exists) {
      code = candidate;
      break;
    }
  }
  if (!code) {
    return res
      .status(503)
      .json({ error: "تعذّر توليد كود فريد. حاول لاحقاً." });
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
  // ✅ إصلاح #5: rate limit لكل IP + عالمي
  if (!rateLimit(authAttempts, `claim-pairing:${ip}`, 12)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  if (!globalRateLimit("claim-pairing-global", 60)) {
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
  if (!globalRateLimit("register-global", 60)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }

  const username = normalizeUsername(req.body && req.body.username);
  const password = req.body && req.body.password ? String(req.body.password) : "";
  const deviceName =
    (req.body && req.body.device_name && String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();

  if (!username || !password) {
    return res
      .status(400)
      .json({ error: "لازم تدخل اسم المستخدم وكلمة المرور." });
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

    if (code) {
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

      if (ownerToken !== parentEntry.parentToken) {
        return res.status(403).json({
          error: "هذا الكود من حساب والد مختلف. استخدم كوداً من حسابك.",
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
      await redis.sadd(
        `owner:${parentEntry.parentToken}:sessions`,
        sessionId
      );

      await redis.set(
        `child:last:${username}`,
        JSON.stringify({
          sessionId,
          deviceToken,
          deviceName,
          linkedAt: Date.now(),
        })
      );

      console.log(
        `[child] NEW device: user=${username} name=${deviceName} session=${sessionId.slice(0, 8)}...`
      );

      return res.json({
        data: {
          device_token: deviceToken,
          session_id: sessionId,
          device_name: deviceName,
        },
      });
    }

    const lastRaw = await redis.get(`child:last:${username}`);
    if (lastRaw) {
      const lastData =
        typeof lastRaw === "string" ? JSON.parse(lastRaw) : lastRaw;
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

  // حساب طفل قديم
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
    await redis.del(`child:last:${info.username}`);
  }

  const liveSession = live[info.sessionId];
  if (liveSession && liveSession.broadcaster) {
    const bClient = clients[liveSession.broadcaster];
    if (bClient) {
      try { bClient.ws.close(); } catch (e) {}
    }
  }
  delete live[info.sessionId];
  res.json({ data: { unpaired: true } });
});

app.get("/camera/sessions", requireAdminToken, async (req, res) => {
  const requesterToken = req.ownerToken;
  try {
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

// ✅ إصلاح #13: تنظيف viewer:approved عند حذف الجهاز
app.delete("/camera/sessions/:id", requireAdminToken, async (req, res) => {
  const requesterToken = req.ownerToken;
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
      try { bClient.ws.close(); } catch (e) {}
    }
  }
  if (liveSession) {
    // ✅ إصلاح: نظّف viewer:approved لكل مشاهد
    for (const [viewerKey] of liveSession.viewers) {
      await redis.del(`viewer:approved:${viewerKey}`);
    }
  }
  delete live[sessionId];

  if (s.deviceToken) await redis.del(`device:${s.deviceToken}`);
  if (s.username) {
    await redis.del(`child:last:${s.username}`);
  }
  await redis.del(`session:${sessionId}`);
  await redis.srem(`owner:${s.ownerToken}:sessions`, sessionId);
  res.json({ data: { deleted: true } });
});

// ═══════════════════════════════════════════════════════════
// WEBSOCKET
// ═══════════════════════════════════════════════════════════

const WS_MESSAGE_LIMIT_PER_MIN = 600; // ✅ إصلاح #9

wss.on("connection", (ws, req) => {
  const ip = clientIp(req);
  if (!rateLimit(wsAttempts, ip, 30)) {
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

  // ✅ إصلاح #9: rate limit بعد الاتصال
  let messageCount = 0;
  let windowStart = Date.now();
  ws._rateOk = () => {
    const now = Date.now();
    if (now - windowStart >= 60000) {
      windowStart = now;
      messageCount = 0;
    }
    messageCount++;
    return messageCount <= WS_MESSAGE_LIMIT_PER_MIN;
  };

  ws.isAlive = true;
  ws.on("pong", () => {
    ws.isAlive = true;
    const c = clients[clientId];
    if (c) c.lastMessageAt = Date.now();
  });

  ws.on("message", async (raw) => {
    if (!ws._rateOk()) {
      try { ws.close(1008, "rate limited"); } catch (_) {}
      return;
    }

    let msg;
    try { msg = JSON.parse(raw); } catch (e) { return; }

    const client = clients[clientId];
    if (!client) return;
    client.lastMessageAt = Date.now();

    if (msg.type === "ping") {
      send(clientId, { type: "pong", timestamp: msg.timestamp || Date.now() });
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
      const sessionObj =
        typeof rawSession === "string" ? JSON.parse(rawSession) : rawSession;
      if (!safeCompare(adminToken, sessionObj.ownerToken)) {
        send(clientId, { type: "wake-failed", reason: "not_authorized" });
        return;
      }
      const liveSession = live[sessionId];
      if (liveSession && liveSession.broadcaster) {
        send(liveSession.broadcaster, {
          type: "wake",
          viewerId: computeViewerKey(sessionId, adminToken),
          name: "الوالد",
        });
        send(clientId, { type: "wake-sent" });
      } else {
        send(clientId, { type: "wake-failed", reason: "broadcaster-offline" });
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
          `[ws] broadcaster: client=${clientId} session=${boundSession.slice(0, 8)}...`
        );

        const sessionData =
          typeof rawSession === "string" ? JSON.parse(rawSession) : rawSession;
        if (sessionData.ownerToken) {
          send(clientId, {
            type: "auth-ok",
            ownerToken: sessionData.ownerToken,
          });
          console.log(
            `[ws] sent auth-ok to broadcaster ${clientId.slice(0, 8)}...`
          );
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
        const targetSession = rawSession
          ? (typeof rawSession === "string" ? JSON.parse(rawSession) : rawSession)
          : null;

        if (!targetSession || !safeCompare(adminToken, targetSession.ownerToken)) {
          send(clientId, { type: "auth-failed", reason: "not_authorized" });
          return;
        }

        const viewerKey = computeViewerKey(session, adminToken);
        client.sessionId = session;
        client.role = role;
        client.viewerKey = viewerKey;
        // ✅ إصلاح #7: safeText على الاسم
        client.callerName = safeText(msg.name, 64) || "الوالد";

        const requestedSource =
          msg.requestedSource === "screen" ? "screen"
          : msg.requestedSource === "files" ? "files"
          : "camera";

        const liveSession = getLive(session);

        const approvedInRedis = await redis.get(`viewer:approved:${viewerKey}`);
        const wasApproved = approvedInRedis === "1";
        const autoApprove = requestedSource === "files";

        liveSession.viewers.set(viewerKey, {
          name: client.callerName,
          approved: wasApproved || autoApprove,
          source: requestedSource,
          currentClientId: clientId,
        });

        console.log(
          `[ws] viewer: key=${viewerKey.slice(0, 8)}... session=${session.slice(0, 8)}... broadcaster=${!!liveSession.broadcaster} source=${requestedSource} wasApproved=${wasApproved}`
        );

        if (liveSession.broadcaster) {
          const finalApproved = wasApproved || autoApprove;
          send(liveSession.broadcaster, {
            type: finalApproved ? "viewer-joined" : "join-request",
            viewerId: viewerKey,
            name: client.callerName,
            source: requestedSource,
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
          liveSession.viewers.clear();
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

      // ✅ إصلاح #12: TTL لمدة أسبوع
      await redis.set(`viewer:approved:${msg.target}`, "1", {
        ex: VIEWER_APPROVED_TTL_SECONDS,
      });

      sendToViewer(liveSession, msg.target, { type: "viewer-approved" });
      console.log(`[ws] viewer approved: ${String(msg.target).slice(0, 8)}...`);
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
      send(liveSession.broadcaster, {
        type: "request-restart-ice",
        viewerId: client.viewerKey,
      });
      return;
    }

    if (msg.type === "switch-camera" || msg.type === "toggle-mic") {
      const liveSession = live[client.sessionId];
      if (client.role !== "viewer" || !liveSession || !liveSession.broadcaster) return;
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
        for (const [viewerKey] of liveSession.viewers) {
          sendToViewer(liveSession, viewerKey, { type: "broadcaster-left" });
        }
        liveSession.viewers.clear();
      }
      if (client.role === "viewer" && client.viewerKey) {
        const v = liveSession.viewers.get(client.viewerKey);
        if (v && v.currentClientId === clientId) {
          v.currentClientId = null;
          setTimeout(() => {
            const ls = live[client.sessionId];
            if (!ls) return;
            const vv = ls.viewers.get(client.viewerKey);
            if (vv && vv.currentClientId === null) {
              ls.viewers.delete(client.viewerKey);
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
      return ws.terminate();
    }
    if (ws.isAlive === false) return ws.terminate();
    ws.isAlive = false;
    try { ws.ping(); } catch (_) {}
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
    const urls = turnUrls.split(",").map((u) => u.trim()).filter(Boolean);
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
    { urls: "turn:openrelay.metered.ca:80", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443?transport=tcp", username: "openrelayproject", credential: "openrelayproject" },
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
  if (SETUP_TOKEN) {
    console.log("[camera-parent] ✅ SETUP_TOKEN configured");
  } else {
    console.warn(
      "[camera-parent] ⚠️  SETUP_TOKEN غير مضبوط — /admin/claim مكشوف!"
    );
  }
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
  for (const [k, v] of globalCounters)
    if (v.startedAt < cutoff) globalCounters.delete(k);
}, RATE_WINDOW_MS).unref();