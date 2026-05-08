/* nix/hosts/vm/default.nix
 *
 * NixOS configuration for the LifeOS development VM.
 *
 * Phase A target: no NVIDIA, no COSMIC, no TTS.
 * Boots to multi-user.target (no display manager — minimal VM).
 *
 * All LifeOS Phase A services are enabled here:
 *   - lifeosd (main daemon, UDS+TCP, SO_PEERCRED)
 *
 * Anti-orphan: every module imported here MUST be wired (REQ-3.6, REQ-12.1).
 * lifeosd module → imported + enabled below.
 *
 * Satisfies: REQ-1.1, REQ-3.6, REQ-6.1, REQ-7.1, REQ-7.2
 */
{ config, pkgs, lib, lifeos, ... }:
{
  imports = [
    # Disko partition layout
    ../../disko/vm.nix

    # LifeOS baseline: users, groups, tmpfiles
    ../../modules/lifeos-defaults.nix

    # Phase A services
    ../../modules/lifeosd.nix
  ];

  # ===== System identity =====
  networking.hostName = "lifeos-vm";
  system.stateVersion = "24.11";

  # ===== Boot =====
  # (boot.loader inherited from mkLifeosSystem baseline)

  # ===== Phase A services =====

  # lifeosd — main LifeOS daemon
  # Package comes from flake specialArgs (crane-built, not nixpkgs)
  services.lifeos.lifeosd = {
    enable = true;
    package = lifeos.packages.lifeosd;
    sqliteVecPackage = lifeos.packages.sqlite-vec;
    # Bootstrap token: on the VM we use a simple file with a test token.
    # On the laptop (Phase C) this is provisioned via sops-nix or secrets file.
    bootstrapTokenFile = pkgs.writeText "lifeosd-bootstrap-token" ''
      LIFEOS_BOOTSTRAP_TOKEN=vm-dev-token-insecure
    '';
  };

  # ===== Base packages =====
  environment.systemPackages = with pkgs; [
    curl
    git
    vim
    htop
    # lifeos packages exposed as normal system packages on VM
    lifeos.packages.lifeosd
    lifeos.packages.life
  ];

  # ===== Attic substituter (REQ-7.1) =====
  # Declared in lib/default.nix baseline; supplemented here with any
  # VM-specific overrides. Placeholder pubkey noted — real key at T-A4-4.
  # nix.settings.substituters and trusted-public-keys come from mkLifeosSystem.

  # ===== Home manager (minimal for VM) =====
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };
}
