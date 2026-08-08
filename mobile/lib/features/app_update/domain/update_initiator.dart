/// WHO asked for this update.
///
/// This distinction is not bookkeeping — it is the safety boundary for the
/// automatic relaunch. Applying an update the user explicitly asked for is
/// finishing the job he started. Applying one that a background check happened
/// to find is taking the window away from someone who is mid-sentence, and
/// destroying work nobody asked us to touch.
///
/// It is an explicit REQUIRED argument rather than a default precisely so a
/// future automatic caller cannot inherit the destructive behaviour by
/// forgetting to think about it.
library;

enum UpdateInitiator {
  /// The user pressed "Actualizar ahora" (or the update banner). He is present,
  /// he is looking at the screen, and finishing the update is what he asked
  /// for — so the app may relaunch itself into the new version.
  user,

  /// A launch check, a resume check or any other automatic path. The update
  /// may be installed, but the running app is NEVER restarted out from under
  /// whoever is using it.
  background,
}
