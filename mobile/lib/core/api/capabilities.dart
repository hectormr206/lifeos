/// Domain model for `GET /api/v1/capabilities` (design D4).
///
/// The OpenAPI contract (`contracts/openapi/axi-v1.json`) declares this
/// endpoint's response as a generic `additionalProperties: true` object —
/// FastAPI returns a plain dict, not a typed Pydantic response model — so the
/// generated dart-dio client hands back an untyped `Map<String, Object>`
/// (see `axi_api_client`'s `DefaultApi.capabilitiesApiV1CapabilitiesGet`).
/// This file is the hand-written typed layer ON TOP of that generated call,
/// informed by design D4's documented JSON shape, not a replacement for
/// generation of the endpoint call itself.
///
/// D4 versioning rule: "integer `v` per capability object; additive fields
/// never bump `v`; ... client degrades per-capability (hides UI)". That is
/// why [CapabilityEntry] only hand-declares `v` and keeps every other field
/// as an untyped `extra` map rather than declaring `features`/`list`/`wire`/
/// `class` etc. as fixed properties — those are per-domain, additive, and
/// out of scope for this foundation milestone.
class Capabilities {
  const Capabilities({
    required this.apiVersion,
    required this.engineVersion,
    required this.capabilities,
  });

  final String apiVersion;
  final String engineVersion;
  final Map<String, CapabilityEntry> capabilities;

  factory Capabilities.fromJson(Map<String, Object?> json) {
    final rawCapabilities = (json['capabilities'] as Map?) ?? const {};
    return Capabilities(
      apiVersion: json['api_version'] as String,
      engineVersion: json['engine_version'] as String,
      capabilities: rawCapabilities.map(
        (key, value) => MapEntry(
          key as String,
          CapabilityEntry.fromJson(Map<String, Object?>.from(value as Map)),
        ),
      ),
    );
  }
}

/// One entry under `capabilities.<name>`, e.g. `capabilities.chat`.
///
/// [v] is the only field this foundation milestone treats as structured;
/// everything else (`features`, `list`, `wire`, `class`, ...) is preserved
/// verbatim in [extra] so per-domain UI code (added in later milestones) can
/// read what it needs without a model change here.
class CapabilityEntry {
  const CapabilityEntry({required this.v, required this.extra});

  final int v;
  final Map<String, Object?> extra;

  factory CapabilityEntry.fromJson(Map<String, Object?> json) {
    final rest = Map<String, Object?>.from(json)..remove('v');
    return CapabilityEntry(v: json['v'] as int, extra: rest);
  }
}
