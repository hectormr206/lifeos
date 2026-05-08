/* nix/packages/lifeosd.nix
 *
 * lifeosd — main LifeOS daemon binary.
 * Uses crane via the shared workspace cargoArtifacts.
 *
 * Feature flags: dbus,http-api,ui-overlay,wake-word,messaging
 * (per feedback_ci_features.md)
 *
 * Satisfies: REQ-2.1, REQ-2.2
 */
{ workspace, lib }:
workspace.mkBin {
  pname = "lifeosd";
  cargoExtraArgs = "-p lifeosd --features dbus,http-api,ui-overlay,wake-word,messaging";
  meta = with lib; {
    description = "LifeOS system daemon";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "lifeosd";
  };
}
