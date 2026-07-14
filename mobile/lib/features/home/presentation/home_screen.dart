import 'package:flutter/material.dart';

/// Minimal foundation home screen (design D1 / M0->M1 bridge).
///
/// Deliberately NOT a chat/domain UI — those land in M1+. This screen only
/// proves the app boots, and is the natural place M1 will wire its first
/// real feature.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LifeOS')),
      body: const Center(
        child: Text('LifeOS mobile is alive.'),
      ),
    );
  }
}
