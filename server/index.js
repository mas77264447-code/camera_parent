require("dotenv").config();
const crypto = require("crypto");
const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const { Redis } = require("@upstash/redis");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/signal" });

app.use(express.json());

app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS");
  res.header("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token, X-Device-Token");
  next();
});

// ------------------------------------------------------------------
// تخزين دائم (Upstash Redis) بدل الملفات المحلية / الذاكرة بس.
// ------------------------------------------------------------------
// المشكلة القديمة: Render (الخطة المجانية) بيمسح قرص السيرفر بالكامل
// مع كل عملية إعادة نشر (redeploy) أو إعادة تشغيل - سواء كان التخزين
// في ملف (.admin_token / .admin_claimed) أو في متغيرات JS في الذاكرة
// (sessions / deviceTokens / pairingCodes). يعني كل ما تعمل ديبلوي
// جديد، الاقتران القديم (claim الوالد + كل أجهزة الأطفال المقترنة)
// كان بيتمسح.
//
// الحل: أي بيانات لازم تعيش لفترة طويلة (توكن الوالد، حالة الـ claim،
// الأجهزة المقترنة device_token، بيانات الجلسات) بقت متخزنة في Upstash
// Redis - قاعدة بيانات خارجية مجانية مستضافة بره Render، فمش بتتأثر
// خالص بإعادة نشر أو إعادة تشغيل سيرفر Render.
//
// أما حالة الاتصال اللحظية (مين متصل دلوقتي فعليًا عبر WebSocket) فده
// طبيعي يتصفر مع كل إعادة تشغيل مهما كان نوع التخزين - لأن الاتصال
// نفسه (TCP/WebSocket) بينقطع وقتها على أي حال. تطبيق الموبايل أصلًا
// فيه منطق إعادة اتصال تلقائي (`_scheduleReconnect`)، فبمجرد ما
// السيرفر يرجع يشتغل، الأجهزة بترجع تتسجل تلقائيًا خلال ثواني من
// غير ما تحتاج اقتران جديد - لأن الـ device_token نفسه لسه محفوظ في
// Redis.
//
// الإعداد المطلوب (مرة واحدة بس):
//   1) اعمل حساب مجاني على https://upstash.com
//   2) اعمل Redis database جديدة (اختار أي region قريب)
//   3) من صفحة الـ database، انسخ "UPSTASH_REDIS_REST_URL" و
//      "UPSTASH_REDIS_REST_TOKEN"
//   4) في Render، Environment > Add Environment Variable، وضيفهم
//      بنفس الاسمين دول بالظبط.
//   5) اعمل Manual Deploy مرة أخيرة - من هنا وطالع، الاقتران والأجهزة
//      المقترنة هيفضلوا موجودين مهما عملت ديبلوي كذا مرة.
// ------------------------------------------------------------------
if (!process.env.UPSTASH_REDIS_REST_URL || !process.env.UPSTASH_REDIS_REST_TOKEN) {
  console.error(
    "[camera-parent] لازم تحدد UPSTASH_REDIS_REST_URL و UPSTASH_REDIS_REST_TOKEN " +
      "كـ environment variables عشان التخزين الدائم يشتغل (شوف التعليق فوق " +
      "في بداية الملف للتفاصيل). السيرفر مش هيشتغل من غيرهم."
  );
  process.exit(1);
}

const redis = new Redis({
  url: process.env.UPSTASH_REDIS_REST_URL,
  token: process.env.UPSTASH_REDIS_REST_TOKEN,
});

const PAIRING_CODE_TTL_SECONDS = 5 * 60;

// ------------------------------------------------------------------
// توكن إداري (Admin Token) - بيتولد مرة واحدة بس ويتخزن في Redis
// (أو يتقرأ من متغير بيئة ADMIN_TOKEN لو معمول له set يدويًا). بيفضل
// نفس القيمة عبر كل عمليات إعادة النشر.
// ------------------------------------------------------------------
async function getOrCreateAdminToken() {
  if (process.env.ADMIN_TOKEN) return process.env.ADMIN_TOKEN;

  const existing = await redis.get("admin:token");
  if (existing) return existing;

  const generated = crypto.randomBytes(24).toString("hex");
  await redis.set("admin:token", generated);
  return generated;
}

let ADMIN_TOKEN = null;

