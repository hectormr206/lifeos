/* nix/packages/lifeos-desktop.nix
 *
 * lifeos-desktop — GTK4 system tray + wake-word relay.
 * Shares cargoArtifacts with lifeosd and life.
 *
 * Satisfies: REQ-2.1
 */
{ workspace, lib }:
workspace.mkBin {
  pname = "lifeos-desktop";
  cargoExtraArgs = "-p lifeos-desktop --features tray,wake-word";
  extraBuildInputs = [];  # gtk4 etc already in commonArgs
  meta = with lib; {
    description = "LifeOS desktop tray companion";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "lifeos-desktop";
  };
}
