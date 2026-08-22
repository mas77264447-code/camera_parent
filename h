[1mdiff --git a/server/index.js b/server/index.js[m
[1mindex 35330c9..522056e 100644[m
[1m--- a/server/index.js[m
[1m+++ b/server/index.js[m
[36m@@ -186,55 +186,32 @@[m [mapp.get("/camera/view", (req, res) => {[m
           #remoteHalf { border-bottom: 2px solid #333; }[m
           video { width:100%; height:100%; object-fit:cover; }[m
           .label { position:absolute; top:8px; right:12px; background:rgba(0,0,0,0.5); color:#fff; padding:4px 12px; border-radius:14px; font-size:12px; }[m
[32m+[m[32m          #unmuteBtn { position:absolute; bottom:12px; left:50%; transform:translateX(-50%); padding:10px 20px; border-radius:20px; border:none; background:#6c3fc5; color:#fff; font-size:14px; display:none; z-index:5; }[m
           #status { position:absolute; top:8px; left:12px; background:rgba(0,0,0,0.5); color:#ccc; padding:4px 12px; border-radius:14px; font-size:12px; }[m
 [m
[31m-          #controls {[m
[31m-            position: fixed;[m
[31m-            left: 0; right: 0;[m
[31m-            bottom: 0;[m
[31m-            padding-bottom: max(14px, env(safe-area-inset-bottom));[m
[31m-            padding-top: 10px;[m
[31m-            display: flex;[m
[31m-            justify-content: center;[m
[31m-            gap: 16px;[m
[31m-            z-index: 999;[m
[31m-            background: linear-gradient(to top, rgba(0,0,0,0.75), rgba(0,0,0,0));[m
[31m-            pointer-events: none;[m
[31m-          }[m
[31m-          #controls button {[m
[31m-            pointer-events: auto;[m
[31m-            width: 52px; height: 52px;[m
[31m-            border-radius: 50%;[m
[31m-            border: none;[m
[31m-            background: rgba(30,30,30,0.85);[m
[31m-            color: #fff;[m
[31m-            font-size: 22px;[m
[31m-            display: flex;[m
[31m-            align-items: center;[m
[31m-            justify-content: center;[m
[31m-          }[m
[31m-          #controls button.off { background:#c0392b; }[m
[32m+[m[32m          #controls { position:absolute; bottom:12px; right:12px; display:flex; gap:10px; z-index:5; }[m
[32m+[m[32m          #controls button { width:46px; height:46px; border-radius:50%; border:none; background:rgba(0,0,0,0.6); color:#fff; font-size:20px; display:flex; align-items:center; justify-content:center; }[m
[32m+[m[32m          #controls button.muted { background:#c0392b; }[m
         </style>[m
       </head>[m
       <body>[m
         <div id="callScreen">[m
[31m-          <div id="remoteHalf">[m
[32m+[m[32m          <div id="remoteHalf" onclick="unmuteRemote()">[m
             <span class="label">الكاميرا</span>[m
             <span id="status">جاري الاتصال...</span>[m
             <video id="remoteVideo" autoplay playsinline muted></video>[m
[32m+[m[32m            <button id="unmuteBtn" onclick="event.stopPropagation(); unmuteRemote();">تشغيل الصوت 🔊</button>[m
           </div>[m
           <div id="localHalf">[m
             <span class="label">أنا</span>[m
             <video id="localVideo" autoplay playsinline muted></video>[m
[32m+[m[32m            <div id="controls">[m
[32m+[m[32m              <button id="switchCamBtn" title="تبديل الكاميرا">🔄</button>[m
[32m+[m[32m              <button id="micBtn" title="كتم/تشغيل الصوت">🎤</button>[m
[32m+[m[32m            </div>[m
           </div>[m
         </div>[m
 [m
[31m-        <div id="controls">[m
[31m-          <button id="speakerBtn" title="تشغيل/كتم صوت الكاميرا" class="off">🔇</button>[m
[31m-          <button id="switchCamBtn" title="تبديل الكاميرا">🔄</button>[m
[31m-          <button id="micBtn" title="كتم/تشغيل المايك">🎤</button>[m
[31m-        </div>[m
[31m-[m
         <script>[m
           const sessionId = "${sessionId}";[m
           const iceServers = ${ICE_SERVERS_JS};[m
[36m@@ -244,7 +221,6 @@[m [mapp.get("/camera/view", (req, res) => {[m
           let localStream = null;[m
           let facingMode = "user";[m
           let micEnabled = true;[m
[31m-          let speakerEnabled = false;[m
 [m
           window.addEventListener("load", startCall);[m
 [m
[36m@@ -266,9 +242,9 @@[m [mapp.get("/camera/view", (req, res) => {[m
                 pc.ontrack = (e) => {[m
                   const video = document.getElementById("remoteVideo");[m
                   video.srcObject = e.streams[0];[m
[31m-                  video.muted = !speakerEnabled;[m
                   video.play().catch(() => {});[m
                   document.getElementById("status").innerText = "متصل";[m
[32m+[m[32m                  document.getElementById("unmuteBtn").style.display = "inline-block";[m
                 };[m
 [m
                 pc.onicecandidate = (e) => {[m
[36m@@ -300,16 +276,17 @@[m [mapp.get("/camera/view", (req, res) => {[m
             };[m
           }[m
 [m
[31m-          document.getElementById("speakerBtn").addEventListener("click", () => {[m
[31m-            speakerEnabled = !speakerEnabled;[m
[32m+[m[32m          document.getElementById("unmuteBtn").addEventListener("click", () => {[m
[32m+[m[32m            unmuteRemote();[m
[32m+[m[32m          });[m
[32m+[m
[32m+[m[32m          function unmuteRemote() {[m
             const video = document.getElementById("remoteVideo");[m
[31m-            video.muted = !speakerEnabled;[m
[32m+[m[32m            video.muted = false;[m
             video.volume = 1.0;[m
[31m-            if (speakerEnabled) video.play().catch(() => {});[m
[31m-            const btn = document.getElementById("speakerBtn");[m
[31m-            btn.classList.toggle("off", !speakerEnabled);[m
[31m-            btn.innerText = speakerEnabled ? "🔊" : "🔇";[m
[31m-          });[m
[32m+[m[32m            video.play().catch(() => {});[m
[32m+[m[32m            document.getElementById("unmuteBtn").style.display = "none";[m
[32m+[m[32m          }[m
 [m
           document.getElementById("switchCamBtn").addEventListener("click", async () => {[m
             if (!localStream) return;[m
[36m@@ -321,7 +298,6 @@[m [mapp.get("/camera/view", (req, res) => {[m
 [m
               if (pc) {[m
                 const sender = pc.getSenders().find(s => s.track && s.track.kind === "video");[m
[31m-[m
                 if (sender) await sender.replaceTrack(newVideoTrack);[m
               }[m
 [m
[36m@@ -337,7 +313,7 @@[m [mapp.get("/camera/view", (req, res) => {[m
             if (!localStream) return;[m
             micEnabled = !micEnabled;[m
             localStream.getAudioTracks().forEach(t => t.enabled = micEnabled);[m
[31m-            document.getElementById("micBtn").classList.toggle("off", !micEnabled);[m
[32m+[m[32m            document.getElementById("micBtn").classList.toggle("muted", !micEnabled);[m
             document.getElementById("micBtn").innerText = micEnabled ? "🎤" : "🔇";[m
           });[m
         </script>[m
