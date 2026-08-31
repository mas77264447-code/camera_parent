require("dotenv").config();
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/signal" });

app.use(express.json());

app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.header("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token");
  next();
});

// ------------------------------------------------------------------
// توكن إداري (Admin Token) بيتولد مرة واحدة ويتخزن في ملف محلي، أو
// يتقرأ من متغير بيئة ADMIN_TOKEN لو معمول له set يدويًا (الأفضل في
// الإنتاج عشان يفضل ثابت حتى لو السيرفر اتعمله إعادة نشر/deploy).
// الرابط بتاع /dashboard اللي بيترجع من /camera/create بيحمل التوكن
// ده جواه، فمحدش يقدر يشوف قائمة الكاميرات غير اللي معاه الرابط ده.
// ------------------------------------------------------------------
const TOKEN_FILE = path.join(__dirname, ".admin_token");

function loadOrCreateAdminToken() {
  if (process.env.ADMIN_TOKEN) return process.env.ADMIN_TOKEN;

  try {
    if (fs.existsSync(TOKEN_FILE)) {
      const existing = fs.readFileSync(TOKEN_FILE, "utf8").trim();
      if (existing) return existing;
    }
  } catch (_) {}

  const generated = crypto.randomBytes(24).toString("hex");

  try {
    fs.writeFileSync(TOKEN_FILE, generated, "utf8");
  } catch (_) {
    // لو مش قادر يكتب على الملف (بعض بيئات الاستضافة بتكون read-only)،
    // التوكن هيفضل شغال للجلسة الحالية بس هيتغير لو السيرفر عمل ريستارت.
    // الأفضل في الحالة دي إنك تعمل set لمتغير بيئة ADMIN_TOKEN يدويًا.
  }

  console.warn(
    "[camera-parent] تم توليد ADMIN_TOKEN جديد تلقائيًا. " +
      "للحفاظ عليه ثابت بين عمليات إعادة النشر، اعمل set لمتغير بيئة " +
      "ADMIN_TOKEN بنفس القيمة دي: " +
      generated
  );

  return generated;
}

const ADMIN_TOKEN = loadOrCreateAdminToken();

// ------------------------------------------------------------------
// أول تطبيق والد يفتح السيرفر ده هو اللي "يتبنى" (claim) الـ
// ADMIN_TOKEN مرة واحدة بس - بعدها التوكن يتخزن محليًا على جهازه
// وميتكررش تسريبه تاني عبر أي endpoint. ده بديل عن كشف التوكن جوه
// رابط قابل للمشاركة زي التصميم القديم.
// ------------------------------------------------------------------
const CLAIM_FILE = path.join(__dirname, ".admin_claimed");

app.post("/admin/claim", (req, res) => {
  if (fs.existsSync(CLAIM_FILE)) {
    res.status(403).json({ error: "تم ربط هذا السيرفر بحساب والد بالفعل." });
    return;
  }

  try {
    fs.writeFileSync(CLAIM_FILE, String(Date.now()), "utf8");
  } catch (_) {}

  res.json({ data: { admin_token: ADMIN_TOKEN } });
});

function requireAdminToken(req, res, next) {
  const provided = req.query.token || req.header("x-admin-token");

  if (provided && provided === ADMIN_TOKEN) {
    return next();
  }

  res.status(403).send("غير مصرح لك بالدخول هنا.");
}

const sessions = {};
const clients = {};
let nextClientId = 1;

