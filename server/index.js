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

app.post("/camera/create", (req, res) => {
  const sessionId = Date.now().toString();
  const baseUrl = `${req.protocol}://${req.get("host")}`;
  const childUrl = `${baseUrl}/camera/view?session=${sessionId}`;

  sessions[sessionId] = { frame: null, updatedAt: null };

  res.json({
    data: {
      child_url: childUrl,
      session_id: sessionId,
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

app.get("/", (req, res) => {
  res.send("Camera Parent server is running.");
});

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
