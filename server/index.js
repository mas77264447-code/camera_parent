const express = require("express");
const app = express();

app.use(express.json());

app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.header("Access-Control-Allow-Headers", "Content-Type");
  next();
});

app.post("/camera/create", (req, res) => {
  const sessionId = Date.now().toString();
  const baseUrl = `${req.protocol}://${req.get("host")}`;
  const childUrl = `${baseUrl}/camera/view?session=${sessionId}`;

  res.json({
    data: {
      child_url: childUrl,
    },
  });
});

app.get("/camera/view", (req, res) => {
  const session = req.query.session || "";
  res.send(`
    <html>
      <head><meta charset="utf-8"><title>Camera - Child</title></head>
      <body style="font-family: sans-serif; text-align:center; padding-top:50px;">
        <h2>صفحة الطفل</h2>
        <p>Session: ${session}</p>
        <p>قيد التطوير</p>
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