// ------------------------------------------------------------------
// نظام الاقتران (Pairing) - بيحل محل فكرة "رابط عام أي حد يفتحه".
// بدل ما نولّد رابط قابل للمشاركة، الوالد يولّد كود قصير الصلاحية من
// تطبيقه (بعد ما يثبت هويته بالـ ADMIN_TOKEN بتاعه)، وجهاز الطفل هو
// اللي يدخل الكود ده يدويًا مرة واحدة بس. بعد الاقتران، جهاز الطفل
// ياخد device_token دائم مربوط بحساب الوالد ده تحديدًا - مفيش حد تاني
// يقدر يستخدمه حتى لو عرف الكود القديم (بينتهي خلال 5 دقايق وبيتلغى
// أول ما يُستخدم مرة واحدة).
// ------------------------------------------------------------------
const PAIRING_CODE_TTL_MS = 5 * 60 * 1000;
const pairingCodes = {}; // code -> { ownerToken, expiresAt, used }
const deviceTokens = {}; // deviceToken -> { sessionId, ownerToken, deviceName, pairedAt }

function generatePairingCode() {
  // كود من 6 أرقام - سهل يتكتب يدويًا على جهاز تاني
  let code;
  do {
    code = String(Math.floor(100000 + Math.random() * 900000));
  } while (pairingCodes[code] && pairingCodes[code].expiresAt > Date.now());
  return code;
}

function send(clientId, data) {
  const c = clients[clientId];
  if (c && c.ws.readyState === 1) {
    c.ws.send(JSON.stringify(data));
  }
}

// ------------------------------------------------------------------
// خطوة 1 من الاقتران: الوالد (لازم يثبت هويته بالـ ADMIN_TOKEN) يطلب
// كود جديد. الكود ده بيتعرض بتطبيق الوالد بس - مفيش رابط يتبعت لحد.
// ------------------------------------------------------------------
app.post("/pairing/create", requireAdminToken, (req, res) => {
  const code = generatePairingCode();

  pairingCodes[code] = {
    ownerToken: ADMIN_TOKEN,
    expiresAt: Date.now() + PAIRING_CODE_TTL_MS,
    used: false,
  };

  res.json({
    data: {
      code,
      expires_in_seconds: PAIRING_CODE_TTL_MS / 1000,
    },
  });
});

// ------------------------------------------------------------------
// خطوة 2 من الاقتران: جهاز الطفل يدخل الكود يدويًا (مرة واحدة بس، على
// نفس الجهاز). لو الكود صحيح وسليم، السيرفر يطلع جلسة جديدة ويربطها
// بحساب الوالد صاحب الكود، ويرجّع device_token دائم لجهاز الطفل. مفيش
// أي رابط قابل للمشاركة في الخطوة دي.
// ------------------------------------------------------------------
app.post("/pairing/claim", (req, res) => {
  const code = (req.body && req.body.code ? String(req.body.code) : "").trim();
  const deviceName =
    (req.body && req.body.device_name && String(req.body.device_name).trim()) ||
    "جهاز غير مسمى";

  const entry = pairingCodes[code];

  if (!entry || entry.used || entry.expiresAt < Date.now()) {
    res.status(400).json({ error: "الكود غير صحيح أو منتهي الصلاحية." });
    return;
  }

  entry.used = true;

  const sessionId = crypto.randomBytes(16).toString("hex");
  const deviceToken = crypto.randomBytes(24).toString("hex");

  sessions[sessionId] = {
    name: deviceName,
    createdAt: Date.now(),
    ownerToken: entry.ownerToken,
    broadcaster: null,
    viewers: new Map(),
  };

  deviceTokens[deviceToken] = {
    sessionId,
    ownerToken: entry.ownerToken,
    deviceName,
    pairedAt: Date.now(),
  };

  res.json({
    data: {
      device_token: deviceToken,
      session_id: sessionId,
      device_name: deviceName,
    },
  });
});

// جهاز الطفل يقدر يلغي الاقتران بنفسه في أي وقت من إعدادات التطبيق
// عنده - مش لازم يمر بالوالد.
app.post("/pairing/unpair", (req, res) => {
  const deviceToken = req.header("x-device-token") || "";
  const info = deviceTokens[deviceToken];

  if (!info) {
    res.status(404).json({ error: "الجهاز غير مقترن." });
    return;
  }

  delete sessions[info.sessionId];
  delete deviceTokens[deviceToken];
  res.json({ data: { unpaired: true } });
});

