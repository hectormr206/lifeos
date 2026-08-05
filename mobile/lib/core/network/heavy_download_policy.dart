/// THE RULE FOR ANYTHING BIG THE APP FETCHES BY ITSELF.
///
/// LifeOS updates itself without being asked: a new APK when one is published,
/// new model weights when they are. Those are ~330 MB and ~2.4 GB. On mobile
/// data that is somebody's phone bill, spent by software they never told to
/// spend it — and the user cannot even see it happening, because the whole
/// point of a background update is that it is invisible.
///
/// So the rule is one line: AUTOMATIC HEAVY DOWNLOADS HAPPEN ON WI-FI ONLY.
///
/// It is enforced by [requiresWiFi] on the download task itself, which is an
/// operating-system guarantee rather than a check this code performs. The
/// download is simply held by the platform until Wi-Fi is available — no
/// polling, no retry loop, and nothing to get wrong. Off Wi-Fi it WAITS,
/// SILENTLY, which is what the user asked for: an update that interrupts to
/// say it cannot run yet is not an automatic update.
///
/// WHY A CONSTANT AND NOT THREE LITERALS. The user's requirement was not "fix
/// the two downloads we have" — it was that anything heavy, "ahora o en el
/// futuro", must obey this. Three copies of `true` are three chances for a
/// fourth downloader to be written without one. Everything heavy goes through
/// this constant, and a guard test fails the build if a new [DownloadTask] is
/// added that does not.
///
/// WHAT THIS DELIBERATELY DOES NOT COVER. Small, latency-sensitive traffic —
/// chat with the laptop, the morning briefing's feed fetches, a manifest poll —
/// stays on any connection. Those are kilobytes, and gating them on Wi-Fi would
/// leave the user without a briefing on any day they are not at home. The rule
/// is about SIZE, not about the network being free.
library;

/// Whether an automatic heavy download may use a metered connection.
///
/// Always false. Named rather than inlined so the intent is greppable and the
/// guard test has something to assert against.
const bool kHeavyDownloadsRequireWiFi = true;

/// A user-initiated download is NOT bound by this policy: if someone taps
/// "download now" they have chosen to spend their data, and overriding that
/// choice would be the app deciding it knows better.
///
/// Nothing sets this today. It exists so that the day a "descargar ahora con
/// datos" button is added, the exemption is an explicit, visible argument
/// rather than someone quietly flipping the constant above.
const bool kUserInitiatedDownloadRequiresWiFi = false;
