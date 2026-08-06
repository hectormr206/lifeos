/// Where each platform's update manifest lives on the update server.
///
/// Android ships ONE signed APK for every device, so its manifest sits at a
/// single well-known path. Desktop ships a tarball of compiled binaries, so it
/// is published per architecture — an arm64 laptop pointed at the x64 build
/// gets something it cannot execute. That is why the architecture is part of
/// the path rather than a field inside the manifest: the wrong build must be
/// unreachable, not merely detectable after download.
///
/// The desktop shape mirrors `tools/publish-linux-to-vps.sh` exactly
/// (`linux/<arch>/manifest.json`). These two are a contract; a test asserts it
/// so a change on either side breaks the build instead of the update.
library;

/// Manifest path (relative to the update base URL) for [operatingSystem], or
/// `null` when this platform publishes no updates at all.
///
/// Returning null rather than a guessed path is deliberate: a future shell
/// asking for a URL nobody publishes to would surface as a server fault and
/// send whoever debugs it looking in the wrong place.
String? updateManifestPathFor(String operatingSystem, {required String arch}) =>
    switch (operatingSystem) {
      'android' || 'ios' => '/manifest',
      'linux' || 'macos' || 'windows' => '/$operatingSystem/$arch/manifest.json',
      _ => null,
    };

/// The architecture name used in published paths, from a `uname -m` value.
///
/// Mirrors the `case "$(uname -m)"` block in `tools/install-linux.sh`; an
/// unrecognised CPU yields null so the app reports "no update info" instead of
/// requesting a build that was never produced for it.
/// Idempotent on purpose: the host probe already reports the published name
/// (`Abi.current()` gives `linux_x64`), while a caller reading `uname -m` gives
/// `x86_64`. Both must land on the same answer, or the two callers disagree
/// about which build this machine runs.
String? updateArchFor(String machine) => switch (machine) {
      'x86_64' || 'amd64' || 'x64' => 'x64',
      'aarch64' || 'arm64' => 'arm64',
      _ => null,
    };