// محمي بتوكن إداري - من غيره أي حد يعرف رابط السيرفر كان يقدر يشوف
// قائمة كل الكاميرات المتصلة بيه، حتى لو مش بتاعته.
app.get("/camera/sessions", requireAdminToken, (req, res) => {
  const requesterToken = req.query.token || req.header("x-admin-token");

  // كل والد يشوف بس الأجهزة المقترنة بحسابه هو، مش كل الجلسات على
  // السيرفر - حتى لو كان يعرف الـ ADMIN_TOKEN بتاعه (وهو أصلًا شرط
  // requireAdminToken فوق).
  const list = Object.keys(sessions)
    .filter((id) => sessions[id].ownerToken === requesterToken)
    .map((id) => {
      const s = sessions[id];
      return {
        session_id: id,
        name: s.name,
        online: !!s.broadcaster,
        viewers: s.viewers.size,
        created_at: s.createdAt,
      };
    });

  list.sort((a, b) => b.created_at - a.created_at);
  res.json({ data: list });
});

// حذف/نسيان جهاز من لوحة الوالد - يفيد خصوصًا للأجهزة اللي اتقرنت
// أكتر من مرة (زي إعادة اقتران بعد تجربة) وفضلت باقية في القائمة
// بحالة "غير متصل" من غير داعي.
app.delete("/camera/sessions/:id", requireAdminToken, (req, res) => {
  const requesterToken = req.query.token || req.header("x-admin-token");
  const session = sessions[req.params.id];

  if (!session || session.ownerToken !== requesterToken) {
    res.status(404).json({ error: "الجهاز غير موجود." });
    return;
  }

  // لو الجهاز متصل دلوقتي، نقطع اتصاله الأول
  if (session.broadcaster) {
    const bClient = clients[session.broadcaster];
    if (bClient) {
      try {
        bClient.ws.close();
      } catch (e) {}
    }
  }

  // نلاقي ونمسح device_token المرتبط بنفس الجلسة عشان الجهاز يحتاج
  // اقتران جديد لو حاول يتصل تاني
  Object.keys(deviceTokens).forEach((token) => {
    if (deviceTokens[token].sessionId === req.params.id) {
      delete deviceTokens[token];
    }
  });

  delete sessions[req.params.id];
  res.json({ data: { deleted: true } });
});

