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
 * Note on cargoArtifacts: crates that generate code in $OUT_DIR via build
 * scripts and then reference those absolute paths (e.g. RustEmbed with
 * #[folder = "..."]) cannot safely reuse cargoArtifacts across different
 * Nix sandbox instances. mkBinFresh bypasses cargoArtifacts for those crates.
 *
 * Note on doCheck: cargo tests require test fixtures that are not committed
 * to the repo (e.g. daemon/tests/security/agentic_red_team_corpus.json).
 * The unit tests run in CI (not Nix sandbox). Set doCheck = false globally.
 *
 * Satisfies: REQ-2.1, REQ-2.2
 */
{ pkgs, crane }:
let
  # crane parameter is already the result of crane.mkLib pkgs (called from flake.nix).
  # Override the toolchain with the pinned channel from rust-toolchain.toml so
  # the entire workspace compiles with the exact same rustc as cargo.
  rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ../../rust-toolchain.toml;
  craneLib = crane.overrideToolchain rustToolchain;

  # Single source filter covering the entire workspace.
  # Excludes: docs/, image/, containers/, nix/, lifeos-site/, target/.
  # Includes: Cargo.{toml,lock}, src/**, build.rs, and all embedded resources.
  src = pkgs.lib.cleanSourceWith {
    src = ../..;  # repo root (two levels up from nix/lib/)
    filter = path: type:
      let
        rel = pkgs.lib.removePrefix (toString ../.. + "/") (toString path);
      in
        (craneLib.filterCargoSources path type)
        # daemon embedded static assets
        || (pkgs.lib.hasPrefix "daemon/defaults/" rel)
        || (pkgs.lib.hasPrefix "daemon/static/" rel)
        # cli embedded assets (model catalog)
        || (pkgs.lib.hasPrefix "cli/assets/" rel)
        # desktop embedded assets
        || (pkgs.lib.hasPrefix "desktop/src/" rel)
        # contracts: model catalog JSON + sig (embedded via include_str!)
        || (pkgs.lib.hasPrefix "contracts/" rel);
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

    # Unit tests require fixtures not present in the Nix source (e.g.,
    # daemon/tests/security/agentic_red_team_corpus.json) — CI runs those.
    doCheck = false;

    nativeBuildInputs = with pkgs; [
      pkg-config
      cmake
    ];

    buildInputs = with pkgs; [
      openssl.dev
      sqlite
      gtk4
      libadwaita
      glib
      dbus
    ];
  };

  # ONE cargoArtifacts — built once per Cargo.lock revision, shared by all binaries.
  # Provides pre-compiled dependency crates to speed up per-binary builds.
  # Only usable for binaries whose deps do NOT embed absolute $OUT_DIR paths.
  cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
    cargoExtraArgs = "--workspace --features messaging,ui-overlay,wake-word,dbus,http-api";
  });

  # mkBin: factory for per-binary crane derivations WITH shared cargoArtifacts.
  # Use for binaries that do not pull in RustEmbed/OUT_DIR-absolute-path crates.
  mkBin = { pname, cargoExtraArgs ? "-p ${pname}", extraBuildInputs ? [], meta ? {} }:
    craneLib.buildPackage (commonArgs // {
      inherit pname cargoArtifacts cargoExtraArgs meta;
      buildInputs = commonArgs.buildInputs ++ extraBuildInputs;
    });

  # mkBinFresh: builds without cargoArtifacts reuse.
  # Required for binaries that transitively depend on crates using RustEmbed
  # with #[folder = "$OUT_DIR/..."] — those crates embed absolute sandbox paths
  # that cannot be carried over from a different buildDepsOnly sandbox.
  # Trade-off: deps are recompiled each time Cargo.lock changes (slower CI).
  # lifeosd uses utoipa-swagger-ui which has this property.
  mkBinFresh = { pname, cargoExtraArgs ? "-p ${pname}", extraBuildInputs ? [], meta ? {} }:
    craneLib.buildPackage (commonArgs // {
      inherit pname cargoExtraArgs meta;
      buildInputs = commonArgs.buildInputs ++ extraBuildInputs;
    });
in
{
  inherit craneLib commonArgs cargoArtifacts mkBin mkBinFresh;
}
