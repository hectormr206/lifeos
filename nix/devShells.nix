/* nix/devShells.nix
 *
 * Canonical development shell for LifeOS.
 *
 * Entry: nix develop
 *
 * Provides:
 *   - Rust toolchain (pinned from rust-toolchain.toml via oxalica/rust-overlay)
 *   - cargo, rustc, rust-analyzer, clippy, rustfmt
 *   - crane (available for local nix build testing)
 *   - nixos-rebuild (for switching VM/laptop config)
 *   - nix-tree (dependency visualization)
 *   - attic-client (for manual cache pushes — future T-A4 wiring)
 *   - Build inputs for the Rust workspace (openssl, gtk4, dbus, etc.)
 *
 * This is the CANONICAL workspace shell — not a one-shot experience.
 * All contributors and CI should enter this shell for Rust dev work.
 *
 * Satisfies: PR-A1 devShell requirement
 */
{ pkgs, rustToolchain }:
pkgs.mkShell {
  name = "lifeos-dev";

  buildInputs = with pkgs; [
    # Rust toolchain
    rustToolchain

    # Nix tooling
    nixos-rebuild
    nix-tree

    # Binary cache client (for pushing to attic manually, T-A4)
    attic-client

    # Build dependencies for the Rust workspace
    pkg-config
    cmake
    openssl.dev
    sqlite
    gtk4
    libadwaita
    glib
    dbus

    # Dev tools
    git
    curl
    jq
  ];

  shellHook = ''
    echo "LifeOS dev shell — Rust $(rustc --version)"
    echo "  nix build .#lifeosd    — build the daemon"
    echo "  nix build .#life       — build the CLI"
    echo "  nix flake check        — run all checks + nixos-tests"
    echo "  nixos-rebuild switch   — apply NixOS config"
  '';

  # Needed by rusqlite (bundled sqlite still links against system sqlite headers)
  PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.sqlite.dev}/lib/pkgconfig";
}
