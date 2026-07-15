import 'package:dio/dio.dart';

import 'tls_trust_decision.dart';

/// Web: TLS trust is entirely browser-managed. `dart:io`'s
/// `SecurityContext`/`HttpClient.badCertificateCallback` do not exist in a
/// web build — Dio's browser adapter runs over the platform `fetch`/XHR
/// stack, which only ever trusts certificates the OS/browser's own trust
/// store already trusts. A self-signed engine is therefore unreachable from
/// a web build of this app unless the user has separately installed the CA
/// into their OS/browser trust store — this app has no API surface to pin a
/// certificate on web at all.
///
/// Always returns `null`: never override Dio's default browser adapter.
/// [decision] is intentionally unused — there is nothing this platform can
/// do with a pinned CA or a self-signed-trust toggle.
// ignore: avoid_unused_parameters
HttpClientAdapter? buildTlsAdapter(TlsTrustDecision decision) => null;
