// server/keepalive.js
// ═══════════════════════════════════════════════════════════
// منع Render من إيقاف الخدمة + إبقاء WebSocket نشطاً
// ═══════════════════════════════════════════════════════════

function startKeepAlive() {
  const SELF_URL =
    process.env.RENDER_EXTERNAL_URL ||
    "https://camera-parent-server.onrender.com";

  // 1) Ping ذاتي كل 10 دقائق لمنع Render من النوم
  const pingInterval = 10 * 60 * 1000; // 10 دقائق

  async function pingSelf() {
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 8000);

      const res = await fetch(`${SELF_URL}/health`, {
        method: "GET",
        signal: controller.signal,
      });
      clearTimeout(timeout);
      console.log(`[keepalive] 🟢 ping OK (${res.status}) @ ${new Date().toISOString()}`);
    } catch (e) {
      console.warn(`[keepalive] ⚠️ ping failed: ${e.message}`);
    }
  }

  // أول ping بعد دقيقة من الإقلاع (Render تحتاج وقت للاستقرار)
  setTimeout(pingSelf, 60 * 1000);

  // ثم كل 10 دقائق
  setInterval(pingSelf, pingInterval);

  console.log("[keepalive] ✅ Self-ping started (every 10 min)");
}

// ═══════════════════════════════════════════════════════════
// Heartbeat لـ WebSocket لمنع قطع الاتصال
// ═══════════════════════════════════════════════════════════

function attachHeartbeat(wss) {
  const HEARTBEAT_INTERVAL = 30 * 1000; // 30 ثانية

  const interval = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) {
        console.log("[ws] ❌ terminating dead connection");
        return ws.terminate();
      }
      ws.isAlive = false;
      try {
        ws.ping();
      } catch (_) {}
    });
  }, HEARTBEAT_INTERVAL);

  wss.on("connection", (ws) => {
    ws.isAlive = true;
    ws.on("pong", () => {
      ws.isAlive = true;
    });
  });

  wss.on("close", () => clearInterval(interval));

  console.log("[ws] ✅ Heartbeat attached (every 30s)");
}

module.exports = { startKeepAlive, attachHeartbeat };