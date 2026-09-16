# Security Hardening Report — Camera Parent 2.0.0+2

## Applied changes

- Disabled public `/admin/claim`; the server now requires an `ADMIN_TOKEN` environment variable and never exposes it through an unauthenticated endpoint or startup log.
- Added request rate limits for admin verification, pairing registration/claim/unpair, and WebSocket connections.
- Added strict JSON body size limits and reduced WebSocket payload size to 256 KiB.
- Disabled WebSocket per-message compression to reduce resource-exhaustion risk.
- Removed wildcard CORS behavior; the native mobile client does not require browser CORS.
- Added basic HTTP security headers and disabled Express `X-Powered-By`.
- Protected `/stats` and `/ice-servers` with admin authentication.
- Added same-session target validation for WebSocket ICE, switch-camera, toggle-mic, and kick messages to prevent cross-session message injection.
- Added message type/shape and credential length validation.
- Increased new-account password minimum from 4 to 12 characters and added authentication throttling.
- Added Android Keystore-backed AES-GCM storage for `admin_token` and `device_token`, with one-time migration from legacy SharedPreferences.
- Disabled Android cleartext traffic through Network Security Config.
- Raised Android minimum SDK to 23 because the Keystore-backed AES-GCM implementation relies on APIs available from Android 6.0.
- Kept `version: 2.0.0+2`.

## Deployment requirement

Before deploying the server, set `ADMIN_TOKEN` in the server environment to a random value of at least 32 characters. Do not commit it to GitHub, source files, screenshots, or logs.

## Validation

- `node --check server/index.js`: passed.
- ZIP integrity (`unzip -t`): passed.
- Flutter build/analyze was not run in this environment because Flutter is not installed here; the project is intended to build in GitHub Actions.

## Remaining security work

A full production assessment should still include dependency/SCA scanning, authenticated WebSocket fuzzing, API authorization tests, release APK static analysis, and testing against the deployed Render/Upstash environment.