// ------------------------------------------------------------------
// أول تطبيق والد يفتح السيرفر ده هو اللي "يتبنى" (claim) الـ
// ADMIN_TOKEN مرة واحدة بس. حالة الـ claim نفسها متخزنة في Redis
// دلوقتي - يعني حتى لو السيرفر عمل ريستارت أو ديبلوي جديد، هي بتفضل
// "متبناة" ومحدش تاني يقدر يستولي عليها.
//
// لو فقدت بيانات تطبيق الوالد (مسحت بيانات التطبيق / جهاز جديد)،
// مينفعش تعمل claim تاني عادي - استخدم خيار "أدخل توكن يدويًا" في
// شاشة تطبيق الوالد، والصق فيه نفس الـ ADMIN_TOKEN اللي مطبوع في لوج
// السيرفر عند بدء التشغيل (شوف تحت).
// ------------------------------------------------------------------
app.post("/admin/claim", async (req, res) => {
  const claimed = await redis.get("admin:claimed");
  if (claimed) {
    res.status(403).json({ error: "تم ربط هذا السيرفر بحساب والد بالفعل." });
    return;
  }

  await redis.set("admin:claimed", String(Date.now()));
  res.json({ data: { admin_token: ADMIN_TOKEN } });
});

// مسار استرجاع: لو تطبيق الوالد فقد بيانات الجهاز (claim فاشل) بس
// المستخدم لسه معاه نسخة قديمة من الـ admin_token (مثلاً من لوج
// السيرفر)، يقدر يتحقق منه هنا ويستخدمه تاني من غير ما يحتاج يعمل
// claim جديد أو يمسح أي حاجة.
app.post("/admin/verify", (req, res) => {
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
// حالة لحظية (runtime state) بس - في الذاكرة، وبتتصفر طبيعي مع كل
// إعادة تشغيل، لأنها أصلًا بتمثل اتصالات WebSocket حية مش بيانات دائمة.
// clients: كل اتصال WS مفتوح دلوقتي.
// live[sessionId]: broadcaster المتصل حاليًا (لو موجود) وقائمة الزائرين
// المتصلين حاليًا لنفس الجلسة.
// ------------------------------------------------------------------
const clients = {};
let nextClientId = 1;
const live = {}; // sessionId -> { broadcaster: clientId|null, viewers: Map(clientId -> {name, approved}) }

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

// ------------------------------------------------------------------
// نظام الاقتران (Pairing). الكود القصير نفسه بيتخزن في Redis بـ TTL
// (بينتهي تلقائيًا بعد 5 دقايق من غير ما نحتاج تنضيف يدوي)، وبيتمسح
// فورًا أول ما يُستخدم مرة واحدة (single-use).
// ------------------------------------------------------------------
app.post("/pairing/create", requireAdminToken, async (req, res) => {
  let code = generatePairingCode();
  // تأكيد إن الكود مش مستخدم بالفعل (احتمال ضئيل جدًا لتصادم لكن بسيط
  // نتأكد منه)
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
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();
  const deviceName =
    (req.body && req.body.device_name && String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";

  const raw = await redis.get(`pairing:${code}`);
  if (!raw) {
    res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
    return;
  }

  // single-use: نمسح الكود فورًا عشان محدش يقدر يستخدمه تاني
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
    JSON.stringify({ sessionId, ownerToken, deviceName, pairedAt: Date.now() })
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

// جهاز الطفل يقدر يلغي الاقتران بنفسه في أي وقت من إعداداته
app.post("/pairing/unpair", async (req, res) => {
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

// محمي بتوكن إداري - كل والد يشوف بس أجهزته هو
app.get("/camera/sessions", requireAdminToken, async (req, res) => {
  const requesterToken = req.query.token || req.header("x-admin-token");

  const sessionIds = (await redis.smembers(`owner:${requesterToken}:sessions`)) || [];
  const list = [];

  for (const sessionId of sessionIds) {
    const raw = await redis.get(`session:${sessionId}`);
    if (!raw) continue; // ممكن يكون اتمسح بس الـ set لسه ماتحدثش، تجاهله
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

// حذف/نسيان جهاز من لوحة الوالد
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

wss.on("connection", (ws) => {
  const clientId = String(nextClientId++);
  clients[clientId] = { ws, sessionId: null, role: null };

  ws.isAlive = true;
  ws.on("pong", () => {
    ws.isAlive = true;
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

    if (msg.type === "register") {
      const { role, session } = msg;

      if (role === "broadcaster") {
        const deviceToken = msg.deviceToken;
        const rawDevice = await redis.get(`device:${deviceToken}`);

        if (!rawDevice) {
          send(clientId, { type: "auth-failed", reason: "device_not_paired" });
          return;
        }
        const deviceInfo = typeof rawDevice === "string" ? JSON.parse(rawDevice) : rawDevice;

        const rawSession = await redis.get(`session:${deviceInfo.sessionId}`);
        if (!rawSession) {
          send(clientId, { type: "auth-failed", reason: "device_not_paired" });
          return;
        }

        const boundSession = deviceInfo.sessionId;

        client.sessionId = boundSession;
        client.role = role;
        const liveSession = getLive(boundSession);

        // نحتفظ بالاتصال الحالي كما هو؛ إعادة اتصال جهاز الطفل تتم تلقائيًا
        // من التطبيق، وإغلاق الاتصال السابق هنا قد يسبب حلقة إعادة اتصال.
        liveSession.broadcaster = clientId;
        console.log(`[ws] broadcaster registered: client=${clientId} session=${boundSession} name=${deviceInfo.deviceName}`);

        liveSession.viewers.forEach((info, viewerId) => {
          if (info.approved) {
            send(clientId, { type: "viewer-joined", viewerId, name: info.name });
          } else {
            send(clientId, { type: "join-request", viewerId, name: info.name });
          }
        });
        return;
      }

      if (role === "viewer") {
        const adminToken = msg.adminToken;
        const rawSession = await redis.get(`session:${session}`);
        const targetSession = rawSession ? (typeof rawSession === "string" ? JSON.parse(rawSession) : rawSession) : null;

        if (!targetSession || adminToken !== targetSession.ownerToken) {
          console.log(`[ws] viewer auth-failed: client=${clientId} session=${session} sessionExists=${!!targetSession}`);
          send(clientId, { type: "auth-failed", reason: "not_authorized" });
          return;
        }

        client.sessionId = session;
        client.role = role;
        client.callerName = msg.name || "الوالد";

        const liveSession = getLive(session);
        liveSession.viewers.set(clientId, {
          name: client.callerName,
          approved: true,
        });

        console.log(`[ws] viewer registered: client=${clientId} session=${session} broadcasterOnline=${!!liveSession.broadcaster}`);

        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, { type: "viewer-joined", viewerId: clientId, name: client.callerName });
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
            send(liveSession.broadcaster, { type: "viewer-left", viewerId: clientId });
          }
        } else if (client.role === "broadcaster" && liveSession.broadcaster === clientId) {
          liveSession.broadcaster = null;
          // قطع كل زوار الجلسة الحالية لأن مصدر البث خرج فعليًا.
          for (const [viewerId] of liveSession.viewers) {
            send(viewerId, { type: "broadcaster-left" });
          }
          liveSession.viewers.clear();
        }

        if (!liveSession.broadcaster && liveSession.viewers.size === 0) {
          delete live[sessionId];
        }
      }

      // بعد leave لا نحتاج أي إعادة استخدام لهذا العميل. الإغلاق الفعلي
      // سيأتي مباشرة من التطبيق، لكن نحمي السيرفر أيضًا من أي رسائل لاحقة.
      client.sessionId = null;
      client.role = null;
      try { client.ws.close(1000, "left"); } catch (_) {}
      return;
    }

    if (msg.type === "approve-viewer") {
      const liveSession = live[client.sessionId];
      if (client.role !== "broadcaster" || !liveSession || liveSession.broadcaster !== clientId) return;

      const viewerInfo = liveSession.viewers.get(msg.target);
      if (!viewerInfo) return;

      viewerInfo.approved = true;
      return;
    }

    if (msg.type === "reject-viewer") {
      const liveSession = live[client.sessionId];
      if (client.role !== "broadcaster" || !liveSession || liveSession.broadcaster !== clientId) return;

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
      if (client.role !== "broadcaster" || !liveSession || liveSession.broadcaster !== clientId) {
        console.log(`[ws] offer REJECTED: client=${clientId} role=${client.role} hasSession=${!!liveSession}`);
        return;
      }

      const viewerInfo = liveSession.viewers.get(msg.viewerId);
      if (!viewerInfo) {
        console.log(`[ws] offer DROPPED - viewer not found: viewerId=${msg.viewerId} knownViewers=${[...liveSession.viewers.keys()]}`);
        return;
      }

      console.log(`[ws] offer forwarded: from=${clientId} to=${msg.viewerId}`);
      send(msg.viewerId, { type: "offer", sdp: msg.sdp, from: clientId });
      return;
    }

    if (msg.type === "answer") {
      const liveSession = live[client.sessionId];
      if (liveSession && liveSession.broadcaster) {
        console.log(`[ws] answer forwarded: from=${clientId} to=${liveSession.broadcaster}`);
        send(liveSession.broadcaster, { type: "answer", sdp: msg.sdp, viewerId: clientId });
      } else {
        console.log(`[ws] answer DROPPED - no broadcaster: client=${clientId} session=${client.sessionId}`);
      }
      return;
    }

    if (msg.type === "ice") {
      send(msg.target, { type: "ice", candidate: msg.candidate, from: clientId });
      return;
    }

    if (msg.type === "switch-camera") {
      // تشخيص مؤقت: نتأكد الرسالة وصلت للسيرفر ونعرف هل فيه عميل
      // فعلاً بالـ target ده متصل دلوقتي ولا لأ (لو مفيش، send() هتتجاهله بصمت).
      const targetExists = !!clients[msg.target];
      console.log(
        `[ws] switch-camera: from=${clientId} target=${msg.target} targetConnected=${targetExists}`
      );
      send(msg.target, { type: "switch-camera" });
      return;
    }

    if (msg.type === "toggle-mic") {
      send(msg.target, { type: "toggle-mic" });
      return;
    }

    if (msg.type === "kick") {
      const liveSession = live[client.sessionId];
      if (client.role === "broadcaster" && liveSession && liveSession.broadcaster === clientId) {
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

      if (client.role === "broadcaster" && liveSession.broadcaster === clientId) {
        liveSession.broadcaster = null;
        for (const [viewerId] of liveSession.viewers) {
          send(viewerId, { type: "broadcaster-left" });
        }
        liveSession.viewers.clear();
      }
      if (client.role === "viewer") {
        liveSession.viewers.delete(clientId);

        if (liveSession.broadcaster) {
          send(liveSession.broadcaster, { type: "viewer-left", viewerId: clientId });
        }
      }

      if (!liveSession.broadcaster && liveSession.viewers.size === 0) {
        delete live[client.sessionId];
      }
    }
    delete clients[clientId];
  });
});

const heartbeatInterval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) {
      return ws.terminate();
    }
    ws.isAlive = false;
    try {
      ws.ping();
    } catch (_) {}
  });
}, 15000);

wss.on("close", () => clearInterval(heartbeatInterval));

// ------------------------------------------------------------------
// سيرفرات ICE (STUN/TURN) - قابلة للتهيئة عن طريق متغيرات البيئة.
// TURN_URLS / TURN_USERNAME / TURN_CREDENTIAL
// ------------------------------------------------------------------
let _warnedNoPrivateTurn = false;

function getIceServers() {
  const stun = { urls: "stun:stun.l.google.com:19302" };

  const turnUrls = (process.env.TURN_URLS || "").trim();

  if (turnUrls) {
    const username = process.env.TURN_USERNAME || "";
    const credential = process.env.TURN_CREDENTIAL || "";

    const urls = turnUrls
      .split(",")
      .map((u) => u.trim())
      .filter(Boolean);

    return [stun, ...urls.map((urls_) => ({ urls: urls_, username, credential }))];
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

  return [
    stun,
    { urls: "turn:openrelay.metered.ca:80", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443", username: "openrelayproject", credential: "openrelayproject" },
    { urls: "turn:openrelay.metered.ca:443?transport=tcp", username: "openrelayproject", credential: "openrelayproject" },
  ];
}

app.get("/ice-servers", (req, res) => {
  res.json({ data: getIceServers() });
});

app.get("/camera/view", (req, res) => {
  res.status(410).send("تم إيقاف هذا المسار. المشاهدة الآن تتم فقط من لوحة الوالد بعد تسجيل الدخول.");
});

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
              ws.send(JSON.stringify({ type: "register", role: "viewer", session: sessionId, adminToken: dashboardToken }));
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
// بدء التشغيل: لازم نجيب/نولّد ADMIN_TOKEN من Redis الأول قبل ما
// نفتح أي اتصال، عشان requireAdminToken وباقي المسارات تلاقيه جاهز.
// بيتطبع في اللوج دايمًا (مش بس أول مرة) عشان لو فقدت بيانات تطبيق
// الوالد، تقدر تيجي هنا وتاخده وتحطه يدويًا من شاشة "استرجاع الاقتران"
// في التطبيق.
// ------------------------------------------------------------------
(async () => {
  ADMIN_TOKEN = await getOrCreateAdminToken();
  console.log(`[camera-parent] ADMIN_TOKEN الحالي: ${ADMIN_TOKEN}`);
  console.log(
    "[camera-parent] احتفظ بالقيمة دي في مكان آمن - لو فقدت بيانات تطبيق " +
      "الوالد تقدر تستخدمها من خيار \"استرجاع الاقتران\" في التطبيق."
  );

  server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
  });
})();
