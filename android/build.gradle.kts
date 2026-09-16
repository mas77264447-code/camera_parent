allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Android 14+ requires MediaProjection consent before a mediaProjection FGS is
// promoted. flutter_webrtc 1.5.2 obtains the consent Intent internally, so this
// deterministic, version-pinned patch starts this app's FGS immediately after
// the consent callback and before WebRTC creates the MediaProjection capturer.
// The dependency is pinned in pubspec.yaml so a plugin source-layout change
// cannot silently produce an incorrectly patched build.
tasks.register("patchFlutterWebRtcMediaProjection") {
    doLast {
        val pubCache = System.getenv("PUB_CACHE")
            ?: java.nio.file.Paths.get(System.getProperty("user.home"), ".pub-cache").toString()
        val root = java.nio.file.Paths.get(pubCache, "hosted")
        if (!java.nio.file.Files.exists(root)) {
            throw GradleException("PUB_CACHE not found: $root. Run flutter pub get first.")
        }

        val candidates = java.nio.file.Files.walk(root).use { paths ->
            paths.filter { path ->
                path.fileName.toString() == "GetUserMediaImpl.java" &&
                    path.toString().contains("flutter_webrtc-1.5.2") &&
                    path.toString().contains("android")
            }.toList()
        }
        if (candidates.isEmpty()) {
            throw GradleException("flutter_webrtc GetUserMediaImpl.java was not found in $root")
        }

        val source = candidates.first().toFile()
        var text = source.readText()
        if (text.contains("CAMERA_PARENT_MEDIA_PROJECTION_PATCH_V2")) {
            logger.lifecycle("flutter_webrtc MediaProjection patch already applied: ${source.absolutePath}")
            return@doLast
        }

        // Match the target block tolerant of whitespace/indentation differences
        // (the published package's formatting can drift from what this literal
        // assumed), while still requiring every token to appear in order so an
        // actual logic/layout change still fails loudly instead of patching the
        // wrong spot.
        fun flexible(literal: String): Regex =
            Regex(literal.trim().split(Regex("\\s+")).joinToString("\\s+") { Regex.escape(it) })

        val targetRegex = flexible(
            """if (resultCode != Activity.RESULT_OK) {
                        resultError("screenRequestPermissions", "User didn't give permission to capture the screen.", result);
                        return;
                    }
                    getDisplayMedia(result, mediaStream, mediaProjectionData);"""
        )
        val replacement = """if (resultCode != Activity.RESULT_OK) {
                        resultError("screenRequestPermissions", "User didn't give permission to capture the screen.", result);
                        return;
                    }
                    // CAMERA_PARENT_MEDIA_PROJECTION_PATCH_V2
                    startCameraParentMediaProjectionForegroundService();
                    waitForCameraParentMediaProjectionForegroundService(result, mediaStream, mediaProjectionData, 0);"""

        val targetMatch = targetRegex.find(text)
            ?: throw GradleException("flutter_webrtc source layout changed; MediaProjection patch was not applied: ${source.absolutePath}")
        text = text.substring(0, targetMatch.range.first) + replacement + text.substring(targetMatch.range.last + 1)

        val markerLiteral = """private void getDisplayMedia(final Result result, final MediaStream mediaStream, final Intent mediaProjectionData) {"""
        val helper = """private void startCameraParentMediaProjectionForegroundService() {
        try {
            Intent serviceIntent = new Intent();
            serviceIntent.setClassName(
                applicationContext,
                applicationContext.getPackageName() + ".StreamForegroundService");
            serviceIntent.setAction("com.example.camera_parent.action.START_STREAM_SERVICE");
            serviceIntent.putExtra("mode", "screen");
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(serviceIntent);
            } else {
                applicationContext.startService(serviceIntent);
            }
        } catch (Exception e) {
            Log.e(TAG, "Unable to start Camera Parent MediaProjection foreground service", e);
            throw e;
        }
    }

    private void waitForCameraParentMediaProjectionForegroundService(
            final Result result,
            final MediaStream mediaStream,
            final Intent mediaProjectionData,
            final int attempt) {
        final boolean ready = applicationContext
            .getSharedPreferences("camera_parent_service", Context.MODE_PRIVATE)
            .getBoolean("screen_fgs_ready", false);

        if (ready) {
            getDisplayMedia(result, mediaStream, mediaProjectionData);
            return;
        }

        if (attempt >= 100) {
            resultError(
                "screenRequestPermissions",
                "MediaProjection foreground service did not become ready in time.",
                result);
            return;
        }

        new Handler(Looper.getMainLooper()).postDelayed(() ->
            waitForCameraParentMediaProjectionForegroundService(
                result, mediaStream, mediaProjectionData, attempt + 1), 50L);
    }

    """
        val markerMatch = flexible(markerLiteral).find(text)
            ?: throw GradleException("flutter_webrtc getDisplayMedia marker not found: ${source.absolutePath}")
        text = text.substring(0, markerMatch.range.first) + helper + markerMatch.value + text.substring(markerMatch.range.last + 1)
        source.writeText(text)
        logger.lifecycle("Applied Camera Parent MediaProjection patch to ${source.absolutePath}")
    }
}
