/* nix/tests/lifeosd-vm-test.nix
 *
 * NixOS integration test for the lifeosd module.
 *
 * TDD phase: GREEN — module, packages, and test wired together.
 *
 * Run (after flake is wired):
 *   nix build .#checks.x86_64-linux.lifeosd-vm-test
 *
 * Satisfies: REQ-3.1, REQ-3.2, REQ-3.4, SCENARIO-1
 */
{ pkgs, ... }:
pkgs.nixosTest {
  name = "lifeosd-module";

  nodes.machine = { config, pkgs, ... }: {
    imports = [
      ../modules/lifeosd.nix
      ../modules/lifeos-defaults.nix
    ];

    services.lifeos.lifeosd = {
      enable = true;
      # pkgs.lifeosd and pkgs.sqlite-vec are injected via the overlay in
      # the flake's mkPkgs (or via overlays passed to nixosTest pkgs).
      package = pkgs.lifeosd;
      sqliteVecPackage = pkgs.sqlite-vec;
      bootstrapTokenFile = pkgs.writeText "bootstrap-token" ''
        LIFEOS_BOOTSTRAP_TOKEN=test-token-insecure
      '';
    };
  };

  testScript = ''
    machine.start()

    # Wait for lifeosd to be active
    machine.wait_for_unit("lifeosd.service")

    # Assert the UDS socket exists (Phase 8b contract)
    machine.wait_for_file("/run/lifeos/lifeosd.sock")

    # Assert health endpoint responds over UDS
    machine.succeed(
      "curl --unix-socket /run/lifeos/lifeosd.sock http://localhost/api/v1/health"
    )

    # Assert service is running (not just activating)
    machine.succeed("systemctl is-active lifeosd.service")
  '';
}
