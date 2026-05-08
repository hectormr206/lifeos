/* nix/packages/sqlite-vec.nix
 *
 * SQLite vector search extension — C loadable module.
 * Used by lifeosd at runtime via LIFEOS_SQLITE_VEC_PATH env var.
 *
 * NOTE: rusqlite keeps `bundled` feature (REQ-2.2) — sqlite-vec is a
 * SEPARATE runtime-loadable extension, not a link-time dep.
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

  # The Makefile uses `git rev-parse HEAD` for COMMIT — override to avoid
  # needing git in the sandbox (pure, reproducible build).
  preBuild = ''
    export COMMIT="v${version}"
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
