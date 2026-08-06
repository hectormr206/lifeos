import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_platform.dart';

/// The operating system the app is actually running on.
///
/// Exists as a provider for one reason: the widget suite runs on a real LINUX
/// host, so a widget that read `Platform.operatingSystem` inline would make
/// every existing test render the DESKTOP shape, and the Android shape — the
/// one on the user's Pixel, with his real data — would go untested forever.
/// Overriding this provider is how a test says "render as Android".
///
/// Production never overrides it; it reports the true host. Pair it with the
/// pure predicates in `app_platform.dart`, which take the OS name as a
/// parameter, rather than branching on this string ad hoc at each call site.
final hostOperatingSystemProvider =
    Provider<String>((ref) => currentOperatingSystem());
