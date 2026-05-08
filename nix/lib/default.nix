/* nix/lib/default.nix
 *
 * mkLifeosSystem — helper to build a NixOS configuration with the LifeOS
 * baseline (locale, SSH, firewall, nix settings, substituter).
 *
 * Usage in hosts/vm/default.nix:
 *   { mkLifeosSystem, nixpkgs, ... }:
 *   mkLifeosSystem {
 *     system = "x86_64-linux";
 *     extraModules = [ ./vm-specific.nix ];
 *   }
 *
 * Satisfies: REQ-1.1 (shared host baseline)
 */
{ nixpkgs, home-manager, disko }:
let
  # Baseline module imported by every nixosConfiguration.
  lifeosBaseModule = { pkgs, lib, ... }: {
    # Locale + timezone
    time.timeZone = "America/Mexico_City";
    i18n.defaultLocale = "en_US.UTF-8";

    # Boot
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Networking — basic; hosts override as needed
    networking.firewall.enable = true;
    networking.useDHCP = lib.mkDefault true;

    # SSH
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };

    # Nix settings baseline
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      # Substituters declared here; hosts may add more (e.g., attic)
      substituters = [
        "https://cache.nixos.org"
        "https://cache.lifeos.hectormr.com/lifeos"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        # lifeos attic pubkey: set after atticd setup (T-A4-4)
        # "lifeos:<PUBKEY_FROM_ATTICD_SETUP>"
      ];
      # Fail-soft: if attic is unreachable, fall through to cache.nixos.org
      # then build locally. REQ-7.2 / SCENARIO-4.
      fallback = true;
      connect-timeout = 5;
      stalled-download-timeout = 30;
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };

    # Allow unfree needed for NVIDIA (Phase B)
    nixpkgs.config.allowUnfree = true;

    # zram swap — no swap partition
    zramSwap.enable = true;
    zramSwap.memoryPercent = 50;
  };
in
{
  # mkLifeosSystem: produces a full nixosSystem attribute.
  mkLifeosSystem = { system, extraModules ? [], specialArgs ? {} }:
    nixpkgs.lib.nixosSystem {
      inherit system specialArgs;
      modules = [
        lifeosBaseModule
        disko.nixosModules.disko
        home-manager.nixosModules.home-manager
      ] ++ extraModules;
    };
}
