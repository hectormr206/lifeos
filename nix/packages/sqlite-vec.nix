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
    hash = "sha256-KcYzPWumP7Ai2Ft6hHT6OIUWZ+OQ9Q5fOB+Y9bBIpE=";
  };

  nativeBuildInputs = [ sqlite ];

  buildPhase = ''
    runHook preBuild
    make loadable
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    # The extension uses the platform's shared library extension (.so on Linux)
    cp dist/vec0${stdenv.hostPlatform.extensions.sharedLibrary} $out/lib/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Vector search SQLite extension — loadable module for lifeosd";
    license = licenses.asl20;
    platforms = platforms.linux;
    homepage = "https://github.com/asg017/sqlite-vec";
  };
}
