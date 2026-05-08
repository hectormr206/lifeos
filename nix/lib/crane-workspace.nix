/* nix/lib/crane-workspace.nix
 *
 * Shared crane workspace setup for all LifeOS Rust binaries.
 *
 * Key property: ONE cargoArtifacts derivation shared across all 4 binaries.
 * A Cargo.lock change invalidates only cargoArtifacts, NOT source builds.
 * A Rust source change invalidates ONLY the affected binary derivation.
 *
 * Feature flags: messaging, ui-overlay, wake-word, dbus, http-api
 * (per feedback_ci_features.md)
 *
 * Satisfies: REQ-2.1, REQ-2.2
 */
{ pkgs, crane }:
let
  craneLib = crane.mkLib pkgs;

  # Single source filter covering the entire workspace.
  # Excludes: docs/, image/, containers/, nix/, lifeos-site/, target/.
  # Includes: Cargo.{toml,lock}, src/**, build.rs, embedded resources.
  src = pkgs.lib.cleanSourceWith {
    src = ../..;  # repo root (two levels up from nix/lib/)
    filter = path: type:
      let
        rel = pkgs.lib.removePrefix (toString ../.. + "/") (toString path);
      in
        (craneLib.filterCargoSources path type)
        || (pkgs.lib.hasPrefix "daemon/defaults/" rel)
        || (pkgs.lib.hasPrefix "daemon/static/" rel)
        || (pkgs.lib.hasPrefix "cli/assets/" rel)
        || (pkgs.lib.hasPrefix "desktop/src/" rel);
    name = "lifeos-workspace";
  };

  # Common build arguments shared by every derivation.
  commonArgs = {
    inherit src;
    strictDeps = true;

    # Workspace-level pname for cargoArtifacts.
    # Per-binary derivations override pname.
    pname = "lifeos-workspace";
    version = "0.0.0";

    nativeBuildInputs = with pkgs; [
      pkg-config
      cmake
      rustPackages.rustc
    ];

    buildInputs = with pkgs; [
      openssl.dev
      sqlite
      gtk4
      libadwaita
      glib
      dbus
    ];

    # Runtime toolchain override: use the pinned channel from rust-toolchain.toml
    RUST_TOOLCHAIN = pkgs.rust-bin.fromRustupToolchainFile ../../rust-toolchain.toml;
  };

  # ONE cargoArtifacts — built once per Cargo.lock revision, shared by all binaries.
  # The workspace-level features bake in ALL feature-conditional dep paths so they
  # are not recompiled per binary.
  cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
    cargoExtraArgs = "--workspace --features messaging,ui-overlay,wake-word,dbus,http-api";
  });

  # mkBin: factory for per-binary crane derivations.
  # All binaries share cargoArtifacts — only source compiles happen per derivation.
  mkBin = { pname, cargoExtraArgs ? "-p ${pname}", extraBuildInputs ? [], meta ? {} }:
    craneLib.buildPackage (commonArgs // {
      inherit pname cargoArtifacts cargoExtraArgs meta;
      buildInputs = commonArgs.buildInputs ++ extraBuildInputs;
    });
in
{
  inherit craneLib commonArgs cargoArtifacts mkBin;
}
