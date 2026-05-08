/* nix/tests/lifeosd-vm-test.nix
 *
 * NixOS integration test for the lifeosd module.
 *
 * TDD phase: RED (written before lifeosd.nix exists)
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
      package = config.lifeos.packages.lifeosd;
      sqliteVecPackage = config.lifeos.packages.sqlite-vec;
      bootstrapTokenFile = pkgs.writeText "bootstrap-token" "test-token-insecure";
    };

    # Make packages available via specialArgs
    _module.args.lifeos = {
      packages = {
        lifeosd = pkgs.lifeosd;
        sqlite-vec = pkgs.sqlite-vec;
      };
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
