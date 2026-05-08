/* nix/packages/lifeosd.nix
 *
 * lifeosd — main LifeOS daemon binary.
 * Uses crane via the shared workspace.
 *
 * Uses mkBinFresh (not mkBin) because lifeosd depends on utoipa-swagger-ui
 * which embeds swagger-ui assets via RustEmbed with an absolute $OUT_DIR path.
 * Sharing cargoArtifacts across Nix sandbox instances breaks this crate.
 * See crane-workspace.nix for the full explanation.
 *
 * Feature flags: dbus,http-api,ui-overlay,wake-word,messaging
 * (per feedback_ci_features.md)
 *
 * Satisfies: REQ-2.1, REQ-2.2
 */
{ workspace, lib }:
workspace.mkBinFresh {
  pname = "lifeosd";
  cargoExtraArgs = "-p lifeosd --features dbus,http-api,ui-overlay,wake-word,messaging";
  meta = with lib; {
    description = "LifeOS system daemon";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "lifeosd";
  };
}