wss.on("connection", (ws) => {
  const clientId = String(nextClientId++);
  clients[clientId] = { ws, sessionId: null, role: null };

  // heartbeat: لو الجهاز فقد النت فجأة (مش خروج نظيف)، من غير ده ممكن
  // TCP ياخد وقت طويل جدًا (أو أبدًا) عشان يكتشف إن الاتصال مات
  ws.isAlive = true;
  ws.on("pong", () => {
    ws.isAlive = true;
  });

  ws.on("message", (raw) => {
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
        // لازم device_token صالح وسبق اقترانه - مفيش تسجيل بث لجلسة
        // باسم حر بيختاره أي حد زي ما كان قبل كده.
        const deviceToken = msg.deviceToken;
        const deviceInfo = deviceTokens[deviceToken];

        if (!deviceInfo || !sessions[deviceInfo.sessionId]) {
          send(clientId, { type: "auth-failed", reason: "device_not_paired" });
          return;
        }

        const boundSession = deviceInfo.sessionId;

        client.sessionId = boundSession;
        client.role = role;
        sessions[boundSession].broadcaster = clientId;
        console.log(`[ws] broadcaster registered: client=${clientId} session=${boundSession} name=${deviceInfo.deviceName}`);

        // لو فيه زائرين كانوا متصلين قبل ما البث يرجع (مثلاً بعد ريستارت
        // التطبيق)، نبعتلهم تاني حسب حالتهم: اللي اتوافق عليهم قبل كده
        // نديله "viewer-joined" عادي (زي ما كان)، واللي لسه معلقين نديله
        // "join-request" تاني عشان صاحب الكاميرا ياخد قراره.
        sessions[boundSession].viewers.forEach((info, viewerId) => {
          if (info.approved) {
            send(clientId, { type: "viewer-joined", viewerId, name: info.name });
          } else {
            send(clientId, { type: "join-request", viewerId, name: info.name });
          }
        });
        return;
      }

      if (role === "viewer") {
        // الزائر (لوحة الوالد) لازم يثبت ADMIN_TOKEN بتاعه، ونتأكد إن
        // الجلسة المطلوبة فعلاً مملوكة لنفس الوالد ده - مفيش "أي حد
        // معاه الرابط" زي قبل كده، لأنه مفيش رابط أصلًا.
        const adminToken = msg.adminToken;
        const targetSession = sessions[session];

        if (!targetSession || adminToken !== targetSession.ownerToken) {
          console.log(`[ws] viewer auth-failed: client=${clientId} session=${session} sessionExists=${!!targetSession}`);
          send(clientId, { type: "auth-failed", reason: "not_authorized" });
          return;
        }

        client.sessionId = session;
        client.role = role;
        client.callerName = msg.name || "الوالد";

        targetSession.viewers.set(clientId, {
          name: client.callerName,
          approved: true,
        });

        console.log(`[ws] viewer registered: client=${clientId} session=${session} broadcasterOnline=${!!targetSession.broadcaster}`);

        const bId = targetSession.broadcaster;
        if (bId) {
          send(bId, { type: "viewer-joined", viewerId: clientId, name: client.callerName });
        }
        return;
      }
      return;
    }

    if (msg.type === "approve-viewer") {
      // بس صاحب البث (broadcaster) بتاع نفس الجلسة يقدر يوافق على زائر
      const session = sessions[client.sessionId];
      if (client.role !== "broadcaster" || !session || session.broadcaster !== clientId) return;

      const viewerInfo = session.viewers.get(msg.target);
      if (!viewerInfo) return;

      viewerInfo.approved = true;
      return;
    }

    if (msg.type === "reject-viewer") {
      // بس صاحب البث بتاع نفس الجلسة يقدر يرفض زائر
      const session = sessions[client.sessionId];
      if (client.role !== "broadcaster" || !session || session.broadcaster !== clientId) return;

      session.viewers.delete(msg.target);
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
      // نتأكد إن اللي باعت الـ offer هو فعلاً صاحب البث بتاع نفس الجلسة،
      // وإن الزائر المستهدف متوافق عليه - عشان محدش يقدر يبعت بث لزائر
      // من غير موافقة حتى لو عدل على التطبيق بنفسه.
      const session = sessions[client.sessionId];
      if (client.role !== "broadcaster" || !session || session.broadcaster !== clientId) {
        console.log(`[ws] offer REJECTED: client=${clientId} role=${client.role} hasSession=${!!session}`);
        return;
      }

      const viewerInfo = session.viewers.get(msg.viewerId);
      if (!viewerInfo) {
        console.log(`[ws] offer DROPPED - viewer not found: viewerId=${msg.viewerId} knownViewers=${[...session.viewers.keys()]}`);
        return;
      }

      console.log(`[ws] offer forwarded: from=${clientId} to=${msg.viewerId}`);
      send(msg.viewerId, { type: "offer", sdp: msg.sdp, from: clientId });
      return;
    }

    if (msg.type === "answer") {
      const session = sessions[client.sessionId];
      if (session && session.broadcaster) {
        console.log(`[ws] answer forwarded: from=${clientId} to=${session.broadcaster}`);
        send(session.broadcaster, { type: "answer", sdp: msg.sdp, viewerId: clientId });
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
      send(msg.target, { type: "switch-camera" });
      return;
    }

    if (msg.type === "toggle-mic") {
      send(msg.target, { type: "toggle-mic" });
      return;
    }

    if (msg.type === "kick") {
      // بس البث اللي مسجل كـ broadcaster في نفس الجلسة يقدر يقطع اتصال زائر
      const session = sessions[client.sessionId];
      if (client.role === "broadcaster" && session && session.broadcaster === clientId) {
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
    if (client && client.sessionId && sessions[client.sessionId]) {
      const session = sessions[client.sessionId];

      if (client.role === "broadcaster" && session.broadcaster === clientId) {
        session.broadcaster = null;
      }
      if (client.role === "viewer") {
        session.viewers.delete(clientId);

        if (session.broadcaster) {
          send(session.broadcaster, { type: "viewer-left", viewerId: clientId });
        }
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
// سيرفرات ICE (STUN/TURN) - قابلة للتهيئة عن طريق متغيرات البيئة عشان
// يبقى ممكن تستخدم سيرفر TURN خاص بيك (مثلاً coturn على سيرفر بتاعك،
// أو خدمة زي Twilio/Xirsys) بدل الاعتماد بشكل دائم على سيرفر مجاني
// عام (openrelay.metered.ca) بيانات الدخول بتاعته معروفة للعامة
// ومحدود السعة. لو TURN_URLS متظبطش، بيرجع تلقائيًا لنفس السيرفر
// المجاني القديم عشان التطبيق يفضل شغال من غير إعداد إضافي.
//
// لتفعيل TURN خاص، اظبط متغيرات البيئة دي على السيرفر:
//   TURN_URLS       رابط أو أكتر مفصولين بفاصلة، مثال:
//                    "turn:my.turn.server:3478,turn:my.turn.server:443?transport=tcp"
//   TURN_USERNAME    اسم المستخدم بتاع سيرفر الـ TURN
//   TURN_CREDENTIAL  كلمة السر/التوكن بتاع سيرفر الـ TURN
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

// بيستخدمه تطبيق الموبايل (broadcaster والـ viewer) عشان ميحتاجش يعمل
// hardcode لسيرفرات الـ ICE جوه الكود - بيجيبها من هنا بدل كده.
app.get("/ice-servers", (req, res) => {
  res.json({ data: getIceServers() });
});

// ملحوظة: صفحة /camera/view القديمة (مشاهدة أي جلسة عبر رابط عام
// يفتحه أي حد) اتشالت بالكامل. المشاهدة الوحيدة المسموحة دلوقتي هي
// عبر /dashboard اللي محمي بـ ADMIN_TOKEN بتاع الوالد صاحب الجهاز.
app.get("/camera/view", (req, res) => {
  res.status(410).send("تم إيقاف هذا المسار. المشاهدة الآن تتم فقط من لوحة الوالد بعد تسجيل الدخول.");
});

// محمي بتوكن إداري - بس صاحب الـ ADMIN_TOKEN (الوالد) يقدر يفتح
// اللوحة، ومحدود على الأجهزة المقترنة بيه هو بس (شوف الفلترة فوق في
// /camera/sessions).
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
          // بيتجابوا فعليًا من /ice-servers قبل أول اتصال؛ القيمة دي مجرد
          // احتياط لو الطلب فشل لأي سبب.
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
            } catch (e) {
              // لو الطلب فشل، هيفضل يستخدم القيمة الاحتياطية (STUN بس)
            }
          }

          loadIceServers();

          // التوكن اتحفظ فوق في متغير الجافاسكريبت؛ دلوقتي نمسحه من شريط
          // العنوان عشان ميفضلش ظاهر في الـ history أو لو حد شاف سكرين شوت
          // للشاشة. الطلب الأول لفتح /dashboard هو المرة الوحيدة اللي
          // التوكن بيتبعت فيها كـ query param؛ أي طلبات تانية (زي
          // loadSessions تحت) بتبعته كـ header بدل الرابط.
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
server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
