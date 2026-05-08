/* nix/packages/sqlite-vec.nix
 *
 * SQLite vector search extension — C loadable module.
 * Used by lifeosd at runtime via LIFEOS_SQLITE_VEC_PATH env var.
 *
 * NOTE: rusqlite keeps `bundled` feature (REQ-2.2) — sqlite-vec is a
 * SEPARATE runtime-loadable extension, not a link-time dep.
 *
 * Build note: sqlite-vec.h is generated from sqlite-vec.h.tmpl using
 * envsubst + git. In the Nix sandbox (no network, no git), we pre-generate
 * the header in preBuild with known version values.
 *
 * Satisfies: REQ-2.3
 */
{ pkgs, lib, stdenv, fetchFromGitHub, sqlite }:
stdenv.mkDerivation rec {
  pname = "sqlite-vec";
  version = "0.1.6";

  src = fetchFromGitHub {
    owner = "asg017";
    repo = "sqlite-vec";
    rev = "v${version}";
    hash = "sha256-CgeSoRoQRMb/V+RzU5NQuIk/3OonYjAfolWD2hqNuXU=";
  };

  nativeBuildInputs = with pkgs; [ gcc ];

  buildInputs = [ sqlite ];

  # Pre-generate sqlite-vec.h from its template with known version values.
  # The Makefile generates it via `envsubst` + git which are unavailable in
  # the Nix pure sandbox.
  preBuild = ''
    VERSION_MAJOR=0
    VERSION_MINOR=1
    VERSION_PATCH=6
    VERSION="${version}"
    DATE="1970-01-01T00:00:00Z+0000"
    SOURCE="v${version}"
    export VERSION VERSION_MAJOR VERSION_MINOR VERSION_PATCH DATE SOURCE
    ${pkgs.gettext}/bin/envsubst < sqlite-vec.h.tmpl > sqlite-vec.h
  '';

  buildPhase = ''
    runHook preBuild
    make loadable
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    # On Linux: dist/vec0.so
    cp dist/vec0${stdenv.hostPlatform.extensions.sharedLibrary} $out/lib/vec0.so
    runHook postInstall
  '';

  meta = with lib; {
    description = "Vector search SQLite extension — loadable module for lifeosd";
    license = licenses.asl20;
    platforms = platforms.linux;
    homepage = "https://github.com/asg017/sqlite-vec";
  };
}
