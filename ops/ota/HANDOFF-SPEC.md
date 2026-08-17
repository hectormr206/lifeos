# LifeOS mobile OTA update host — hand-off spec (for the VPS agent)

Please REVIEW and finish the Cloudflare public exposure.

## Purpose
Host the LifeOS Android app self-update. The sideloaded app checks this host (NO pairing) for a newer version and downloads the APK.

## Content in this dir (/home/hectormr/lifeos-updates)
- manifest.json  -> {versionCode, versionName, apkFilename, sha256, sizeBytes, notes, publishedAt}
- lifeos-<versionName>-<versionCode>.apk  -> the signed release APK
(Claude uploads both AFTER building the final app with your public URL baked in.)

## Endpoints the app expects (serve this dir)
- GET  <base>/manifest   -> manifest.json (application/json)
- GET  <base>/download   -> the current APK (application/vnd.android.package-archive)

## ACCESS CONTROL (required)
The app sends header:  X-LifeOS-Update-Key: 24c116f17508c5707b3ae5f8b595374edf572bd657b4a3661ecf84566f328e8d
Serving MUST require this exact header on both endpoints (403 without it).
The APK is also keystore-signed and sha256-verified by the app.

## What the agent needs to do
1. Serve this dir via Coolify (static/nginx), enforcing the X-LifeOS-Update-Key header.
2. Expose it publicly via Cloudflare at a domain (e.g. updates.<domain>/lifeos).
3. Reply to Claude with the FINAL public base URL + confirm the key value.
Then Claude bakes {URL, key} into the app, builds, and uploads manifest.json + the APK here.

KEY: 24c116f17508c5707b3ae5f8b595374edf572bd657b4a3661ecf84566f328e8d
