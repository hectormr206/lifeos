/* nix/flake.nix — canonical LifeOS flake
 *
 * This is the authoritative flake definition. flake.nix at the repo root
 * is a symlink pointing here so that `nix build .#x` works from the repo root.
 *
 * Phase A outputs:
 *   nixosConfigurations.vm
 *   packages.{system}.{lifeosd, life, lifeos-desktop, sqlite-vec}
 *   devShells.{system}.default
 *   checks.{system}.lifeosd-vm-test
 *
 * Phase B outputs (not yet): nixosConfigurations.laptop, kokoro-tts
 * Phase C outputs (not yet): installer-iso, disko/laptop.nix
 *
 * Binary cache: https://cache.lifeos.hectormr.com/lifeos
 * Atticd setup: T-A4-4 (pubkey placeholder until then)
 *
 * Satisfies: REQ-1.1, REQ-1.2, REQ-1.5
 */
{
  description = "LifeOS — AI-native NixOS configuration and packages";

  inputs = {
    # Pinned nixpkgs — use nixos-unstable for latest COSMIC/NVIDIA support
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # home-manager matched to nixpkgs rev (REQ-1.2)
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative partition layout
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Rust packaging with dep-cache separation (REQ-2.1)
    crane.url = "github:ipetkov/crane";

    # Rust toolchain overlay (for pinned channel from rust-toolchain.toml)
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixos-cosmic: PINNED rev — manual updates only (REQ-1.3, Phase B)
    # Declared now but outputs are not yet consumed (Phase B wires it).
    nixos-cosmic = {
      url = "github:lilyinstarlight/nixos-cosmic";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, disko, crane, rust-overlay, nixos-cosmic, ... }:
    let
      # Supported systems — x86_64-linux for Phase A
      supportedSystems = [ "x86_64-linux" ];

      # Helper: produce per-system attribute set
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Helper: mkPkgs — nixpkgs with rust-overlay applied
      mkPkgs = system: import nixpkgs {
        inherit system;
        overlays = [
          rust-overlay.overlays.default
          # LifeOS package overlay: adds lifeosd, life, lifeos-desktop, sqlite-vec
          (final: prev: {
            lifeosd = final.callPackage ./packages/lifeosd.nix { inherit workspace; };
            life = final.callPackage ./packages/life.nix { inherit workspace; };
            lifeos-desktop = final.callPackage ./packages/lifeos-desktop.nix { inherit workspace; };
            sqlite-vec = final.callPackage ./packages/sqlite-vec.nix {};
          })
        ];
        config.allowUnfree = true;
      };

      # Workspace: shared crane setup (cargoArtifacts shared across all binaries)
      # Defined lazily per-system.
      mkWorkspace = system:
        let pkgs = mkPkgs system;
        in import ./lib/crane-workspace.nix {
          inherit pkgs;
          crane = crane.mkLib pkgs;
        };

      # Convenience binding (used in overlay above — but needs system context)
      # The overlay calls workspace which is system-scoped; we handle this via
      # specialArgs in nixosConfigurations.
      workspace = mkWorkspace "x86_64-linux";

      # Lib helpers (mkLifeosSystem)
      lifeoLib = import ./lib/default.nix {
        inherit nixpkgs home-manager disko;
      };
    in
    {
      # ===== NixOS Configurations =====

      nixosConfigurations = {
        # Phase A: development VM (no NVIDIA, no COSMIC, no TTS)
        vm = lifeoLib.mkLifeosSystem {
          system = "x86_64-linux";
          specialArgs = {
            # Make crane-built packages available to host modules via specialArgs
            lifeos = {
              packages = {
                lifeosd = (mkPkgs "x86_64-linux").lifeosd;
                life = (mkPkgs "x86_64-linux").life;
                "lifeos-desktop" = (mkPkgs "x86_64-linux").lifeos-desktop;
                "sqlite-vec" = (mkPkgs "x86_64-linux").sqlite-vec;
              };
            };
          };
          extraModules = [
            ./hosts/vm/default.nix
          ];
        };

        # Phase B: laptop config — scaffolded but empty until PR-B1
        # laptop = ... (Phase B)
      };

      # ===== Packages =====

      packages = forAllSystems (system:
        let pkgs = mkPkgs system;
        in {
          lifeosd = pkgs.lifeosd;
          life = pkgs.life;
          lifeos-desktop = pkgs.lifeos-desktop;
          sqlite-vec = pkgs.sqlite-vec;

          # Default package: lifeosd
          default = pkgs.lifeosd;
        }
      );

      # ===== Dev Shells =====

      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ../rust-toolchain.toml;
        in
        {
          default = import ./devShells.nix { inherit pkgs rustToolchain; };
        }
      );

      # ===== Checks (nixos-tests + cargo tests) =====

      checks = forAllSystems (system:
        let pkgs = mkPkgs system;
        in {
          # lifeosd integration test (RED written first in T-A1-1)
          lifeosd-vm-test = import ./tests/lifeosd-vm-test.nix {
            inherit pkgs;
          };
        }
      );

      # ===== NixOS Modules (for external consumption) =====

      nixosModules = {
        lifeosd = import ./modules/lifeosd.nix;
        lifeos-defaults = import ./modules/lifeos-defaults.nix;
      };

      # ===== Home Manager Modules =====
      # Phase B: cosmic-identity, firefox-hardened, lifeos-desktop-tray, wake-word
      homeManagerModules = {};
    };
}
