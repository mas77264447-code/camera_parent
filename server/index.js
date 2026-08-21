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
  res.header("Access-Control-Allow-Headers", "Content-Type");
  next();
});

const sessions = {};
const clients = {};
let nextClientId = 1;

function send(clientId, data) {
  const c = clients[clientId];
  if (c && c.ws.readyState === 1) {
    c.ws.send(JSON.stringify(data));
  }
}

app.post("/camera/create", (req, res) => {
  const sessionId = Date.now().toString();
  const baseUrl = `${req.protocol}://${req.get("host")}`;
  const wsProtocol = req.protocol === "https" ? "wss" : "ws";

  const name =
    (req.body && req.body.name && String(req.body.name).trim()) ||
    `كاميرا ${Object.keys(sessions).length + 1}`;

  sessions[sessionId] = {
    name,
    createdAt: Date.now(),
    broadcaster: null,
    viewers: new Set(),
  };

  res.json({
    data: {
      child_url: `${baseUrl}/camera/view?session=${sessionId}`,
      session_id: sessionId,
      dashboard_url: `${baseUrl}/dashboard`,
      signal_url: `${wsProtocol}://${req.get("host")}/signal`,
    },
  });
});

app.get("/camera/sessions", (req, res) => {
  const list = Object.keys(sessions).map((id) => {
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

wss.on("connection", (ws) => {
  const clientId = String(nextClientId++);
  clients[clientId] = { ws, sessionId: null, role: null };

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
        if (!sessions[session]) {
          sessions[session] = {
            name: msg.name || `كاميرا ${Object.keys(sessions).length + 1}`,
            createdAt: Date.now(),
            broadcaster: null,
            viewers: new Set(),
          };
        }

        client.sessionId = session;
        client.role = role;
        sessions[session].broadcaster = clientId;

        sessions[session].viewers.forEach((viewerId) => {
          send(clientId, { type: "viewer-joined", viewerId });
        });
        return;
      }

      if (role === "viewer") {
        if (!sessions[session]) return;

        client.sessionId = session;
        client.role = role;
        sessions[session].viewers.add(clientId);

        const bId = sessions[session].broadcaster;
        if (bId) {
          send(bId, { type: "viewer-joined", viewerId: clientId });
        }
        return;
      }
      return;
    }

    if (msg.type === "offer") {
      send(msg.viewerId, { type: "offer", sdp: msg.sdp, from: clientId });
      return;
    }

    if (msg.type === "answer") {
      const session = sessions[client.sessionId];
      if (session && session.broadcaster) {
        send(session.broadcaster, { type: "answer", sdp: msg.sdp, viewerId: clientId });
      }
      return;
    }

    if (msg.type === "ice") {
      send(msg.target, { type: "ice", candidate: msg.candidate, from: clientId });
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
      }
    }
    delete clients[clientId];
  });
});

const ICE_SERVERS_JS = `[
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "turn:openrelay.metered.ca:80", username: "openrelayproject", credential: "openrelayproject" },
  { urls: "turn:openrelay.metered.ca:443", username: "openrelayproject", credential: "openrelayproject" },
  { urls: "turn:openrelay.metered.ca:443?transport=tcp", username: "openrelayproject", credential: "openrelayproject" }
]`;

app.get("/camera/view", (req, res) => {
  const sessionId = req.query.session || "";

  res.send(`
    <html>
      <head>
        <meta charset="utf-8">
        <title>Camera - Child</title>
        <style>
          body { margin:0; background:#111; display:flex; flex-direction:column; align-items:center; justify-content:center; height:100vh; font-family: sans-serif; }
          video { max-width:100%; max-height:85vh; border-radius:8px; background:#000; }
          p { color:#ccc; }
        </style>
      </head>
      <body>
        <div style="position:relative;">
          <video id="remoteVideo" autoplay playsinline muted></video>
          <video id="localVideo" autoplay playsinline muted style="position:absolute; bottom:10px; left:10px; width:110px; border-radius:8px; border:2px solid #fff; background:#000;"></video>
        </div>
        <button id="unmuteBtn" style="display:none; margin-top:12px; padding:10px 20px; border-radius:20px; border:none; background:#6c3fc5; color:#fff; font-size:14px;">تشغيل الصوت 🔊</button>
        <p id="status">جاري الاتصال...</p>
        <script>
          const sessionId = "${sessionId}";
          const wsProto = location.protocol === "https:" ? "wss" : "ws";
          const ws = new WebSocket(wsProto + "://" + location.host + "/signal");
          const iceServers = ${ICE_SERVERS_JS};
          let pc = null;
          let broadcasterId = null;

          ws.onopen = () => {
            ws.send(JSON.stringify({ type: "register", role: "viewer", session: sessionId }));
          };

          ws.onmessage = async (event) => {
            const msg = JSON.parse(event.data);

            if (msg.type === "offer") {
              broadcasterId = msg.from;
              pc = new RTCPeerConnection({ iceServers });

              pc.ontrack = (e) => {
                const video = document.getElementById("remoteVideo");
                video.srcObject = e.streams[0];
                video.play().catch(() => {});
                document.getElementById("status").innerText = "متصل";
                document.getElementById("unmuteBtn").style.display = "inline-block";
              };

              pc.onicecandidate = (e) => {
                if (e.candidate) {
                  ws.send(JSON.stringify({ type: "ice", candidate: e.candidate, target: broadcasterId }));
                }
              };

              try {
                const localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
                document.getElementById("localVideo").srcObject = localStream;
                localStream.getTracks().forEach(track => pc.addTrack(track, localStream));
              } catch (e) {
                document.getElementById("localVideo").style.display = "none";
              }

              await pc.setRemoteDescription(new RTCSessionDescription(msg.sdp));
              const answer = await pc.createAnswer();
              await pc.setLocalDescription(answer);

              ws.send(JSON.stringify({ type: "answer", sdp: answer }));
            }

            if (msg.type === "ice" && pc) {
              try { await pc.addIceCandidate(msg.candidate); } catch (e) {}
            }
          };

          ws.onclose = () => {
            document.getElementById("status").innerText = "انقطع الاتصال";
          };

          document.getElementById("unmuteBtn").addEventListener("click", () => {
            const video = document.getElementById("remoteVideo");
            video.muted = false;
            video.play().catch(() => {});
          });
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
          const iceServers = ${ICE_SERVERS_JS};
          let currentSession = null;
          let ws = null;
          let pc = null;
          let broadcasterId = null;

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
              ws.send(JSON.stringify({ type: "register", role: "viewer", session: sessionId }));
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
            };

            loadSessions();
          }

          setInterval(loadSessions, 3000);
          loadSessions();

          document.getElementById("unmuteBtn2").addEventListener("click", () => {
            const video = document.getElementById("camView");
            video.muted = false;
            video.play().catch(() => {});
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
