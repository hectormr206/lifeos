/* nix/packages/lifeosd.nix
 *
 * lifeosd — main LifeOS system daemon.
 * Uses crane via the shared workspace.
 *
 * Uses mkBinFresh (not mkBin) because lifeosd depends on utoipa-swagger-ui
 * which embeds swagger-ui assets via RustEmbed with an absolute $OUT_DIR path.
 * Sharing cargoArtifacts across Nix sandbox instances breaks this crate.
 * See crane-workspace.nix for the full explanation.
 *
 * Feature flags: dbus,http-api,messaging
 * NOTE: ui-overlay and wake-word are intentionally EXCLUDED from the systemd
 * service build. Those features require a Wayland/X11 display; when compiled
 * in, GTK's g_application_run() calls exit(1) if no display is available,
 * crashing the daemon. The lifeos-desktop companion binary handles all
 * host-display surfaces (tray, wake-word relay) — the daemon itself is
 * headless. (per feedback_ci_features.md: full features only for CI, not NixOS service)
 *
 * Satisfies: REQ-2.1, REQ-2.2
 */
{ workspace, lib }:
workspace.mkBinFresh {
  pname = "lifeosd";
  cargoExtraArgs = "-p lifeosd --features dbus,http-api,messaging";
  meta = with lib; {
    description = "LifeOS system daemon";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "lifeosd";
  };
}
