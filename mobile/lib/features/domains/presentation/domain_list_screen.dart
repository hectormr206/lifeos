import 'package:flutter/material.dart';

import '../domain/domain_descriptor.dart';
import 'local_domain_tab.dart';

/// A domain's screen: create, edit, delete and filter structured entries in
/// the on-device encrypted graph.
///
/// There used to be a second tab, "Desde el motor Axi", showing the same kind
/// of data living on a paired server. That design is gone. The plan was to run
/// a bigger model on a powerful machine and share it; today every device runs
/// its own local model and the graph syncs the results, so the engine tab had
/// nothing behind it and could only report a connection error.
///
/// Still ONE widget class instantiated per [DomainDescriptor] — every
/// per-domain difference lives in data/config, never in widget code.
class DomainListScreen extends StatelessWidget {
  const DomainListScreen({required this.descriptor, super.key});

  final DomainDescriptor descriptor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(descriptor.title)),
      body: LocalDomainTab(descriptor: descriptor),
    );
  }
}
