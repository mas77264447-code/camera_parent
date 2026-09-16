require("dotenv").config();
const crypto = require("crypto");
const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");

// ============================================
// Upstash Redis - Persistent Storage
// ============================================
const UPSTASH_URL = process.env.UPSTASH_REDIS_REST_URL;
const UPSTASH_TOKEN = process.env.UPSTASH_REDIS_REST_TOKEN;

if (!UPSTASH_URL || !UPSTASH_TOKEN) {
  console.error(
    "[ERROR] Missing UPSTASH_REDIS_REST_URL or UPSTASH_REDIS_REST_TOKEN environment variables!"
  );
  console.error("Set them in Render Dashboard > Settings > Environment");
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

      if (opts?.ex) {
        url += `/EX/${opts.ex}`;
      }

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
      console.error(`[Redis DEL Error] ${k}:`, e.message);
      return 0;
    }
  },

  async sadd(key, member) {
    try {
      const res = await fetch(
        `${UPSTASH_URL}/sadd/${key}/${encodeURIComponent(member)}`,
        {
          headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` },
        }
      );
      const data = await res.json();
      return data.result ? 1 : 0;
    } catch (e) {
      console.error(`[Redis SADD Error] ${key}:`, e.message);
      return 0;
    }
  },

  async srem(key, member) {
    try {
      const res = await fetch(
        `${UPSTASH_URL}/srem/${key}/${encodeURIComponent(member)}`,
        {
          headers: { Authorization: `Bearer ${UPSTASH_TOKEN}` },
        }
      );
      const data = await res.json();
      return data.result ? 1 : 0;
    } catch (e) {
      console.error(`[Redis SREM Error] ${key}:`, e.message);
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
      console.error(`[Redis SMEMBERS Error] ${key}:`, e.message);
      return [];
    }
  },
};

const app = express();
const server = http.createServer(app);
const MAX_FILE_BYTES = 25 * 1024 * 1024;
const wss = new WebSocketServer({
  server,
  path: "/signal",
  maxPayload: 256 * 1024,
  perMessageDeflate: false,
});

// Native mobile clients do not need wildcard CORS. Keep JSON requests small
// and add conservative security headers without adding a runtime dependency.
app.disable("x-powered-by");
app.use(express.json({ limit: "32kb" }));
app.use((req, res, next) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("Cache-Control", "no-store");
  next();
});

// ------------------------------------------------------------------
// Admin Token Management
// ------------------------------------------------------------------
function getConfiguredAdminToken() {
  const token = String(process.env.ADMIN_TOKEN || "").trim();
  if (!token || token.length < 32) {
    throw new Error("ADMIN_TOKEN must be configured and contain at least 32 characters.");
  }
  return token;
}

let ADMIN_TOKEN = null;

const RATE_WINDOW_MS = 60 * 1000;
const authAttempts = new Map();
const wsAttempts = new Map();

function clientIp(req) {
  return String(req.headers["x-forwarded-for"] || req.socket.remoteAddress || "unknown")
    .split(",")[0].trim();
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

function sameSessionTarget(client, targetId) {
  const target = clients[String(targetId)];
  return !!target && !!client.sessionId && target.sessionId === client.sessionId;
}

// ------------------------------------------------------------------
// Admin Claim Endpoint
// ------------------------------------------------------------------
app.post("/admin/claim", (req, res) => {
  // Disabled intentionally. A public bootstrap endpoint must never disclose
  // the administrator credential. Set ADMIN_TOKEN in the server environment
  // and enter it once in the owner app.
  return res.status(410).json({
    error: "الربط التلقائي معطل لأسباب أمنية. استخدم ADMIN_TOKEN من إعدادات السيرفر.",
  });
});

// ------------------------------------------------------------------
// Admin Verify Endpoint (for recovery)
// ------------------------------------------------------------------
app.post("/admin/verify", (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `verify:${ip}`, 10)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const token = (req.body && req.body.admin_token) || "";
  if (token && token === ADMIN_TOKEN) {
    res.json({ data: { valid: true } });
  } else {
    res.status(403).json({ error: "توكن غير صحيح." });
  }
});

function requireAdminToken(req, res, next) {
  const provided = req.query.token || req.header("x-admin-token");

  if (provided && provided === ADMIN_TOKEN) {
    return next();
  }

  res.status(403).send("غير مصرح لك بالدخول هنا.");
}

// ------------------------------------------------------------------
// Runtime State (in-memory, resets on restart)
// ------------------------------------------------------------------
const clients = {};
let nextClientId = 1;
const live = {};

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
  return String(Math.floor(100000 + Math.random() * 900000));
}

const PAIRING_CODE_TTL_SECONDS = 5 * 60;

// ------------------------------------------------------------------
// Password Hashing (scrypt, salted)
// ------------------------------------------------------------------
function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString("hex");
}

function verifyPassword(password, salt, expectedHash) {
  try {
    const candidate = hashPassword(password, salt);
    const a = Buffer.from(candidate, "hex");
    const b = Buffer.from(expectedHash, "hex");
    if (a.length !== b.length) return false;
    return crypto.timingSafeEqual(a, b);
  } catch (e) {
    return false;
  }
}

// ------------------------------------------------------------------
// Pairing System
// ------------------------------------------------------------------
app.post("/pairing/create", requireAdminToken, async (req, res) => {
  let code = generatePairingCode();

  for (let i = 0; i < 5; i++) {
    const exists = await redis.get(`pairing:${code}`);
    if (!exists) break;
    code = generatePairingCode();
  }

  await redis.set(
    `pairing:${code}`,
    JSON.stringify({ ownerToken: ADMIN_TOKEN }),
    { ex: PAIRING_CODE_TTL_SECONDS }
  );

  res.json({
    data: {
      code,
      expires_in_seconds: PAIRING_CODE_TTL_SECONDS,
    },
  });
});

app.post("/pairing/claim", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `claim-pairing:${ip}`, 12)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();
  const deviceName =
    (req.body &&
      req.body.device_name &&
      String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";

  const raw = await redis.get(`pairing:${code}`);
  if (!raw) {
    res
      .status(400)
      .json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
    return;
  }

  await redis.del(`pairing:${code}`);

  const entry = typeof raw === "string" ? JSON.parse(raw) : raw;
  const ownerToken = entry.ownerToken;

  const sessionId = crypto.randomBytes(16).toString("hex");
  const deviceToken = crypto.randomBytes(24).toString("hex");

  const sessionData = {
    name: deviceName,
    createdAt: Date.now(),
    ownerToken,
    deviceToken,
  };

  await redis.set(`session:${sessionId}`, JSON.stringify(sessionData));
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

// ------------------------------------------------------------------
// Username/Password Registration (permanent credentials, no admin
// pairing-code needed). أول مرة تدخل بيوزر وباسورد جدد بيتسجل جهاز
// جديد. لو نفس اليوزر موجود قبل كده، لازم نفس الباسورد وبيرجعلك نفس
// الـ device_token/session_id القدام (مفيد لو التطبيق اتمسح وعايز
// ترجع لنفس الجهاز من غير كود جديد من الوالد).
// ------------------------------------------------------------------
app.post("/pairing/register", async (req, res) => {
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `register:${ip}`, 12)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const username = (
    req.body && req.body.username ? String(req.body.username).trim() : ""
  ).toLowerCase();
  const password =
    (req.body && req.body.password ? String(req.body.password) : "");
  const deviceName =
    (req.body &&
      req.body.device_name &&
      String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();

  if (!username || !password) {
    res.status(400).json({ error: "لازم تدخل اسم المستخدم وكلمة المرور." });
    return;
  }
  if (password.length < 12) {
    res.status(400).json({ error: "كلمة المرور لازم تكون 12 حرفًا على الأقل." });
    return;
  }

  const credKey = `credentials:${username}`;
  const raw = await redis.get(credKey);

  if (raw) {
    // اليوزر ده متسجل قبل كده - تحقق من الباسورد ورجّع نفس الجلسة
    // (مش محتاجين كود هنا؛ الكود مطلوب أول مرة بس وقت إنشاء الحساب)
    const entry = typeof raw === "string" ? JSON.parse(raw) : raw;
    const ok = verifyPassword(password, entry.salt, entry.passwordHash);

    if (!ok) {
      res
        .status(401)
        .json({ error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
      return;
    }

    res.json({
      data: {
        device_token: entry.deviceToken,
        session_id: entry.sessionId,
        device_name: entry.deviceName,
      },
    });
    return;
  }

  // يوزر جديد - لازم كود صادر من تطبيق الوالد (شاشة "إضافة جهاز") عشان
  // نتأكد إن الوالد فعلاً هو اللي بيوافق على ربط الجهاز ده بحسابه.
  if (!code) {
    res
      .status(400)
      .json({ error: "لازم كود من تطبيق الوالد لأول تسجيل دخول." });
    return;
  }

  const pairingRaw = await redis.get(`pairing:${code}`);
  if (!pairingRaw) {
    res
      .status(400)
      .json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
    return;
  }
  // الكود يُستخدم مرة واحدة بس
  await redis.del(`pairing:${code}`);

  const pairingEntry =
    typeof pairingRaw === "string" ? JSON.parse(pairingRaw) : pairingRaw;
  const ownerToken = pairingEntry.ownerToken;

  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = hashPassword(password, salt);

  const sessionId = crypto.randomBytes(16).toString("hex");
  const deviceToken = crypto.randomBytes(24).toString("hex");

  const sessionData = {
    name: deviceName,
    createdAt: Date.now(),
    ownerToken,
    deviceToken,
  };

  await redis.set(`session:${sessionId}`, JSON.stringify(sessionData));
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
  const ip = clientIp(req);
  if (!rateLimit(authAttempts, `unpair:${ip}`, 20)) {
    return res.status(429).json({ error: "محاولات كثيرة. حاول لاحقًا." });
  }
  const deviceToken = req.header("x-device-token") || "";
  const raw = await redis.get(`device:${deviceToken}`);

  if (!raw) {
    res.status(404).json({ error: "الجهاز غير مقترن." });
    return;
  }

  const info = typeof raw === "string" ? JSON.parse(raw) : raw;

  await redis.del(`device:${deviceToken}`);
  await redis.del(`session:${info.sessionId}`);
  await redis.srem(`owner:${info.ownerToken}:sessions`, info.sessionId);

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

// ------------------------------------------------------------------
// Camera Sessions (Protected)
// ------------------------------------------------------------------
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

// ------------------------------------------------------------------
// Delete Device Session
// ------------------------------------------------------------------
app.delete("/camera/sessions/:id", requireAdminToken, async (req, res) => {
  const requesterToken = req.query.token || req.header("x-admin-token");
  const sessionId = req.params.id;

  const raw = await redis.get(`session:${sessionId}`);
  if (!raw) {
    res.status(404).json({ error: "الجهاز غير موجود." });
    return;
  }

  const s = typeof raw === "string" ? JSON.parse(raw) : raw;

  if (s.ownerToken !== requesterToken) {
    res.status(404).json({ error: "الجهاز غير موجود." });
    return;
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

  if (s.deviceToken) {
    await redis.del(`device:${s.deviceToken}`);
  }
  await redis.del(`session:${sessionId}`);
  await redis.srem(`owner:${s.ownerToken}:sessions`, sessionId);

  res.json({ data: { deleted: true } });
});

// ------------------------------------------------------------------
// WebSocket Signaling
// ------------------------------------------------------------------
wss.on("connection", (ws, req) => {
  const ip = clientIp(req);
  if (!rateLimit(wsAttempts, ip, 30)) {
    try { ws.close(1013, "rate limited"); } catch (_) {}
    return;
  }

  const clientId = String(nextClientId++);
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
    if (!client || !msg || typeof msg !== "object" || Array.isArray(msg)) return;
    if (typeof msg.type !== "string" || msg.type.length > 64) return;
    client.lastMessageAt = Date.now();

    // ------ Ping / Pong (app-level, keeps NAT/proxy connections alive) ------
    if (msg.type === "ping") {
      send(clientId, { type: "pong", timestamp: msg.timestamp || Date.now() });
      return;
    }

    // ------ Register Broadcaster ------
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
          `[ws] broadcaster registered: client=${clientId} session=${boundSession} name=${deviceInfo.deviceName}`
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

      // ------ Register Viewer ------
      if (role === "viewer") {
        const adminToken = safeText(msg.adminToken, 256);
        const rawSession = await redis.get(`session:${session}`);
        const targetSession = rawSession
          ? typeof rawSession === "string"
            ? JSON.parse(rawSession)
            : rawSession
          : null;

        if (!targetSession || adminToken !== targetSession.ownerToken) {
          console.log(
            `[ws] viewer auth-failed: client=${clientId} session=${session} sessionExists=${!!targetSession}`
          );
          send(clientId, { type: "auth-failed", reason: "not_authorized" });
          return;
        }

        client.sessionId = session;
        client.role = role;
        client.callerName = msg.name || "الوالد";

        // viewerKey stays stable across WebSocket reconnects. The viewer screen
        // uses its paired session id as this key, so a transient network loss
        // does not create a brand-new approval record every time.
        const viewerKey = safeText(msg.viewerKey || session, 128) || session;
        client.viewerKey = viewerKey;

        // نوع البث المطلوب من الوالد: "camera" أو "screen". أي قيمة
        // تانية أو مفقودة بترجع "camera" افتراضيًا.
        const requestedSource = ["screen", "files"].includes(msg.requestedSource) ? msg.requestedSource : "camera";

        const liveSession = getLive(session);

        // Replace an older socket for the same logical viewer, but preserve
        // its approval state. This is the key part of reconnect recovery.
        let previousViewer = null;
        for (const [oldViewerId, info] of liveSession.viewers) {
          if (info.viewerKey === viewerKey) {
            previousViewer = { oldViewerId, info };
            liveSession.viewers.delete(oldViewerId);
            if (oldViewerId !== clientId) {
              const oldClient = clients[oldViewerId];
              if (oldClient) {
                try { oldClient.ws.close(1000, "replaced"); } catch (_) {}
              }
            }
            break;
          }
        }

        const approved = previousViewer?.info.approved === true;
        liveSession.viewers.set(clientId, {
          name: client.callerName,
          viewerKey,
          approved,
          source: requestedSource,
        });

        console.log(
          `[ws] viewer registered: client=${clientId} session=${session} broadcasterOnline=${!!liveSession.broadcaster} source=${requestedSource} approved=${approved}`
        );

        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, {
            type: approved ? "viewer-joined" : "join-request",
            viewerId: clientId,
            name: client.callerName,
            source: requestedSource,
          });
        } else {
          send(clientId, { type: "await-approval" });
        }
        return;
      }

      return;
    }

    // ------ Leave ------
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

        if (
          !liveSession.broadcaster &&
          liveSession.viewers.size === 0
        ) {
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

    // ------ Approve Viewer ------
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
      return;
    }

    // ------ Reject Viewer ------
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

    // ------ Permission / File Request (viewer -> child broadcaster) ------
    if (msg.type === "permission-request") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "viewer" ||
        !liveSession ||
        !liveSession.broadcaster
      ) return;

      const viewerInfo = liveSession.viewers.get(clientId);
      if (!viewerInfo || !viewerInfo.approved) return;

      const kind = ["gallery_photo", "gallery_video", "file_pick"].includes(msg.kind)
        ? msg.kind
        : null;
      if (!kind) return;

      send(liveSession.broadcaster, {
        type: "permission-request",
        requestId: String(msg.requestId || crypto.randomUUID()),
        kind,
        viewerId: clientId,
        name: client.callerName || "الوالد",
      });
      return;
    }

    // ------ Permission Response (child broadcaster -> parent viewer) ------
    if (msg.type === "permission-response") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) return;

      const target = String(msg.target || "");
      const viewerInfo = liveSession.viewers.get(target);
      if (!viewerInfo) return;

      send(target, {
        type: "permission-response",
        requestId: String(msg.requestId || ""),
        kind: msg.kind,
        granted: msg.granted === true,
        error: msg.error || null,
      });
      return;
    }

    // ------ File Transfer (child broadcaster -> parent viewer) ------
    if (msg.type === "file-transfer-start" || msg.type === "file-transfer-chunk" || msg.type === "file-transfer-end") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) return;

      const target = String(msg.target || "");
      const viewerInfo = liveSession.viewers.get(target);
      if (!viewerInfo) return;

      if (msg.type === "file-transfer-start") {
        const size = Number(msg.size || 0);
        if (!Number.isFinite(size) || size < 0 || size > MAX_FILE_BYTES) {
          return;
        }
        send(target, {
          type: "file-transfer-start",
          requestId: String(msg.requestId || ""),
          name: String(msg.name || "file"),
          size,
          mime: String(msg.mime || "application/octet-stream"),
        });
      } else if (msg.type === "file-transfer-chunk") {
        const data = String(msg.data || "");
        // كل chunk يجب أن يبقى صغيرًا حتى لا تُستهلك ذاكرة السيرفر برسالة ضخمة.
        if (data.length > 100000) return;
        send(target, {
          type: "file-transfer-chunk",
          requestId: String(msg.requestId || ""),
          index: Number(msg.index || 0),
          data,
        });
      } else {
        send(target, {
          type: "file-transfer-end",
          requestId: String(msg.requestId || ""),
        });
      }
      return;
    }

    // ------ File Browser: viewer -> child ------
    if (msg.type === "file-browser-list" || msg.type === "file-browser-download") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "viewer" ||
        !liveSession ||
        !liveSession.broadcaster
      ) return;

      const viewerInfo = liveSession.viewers.get(clientId);
      if (!viewerInfo || !viewerInfo.approved || viewerInfo.source !== "files") return;

      const payload = {
        type: msg.type,
        requestId: String(msg.requestId || crypto.randomUUID()),
        viewerId: clientId,
      };

      if (msg.type === "file-browser-list") {
        payload.uri = msg.uri ? String(msg.uri) : null;
      } else {
        payload.uri = msg.uri ? String(msg.uri) : "";
        payload.name = msg.name ? String(msg.name) : "file";
      }

      send(liveSession.broadcaster, payload);
      return;
    }

    // ------ File Browser responses: child -> viewer ------
    if (
      msg.type === "file-browser-ready" ||
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
      if (!viewerInfo || !viewerInfo.approved || viewerInfo.source !== "files") return;

      if (msg.type === "file-browser-ready") {
        send(target, {
          type: "file-browser-ready",
          granted: msg.granted === true,
          error: msg.error || null,
        });
      } else {
        send(target, {
          type: "file-browser-list-response",
          requestId: String(msg.requestId || ""),
          ok: msg.ok === true,
          items: Array.isArray(msg.items) ? msg.items : [],
          error: msg.error || null,
        });
      }
      return;
    }

    // ------ Offer ------
    if (msg.type === "offer") {
      const liveSession = live[client.sessionId];
      if (
        client.role !== "broadcaster" ||
        !liveSession ||
        liveSession.broadcaster !== clientId
      ) {
        console.log(
          `[ws] offer REJECTED: client=${clientId} role=${client.role} hasSession=${!!liveSession}`
        );
        return;
      }

      const viewerInfo = liveSession.viewers.get(msg.viewerId);
      if (!viewerInfo) {
        console.log(
          `[ws] offer DROPPED - viewer not found: viewerId=${msg.viewerId} knownViewers=${[
            ...liveSession.viewers.keys(),
          ]}`
        );
        return;
      }

      console.log(
        `[ws] offer forwarded: from=${clientId} to=${msg.viewerId}`
      );
      send(msg.viewerId, { type: "offer", sdp: msg.sdp, from: clientId });
      return;
    }

    // ------ Answer ------
    if (msg.type === "answer") {
      const liveSession = live[client.sessionId];
      if (liveSession && liveSession.broadcaster) {
        console.log(
          `[ws] answer forwarded: from=${clientId} to=${liveSession.broadcaster}`
        );
        send(liveSession.broadcaster, {
          type: "answer",
          sdp: msg.sdp,
          viewerId: clientId,
        });
      } else {
        console.log(
          `[ws] answer DROPPED - no broadcaster: client=${clientId} session=${client.sessionId}`
        );
      }
      return;
    }

    // ------ ICE Candidate ------
    if (msg.type === "ice") {
      const targetId = String(msg.target || "");
      if (!sameSessionTarget(client, targetId)) return;
      const target = clients[targetId];
      if (!target || !target.role || target.role === client.role) return;
      send(targetId, { type: "ice", candidate: msg.candidate, from: clientId });
      return;
    }

    // ------ Switch Camera ------
    if (msg.type === "switch-camera") {
      if (client.role !== "broadcaster") return;
      const targetId = String(msg.target || "");
      if (!sameSessionTarget(client, targetId)) return;
      const target = clients[targetId];
      const liveSession = live[client.sessionId];
      if (!target || !liveSession || liveSession.broadcaster !== clientId) return;
      if (!liveSession.viewers.has(targetId)) return;
      send(targetId, { type: "switch-camera" });
      return;
    }

    // ------ Toggle Mic ------
    if (msg.type === "toggle-mic") {
      if (client.role !== "broadcaster") return;
      const targetId = String(msg.target || "");
      if (!sameSessionTarget(client, targetId)) return;
      const liveSession = live[client.sessionId];
      if (!liveSession || liveSession.broadcaster !== clientId || !liveSession.viewers.has(targetId)) return;
      send(targetId, { type: "toggle-mic" });
      return;
    }

    // ------ Kick ------
    if (msg.type === "kick") {
      const liveSession = live[client.sessionId];
      if (
        client.role === "broadcaster" &&
        liveSession &&
        liveSession.broadcaster === clientId
      ) {
        const targetId = String(msg.target || "");
        if (!sameSessionTarget(client, targetId) || !liveSession.viewers.has(targetId)) return;
        const target = clients[targetId];
        if (target) {
          send(targetId, { type: "kicked" });
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

      if (client.role === "broadcaster" && liveSession.broadcaster === clientId) {
        // Keep viewer records while the broadcaster is temporarily offline.
        // When the broadcaster reconnects, approved viewers are re-announced
        // and a fresh WebRTC offer can be negotiated.
        liveSession.broadcaster = null;
        for (const [viewerId] of liveSession.viewers) {
          send(viewerId, { type: "broadcaster-left" });
        }
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

// ------------------------------------------------------------------
// Heartbeat
// ------------------------------------------------------------------
const HEARTBEAT_INTERVAL = 10000; // 10s بدل 15s - يكتشف الانقطاع أسرع
const WS_IDLE_TIMEOUT = 35000; // لو مفيش أي رسالة/pong خلال 35 ثانية، اقفل الاتصال

const heartbeatInterval = setInterval(() => {
  const now = Date.now();

  wss.clients.forEach((ws) => {
    const entry = Object.entries(clients).find(([, c]) => c.ws === ws);
    const clientId = entry ? entry[0] : null;
    const client = clientId ? clients[clientId] : null;

    if (client && now - client.lastMessageAt > WS_IDLE_TIMEOUT) {
      console.log(`[ws] idle timeout: client=${clientId}`);
      return ws.terminate();
    }

    if (ws.isAlive === false) {
      console.log(`[ws] no pong received: client=${clientId ?? "?"}`);
      return ws.terminate();
    }

    ws.isAlive = false;
    try {
      ws.ping();
    } catch (_) {}
  });
}, HEARTBEAT_INTERVAL);

wss.on("close", () => clearInterval(heartbeatInterval));

// ------------------------------------------------------------------
// ICE Servers
// ------------------------------------------------------------------
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
    console.warn(
      "[camera-parent] مفيش TURN_URLS متظبط - النظام هيستخدم سيرفر TURN " +
        "مجاني عام (openrelay.metered.ca) وده بطيء ومحدود. للاستخدام " +
        "الجاد، اعمل TURN خاص واظبط TURN_URLS / TURN_USERNAME / " +
        "TURN_CREDENTIAL."
    );
  }

  // openrelay كـ fallback أخير فقط لو مفيش TURN_URLS متظبط
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

app.get("/ice-servers", requireAdminToken, (req, res) => {
  res.json({ data: getIceServers() });
});

// نقطة تشخيص سريعة لمعرفة حالة الاتصالات الحية (Broadcaster/Viewers)
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

app.get("/camera/view", (req, res) => {
  res
    .status(410)
    .send(
      "تم إيقاف هذا المسار. المشاهدة الآن تتم فقط من لوحة الوالد بعد تسجيل الدخول."
    );
});

// ------------------------------------------------------------------
// Dashboard
// ------------------------------------------------------------------
app.get("/dashboard", requireAdminToken, (req, res) => {
  const dashboardToken = req.query.token;
  res.send(`
    <html>
      <head>
        <meta charset="utf-8">
        <title>لوحة الكاميرات</title>
        <style>
          * { box-sizing: border-box; }
          body { margin:0; font-family: sans-serif; background:#0d0d0d; color:#eee; display:flex; height:100vh; direction: rtl; }
          #sidebar { width: 260px; background:#161616; overflow-y:auto; border-left: 1px solid #2a2a2a; flex-shrink:0; }
          #sidebar h2 { padding:16px; margin:0; font-size:16px; border-bottom:1px solid #2a2a2a; }
          .cam-item { padding:14px 16px; cursor:pointer; border-bottom:1px solid #222; display:flex; align-items:center; justify-content:space-between; }
          .cam-item:hover { background:#222; }
          .cam-item.active { background:#3a2a5c; }
          .dot { width:10px; height:10px; border-radius:50%; display:inline-block; margin-left:8px; }
          .online { background:#2ecc71; }
          .offline { background:#666; }
          #main { flex:1; display:flex; flex-direction:column; align-items:center; justify-content:center; position:relative; }
          #main video { max-width:100%; max-height:100vh; }
          #placeholder { color:#666; font-size:18px; }
          #camTitle { position:absolute; top:12px; right:16px; background:rgba(0,0,0,0.5); padding:6px 14px; border-radius:20px; font-size:14px; }
        </style>
      </head>
      <body>
        <div id="sidebar">
          <h2>الكاميرات المتصلة</h2>
          <div id="camList"></div>
        </div>
        <div id="main">
          <div id="camTitle" style="display:none;"></div>
          <video id="camView" autoplay playsinline muted style="display:none;"></video>
          <video id="localVideo2" autoplay playsinline muted style="display:none; position:absolute; bottom:60px; left:16px; width:110px; border-radius:8px; border:2px solid #fff; background:#000;"></video>
          <button id="unmuteBtn2" style="display:none; margin-top:12px; padding:10px 20px; border-radius:20px; border:none; background:#6c3fc5; color:#fff; font-size:14px;">تشغيل الصوت 🔊</button>
          <div id="placeholder">اختار كاميرا من القائمة للمشاهدة</div>
        </div>

        <script>
          let iceServers = [{ urls: "stun:stun.l.google.com:19302" }];
          const dashboardToken = ${JSON.stringify(dashboardToken || "")};
          let currentSession = null;
          let ws = null;
          let pc = null;
          let broadcasterId = null;

          async function loadIceServers() {
            try {
              const res = await fetch("/ice-servers");
              const json = await res.json();
              if (Array.isArray(json.data) && json.data.length) {
                iceServers = json.data;
              }
            } catch (e) {}
          }

          loadIceServers();

          if (window.history && window.history.replaceState && dashboardToken) {
            const cleanUrl = location.pathname;
            window.history.replaceState({}, document.title, cleanUrl);
          }

          async function loadSessions() {
            try {
              const res = await fetch('/camera/sessions', {
                headers: { 'X-Admin-Token': dashboardToken },
              });
              const json = await res.json();
              const list = json.data || [];
              const container = document.getElementById('camList');
              container.innerHTML = '';

              if (list.length === 0) {
                container.innerHTML = '<div style="padding:16px;color:#777;">مفيش كاميرات لسه</div>';
              }

              list.forEach(cam => {
                const div = document.createElement('div');
                div.className = 'cam-item' + (cam.session_id === currentSession ? ' active' : '');
                div.onclick = () => selectCamera(cam.session_id, cam.name);
                const dot = '<span class="dot ' + (cam.online ? 'online' : 'offline') + '"></span>';
                div.innerHTML = '<span>' + cam.name + '</span>' + dot;
                container.appendChild(div);
              });
            } catch (e) {}
          }

          function cleanupConnection() {
            if (pc) { pc.close(); pc = null; }
            if (ws) { ws.close(); ws = null; }
            const lv = document.getElementById("localVideo2");
            if (lv.srcObject) {
              lv.srcObject.getTracks().forEach(t => t.stop());
              lv.srcObject = null;
            }
            broadcasterId = null;
          }

          function selectCamera(sessionId, name) {
            cleanupConnection();
            currentSession = sessionId;

            document.getElementById('placeholder').style.display = 'none';
            document.getElementById('camView').style.display = 'block';
            document.getElementById('camTitle').style.display = 'block';
            document.getElementById('camTitle').innerText = name;

            const wsProto = location.protocol === "https:" ? "wss" : "ws";
            ws = new WebSocket(wsProto + "://" + location.host + "/signal");

            ws.onopen = () => {
              ws.send(JSON.stringify({ type: "register", role: "viewer", session: sessionId, adminToken: dashboardToken, requestedSource: "camera" }));
            };

            ws.onmessage = async (event) => {
              const msg = JSON.parse(event.data);

              if (msg.type === "offer") {
                broadcasterId = msg.from;
                pc = new RTCPeerConnection({ iceServers });

                pc.ontrack = (e) => {
                  const video = document.getElementById("camView");
                  video.srcObject = e.streams[0];
                  video.play().catch(() => {});
                  document.getElementById("unmuteBtn2").style.display = "inline-block";
                };

                pc.onicecandidate = (e) => {
                  if (e.candidate) {
                    ws.send(JSON.stringify({ type: "ice", candidate: e.candidate, target: broadcasterId }));
                  }
                };

                try {
                  const localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
                  const lv = document.getElementById("localVideo2");
                  lv.srcObject = localStream;
                  lv.style.display = "block";
                  localStream.getTracks().forEach(track => pc.addTrack(track, localStream));
                } catch (e) {}

                await pc.setRemoteDescription(new RTCSessionDescription(msg.sdp));
                const answer = await pc.createAnswer();
                await pc.setLocalDescription(answer);
                ws.send(JSON.stringify({ type: "answer", sdp: answer }));
              }

              if (msg.type === "ice" && pc) {
                try { await pc.addIceCandidate(msg.candidate); } catch (e) {}
              }

              if (msg.type === "kicked") {
                cleanupConnection();
                currentSession = null;
                document.getElementById('camView').style.display = 'none';
                document.getElementById('camTitle').style.display = 'none';
                document.getElementById('unmuteBtn2').style.display = 'none';
                const ph = document.getElementById('placeholder');
                ph.style.display = 'block';
                ph.innerText = 'تم إنهاء الاتصال بواسطة صاحب الكاميرا';
              }
            };

            loadSessions();
          }

          setInterval(loadSessions, 3000);
          loadSessions();

          document.getElementById("unmuteBtn2").addEventListener("click", () => {
            const video = document.getElementById("camView");
            video.muted = false;
            video.volume = 1.0;
            video.play().catch(() => {});
            document.getElementById("unmuteBtn2").style.display = "none";
          });
        </script>
      </body>
    </html>
  `);
});

app.get("/", (req, res) => {
  res.send("Camera Parent server is running.");
});

const PORT = process.env.PORT || 8080;

// ------------------------------------------------------------------
// Initialize
// ------------------------------------------------------------------
(async () => {
  ADMIN_TOKEN = await getOrCreateAdminToken();
  console.log(
    `[camera-parent] ✅ ADMIN_TOKEN الحالي: ${ADMIN_TOKEN}`
  );
  console.log(
    "[camera-parent] احتفظ بالقيمة دي في مكان آمن - لو فقدت بيانات تطبيق " +
      'الوالد تقدر تستخدمها من خيار "استرجاع الاقتران" في التطبيق.'
  );
  console.log("[camera-parent] ✅ متصل بـ Upstash Redis");

  server.listen(PORT, () => {
    console.log(`✅ Server running on port ${PORT}`);
  });
})();


setInterval(() => {
  const cutoff = Date.now() - RATE_WINDOW_MS;
  for (const [k, v] of authAttempts) if (v.startedAt < cutoff) authAttempts.delete(k);
  for (const [k, v] of wsAttempts) if (v.startedAt < cutoff) wsAttempts.delete(k);
}, RATE_WINDOW_MS).unref();
