// LifeOS Firefox Preferences
// This file sets preferences that are NOT enforced by policies.json
// Policies are for critical security/privacy; user.js is for cosmetic preferences
// Location: /etc/skel/.mozilla/firefox/lifeos.default/user.js

// ============================================================================
// WAYLAND SUPPORT
// ============================================================================

// Enable Wayland native rendering (also set via environment variable)
// This is a backup in case MOZ_ENABLE_WAYLAND isn't set
// pref("widget.wayland-dmabuf-vaapi.enabled", true);

// ============================================================================
// UI / COSMETIC PREFERENCES
// ============================================================================

// Use dark theme by default (matches LifeOS aesthetic)
user_pref("layout.css.prefers-color-scheme.content-override", 0);

// Smooth scrolling
user_pref("general.smoothScroll", true);
user_pref("general.smoothScroll.msdPhysics.enabled", true);

// Disable animations for faster UI
user_pref("toolkit.cosmeticAnimations.enabled", false);

// Compact UI density
user_pref("browser.uidensity", 1);

// Show bookmarks bar only on new tab
user_pref("browser.toolbars.bookmarks.visibility", "newtab");

// ============================================================================
// PRIVACY ENHANCEMENTS (supplemental to policies)
// ============================================================================

// Disable WebRTC leaks
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", false);

// Disable WebGL (fingerprinting vector) - can be re-enabled per-site
user_pref("webgl.disabled", false); // Keep WebGL for games, but...
user_pref("webgl.enable-webgl2", true);

// Disable battery API (fingerprinting)
user_pref("dom.battery.enabled", false);

// Disable WebRTC platform UDP port leak
user_pref("media.peerconnection.ice.proxy_only_if_behind_proxy", true);

// Privacy resist fingerprinting
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.pbmode", true);

// Letterboxing (Tor Browser feature) - optional, can cause layout issues
user_pref("privacy.resistFingerprinting.letterboxing", false);

// ============================================================================
// PERFORMANCE
// ============================================================================

// Hardware acceleration
user_pref("layers.acceleration.enabled", true);
user_pref("layers.acceleration.force-enabled", true);
user_pref("gfx.webrender.all", true);

// VA-API hardware video decoding (Wayland)
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.ffmpeg.vaapi-drm-display.enabled", true);
user_pref("media.rdd-ffmpeg.enabled", true);

// ============================================================================
// NETWORK
// ============================================================================

// DNS over HTTPS (DoH)
user_pref("network.trr.mode", 2); // TRR first, fallback to system DNS
user_pref("network.trr.uri", "https://dns.quad9.net/dns-query");
user_pref("network.trr.custom_uri", "https://dns.quad9.net/dns-query");

// Disable prefetching (privacy)
user_pref("network.predictor.enabled", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.prefetch-next", false);

// ============================================================================
// SESSION / STARTUP
// ============================================================================

// Restore session on startup
user_pref("browser.startup.page", 3); // Resume previous session

// Disable crash recovery prompt
user_pref("browser.sessionstore.resume_from_crash", true);

// ============================================================================
// CONTENT SETTINGS
// ============================================================================

// Default zoom
user_pref("layout.css.devPixelsPerPx", "1.0");

// Reader mode settings
user_pref("reader.color_scheme", "dark");

// Picture-in-picture
user_pref("media.videocontrols.picture-in-picture.video-toggle.enabled", true);

// ============================================================================
// DEVELOPER TOOLS
// ============================================================================

// Dark theme for devtools
user_pref("devtools.theme", "dark");

// ============================================================================
// EXTENSIONS
// ============================================================================

// uBlock Origin settings will be managed by the extension itself
// but we can set some defaults here if needed

// Allow extensions on all URLs
user_pref("extensions.webextensions.restrictedDomains", "");

// ============================================================================
// PDF VIEWER
// ============================================================================

// Use built-in PDF viewer
user_pref("pdfjs.disabled", false);

// ============================================================================
// TAB BEHAVIOR
// ============================================================================

// Don't close window with last tab
user_pref("browser.tabs.closeWindowWithLastTab", false);

// Open new tabs in background
user_pref("browser.tabs.loadInBackground", true);

// Open bookmarks in new tab
user_pref("browser.tabs.loadBookmarksInTabs", true);

// ============================================================================
// DOWNLOAD BEHAVIOR
// ============================================================================

// Always ask where to save (overridden by policy PromptForDownloadLocation)
user_pref("browser.download.useDownloadDir", false);

// Don't add downloads to history
user_pref("browser.download.manager.addToRecentDocs", false);

// ============================================================================
// SEARCH
// ============================================================================

// Search suggestions (privacy consideration)
user_pref("browser.search.suggest.enabled", false);
user_pref("browser.search.suggest.enabled.private", false);

// ============================================================================
// FORMS
// ============================================================================

// Disable form autofill (privacy)
user_pref("browser.formfill.enable", false);

// ============================================================================
// CLIPBOARD
// ============================================================================

// Allow paste buttons in context menu
user_pref("dom.event.clipboardevents.enabled", true);

// ============================================================================
// U2F / WEBAUTHN
// ============================================================================

// Enable WebAuthn for security keys
user_pref("security.webauth.webauthn", true);
user_pref("security.webauth.u2f", true);
