#!/usr/bin/env bash
# Regenerates mobile/packages/axi_api_client from the committed OpenAPI
# contract (contracts/openapi/axi-v1.json).
#
# Design D3 (sdd/mobile-app): the Dart API client is generated FROM the
# OpenAPI export, never hand-written. This script is the one supported way
# to (re)produce packages/axi_api_client — do not hand-edit files under that
# directory; they are marked "AUTO-GENERATED FILE, DO NOT MODIFY!" by the
# generator itself and will be overwritten on the next run.
#
# Usage: mobile/tool/gen-api.sh
# Requires: npx (Node/npm), a JVM (openapi-generator-cli runs on the JVM),
# and the Dart SDK (ships with Flutter) on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$MOBILE_DIR")"
SPEC="$REPO_ROOT/contracts/openapi/axi-v1.json"
OUT_DIR="$MOBILE_DIR/packages/axi_api_client"

if [[ ! -f "$SPEC" ]]; then
  echo "error: contract not found at $SPEC" >&2
  echo "       run 'axi-openapi-export' (or 'python -m axi.openapi_export') in axi/ first." >&2
  exit 1
fi

# KNOWN GENERATOR LIMITATION: openapi-generator's dart-dio templates emit a
# broken empty class (missing constructor params, malformed ==/hashCode) for
# inline `anyOf`-of-scalar schemas. The only place that pattern appears in
# this contract is FastAPI's standard 422 diagnostic field
# `ValidationError.loc` (`anyOf: [string, integer]`, i.e. a JSON-pointer-like
# path such as ["body","code"]). This does NOT affect the pair/capabilities
# success-path payloads that matter for parity. Work around it by generating
# from a throwaway copy of the spec with that one field flattened to
# `type: string` — the COMMITTED contract at $SPEC is never modified.
GEN_SPEC="$(mktemp -t axi-v1-gen-XXXXXX.json)"
trap 'rm -f "$GEN_SPEC"' EXIT
jq '.components.schemas.ValidationError.properties.loc.items = {"type": "string"}' "$SPEC" > "$GEN_SPEC"

echo "==> generating dart-dio client from ${SPEC#"$REPO_ROOT"/} (loc.items flattened for the dart-dio anyOf-of-scalars generator bug, see comment above)"
npx --yes @openapitools/openapi-generator-cli generate \
  -i "$GEN_SPEC" \
  -g dart-dio \
  -o "$OUT_DIR" \
  --additional-properties="pubName=axi_api_client,pubLibrary=axi_api_client,pubDescription=GeneratedAxiV1ApiClient-DoNotHandEdit,serializationLibrary=json_serializable"

echo "==> patching generated pubspec.yaml SDK floor (generator emits >=3.5.0, too old for the"
echo "    null-aware-elements syntax the resolved json_serializable version emits)"
sd "sdk: '>=3.5.0 <4.0.0'" "sdk: '>=3.9.0 <4.0.0'" "$OUT_DIR/pubspec.yaml"

echo "==> dart pub get (generated package)"
(cd "$OUT_DIR" && dart pub get)

echo "==> build_runner (json_serializable + copy_with codegen)"
(cd "$OUT_DIR" && dart run build_runner build --delete-conflicting-outputs)

echo "==> done. Review the diff under $OUT_DIR, then commit it alongside the contract."
