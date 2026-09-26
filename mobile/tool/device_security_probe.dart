import 'package:flutter/material.dart';

import 'device_security_probe/probe_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ProbeScreen(),
  ));
}
