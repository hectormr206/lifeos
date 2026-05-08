/* nix/packages/life.nix
 *
 * life — LifeOS CLI binary.
 * Shares cargoArtifacts with lifeosd (crane workspace dep cache).
 *
 * Satisfies: REQ-2.1
 */
{ workspace, lib }:
workspace.mkBin {
  pname = "life";
  cargoExtraArgs = "-p life";
  meta = with lib; {
    description = "LifeOS command-line interface";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "life";
  };
}
