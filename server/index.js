const express = require("express");
const app = express();

app.use(express.json());
app.use(express.raw({ type: "image/jpeg", limit: "5mb" }));

app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.header("Access-Control-Allow-Headers", "Content-Type");
  next();
});

const sessions = {};
const ONLINE_TIMEOUT_MS = 8000;

app.post("/camera/create", (req, res) => {
  const sessionId = Date.now().toString();
  const baseUrl = `${req.protocol}://${req.get("host")}`;
  const childUrl = `${baseUrl}/camera/view?session=${sessionId}`;

  const name =
    (req.body && req.body.name && String(req.body.name).trim()) ||
    `كاميرا ${Object.keys(sessions).length + 1}`;

  sessions[sessionId] = {
    name,
    frame: null,
    createdAt: Date.now(),
    updatedAt: null,
  };

  res.json({
    data: {
      child_url: childUrl,
      session_id: sessionId,
      dashboard_url: `${baseUrl}/dashboard`,
    },
  });
});

app.post("/camera/frame", (req, res) => {
  const sessionId = req.query.session;

  if (!sessionId || !sessions[sessionId]) {
    return res.status(404).send("Unknown session");
  }

  sessions[sessionId].frame = req.body;
  sessions[sessionId].updatedAt = Date.now();

  res.sendStatus(200);
});

app.get("/camera/frame", (req, res) => {
  const sessionId = req.query.session;
  const session = sessions[sessionId];

  if (!session || !session.frame) {
    return res.status(404).send("No frame yet");
  }

  res.set("Content-Type", "image/jpeg");
  res.set("Cache-Control", "no-store");
  res.send(session.frame);
});

app.get("/camera/sessions", (req, res) => {
  const list = Object.keys(sessions).map((id) => {
    const s = sessions[id];
    const online = !!s.updatedAt && Date.now() - s.updatedAt < ONLINE_TIMEOUT_MS;

    return {
      session_id: id,
      name: s.name,
      online,
      created_at: s.createdAt,
      updated_at: s.updatedAt,
    };
  });

  list.sort((a, b) => b.created_at - a.created_at);

  res.json({ data: list });
});

app.get("/camera/view", (req, res) => {
  const session = req.query.session || "";

  res.send(`
    <html>
      <head>
        <meta charset="utf-8">
        <title>Camera - Child</title>
        <style>
          body { margin:0; background:#111; display:flex; flex-direction:column; align-items:center; justify-content:center; height:100vh; font-family: sans-serif; }
          img { max-width:100%; max-height:85vh; border-radius:8px; }
          p { color:#ccc; }
        </style>
      </head>
      <body>
        <img id="cam" src="/camera/frame?session=${session}&t=0" />
        <p>البث المباشر</p>
        <script>
          const img = document.getElementById('cam');
          setInterval(() => {
            img.src = '/camera/frame?session=${session}&t=' + Date.now();
          }, 1500);
        </script>
      </body>
    </html>
  `);
});

app.get("/dashboard", (req, res) => {
  res.send(`
    <html>
      <head>
        <meta charset="utf-8">
        <title>لوحة الكاميرات</title>
        <style>
          * { box-sizing: border-box; }
          body {
            margin:0;
            font-family: sans-serif;
            background:#0d0d0d;
            color:#eee;
            display:flex;
            height:100vh;
            direction: rtl;
          }
          #sidebar {
            width: 260px;
            background:#161616;
            overflow-y:auto;
            border-left: 1px solid #2a2a2a;
            flex-shrink:0;
          }
          #sidebar h2 {
            padding:16px;
            margin:0;
            font-size:16px;
            border-bottom:1px solid #2a2a2a;
          }
          .cam-item {
            padding:14px 16px;
            cursor:pointer;
            border-bottom:1px solid #222;
            display:flex;
            align-items:center;
            justify-content:space-between;
          }
          .cam-item:hover { background:#222; }
          .cam-item.active { background:#3a2a5c; }
          .dot {
            width:10px; height:10px; border-radius:50%;
            display:inline-block; margin-left:8px;
          }
          .online { background:#2ecc71; }
          .offline { background:#666; }
          #main {
            flex:1;
            display:flex;
            flex-direction:column;
            align-items:center;
            justify-content:center;
            position:relative;
          }
          #main img {
            max-width:100%;
            max-height:100vh;
          }
          #placeholder {
            color:#666;
            font-size:18px;
          }
          #camTitle {
            position:absolute;
            top:12px;
            right:16px;
            background:rgba(0,0,0,0.5);
            padding:6px 14px;
            border-radius:20px;
            font-size:14px;
          }
        </style>
      </head>
      <body>
        <div id="sidebar">
          <h2>الكاميرات المتصلة</h2>
          <div id="camList"></div>
        </div>
        <div id="main">
          <div id="camTitle" style="display:none;"></div>
          <img id="camView" style="display:none;" />
          <div id="placeholder">اختار كاميرا من القائمة للمشاهدة</div>
        </div>

        <script>
          let currentSession = null;

          async function loadSessions() {
            try {
              const res = await fetch('/camera/sessions');
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

          function selectCamera(sessionId, name) {
            currentSession = sessionId;

            document.getElementById('placeholder').style.display = 'none';
            document.getElementById('camView').style.display = 'block';
            document.getElementById('camTitle').style.display = 'block';
            document.getElementById('camTitle').innerText = name;

            refreshImage();
            loadSessions();
          }

          function refreshImage() {
            if (!currentSession) return;
            document.getElementById('camView').src =
              '/camera/frame?session=' + currentSession + '&t=' + Date.now();
          }

          setInterval(loadSessions, 3000);
          setInterval(refreshImage, 1500);

          loadSessions();
        </script>
      </body>
    </html>
  `);
});

app.get("/", (req, res) => {
  res.send("Camera Parent server is running.");
});

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
