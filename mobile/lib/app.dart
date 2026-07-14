import 'package:flutter/material.dart';

import 'features/home/presentation/home_screen.dart';

/// Root widget (design D1 foundation). Wrapped in a [ProviderScope] by
/// [main] — this widget itself stays framework-agnostic so widget tests can
/// pump it directly inside their own [ProviderScope].
class LifeOSApp extends StatelessWidget {
  const LifeOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LifeOS',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const HomeScreen(),
    );
  }
}
