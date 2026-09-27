import 'dart:io';

// The standalone AOT probe compiles without pub get or a package config.
// ignore: avoid_relative_lib_imports
import '../../lib/features/app_update/domain/update_source_config.dart';

void main() {
  final config = const UpdateSourceConfig.fromEnvironment();
  final expectedUrl = const String.fromEnvironment('UPDATE_BASE_URL');
  final expectedKey = const String.fromEnvironment('UPDATE_ACCESS_KEY');
  if (expectedUrl.isEmpty ||
      expectedKey.isEmpty ||
      config.baseUrl != expectedUrl ||
      config.accessKey != expectedKey ||
      !config.isConfigured ||
      !config.baseUrl.startsWith('https://')) {
    throw StateError('OTA configuration probe failed');
  }
  stdout.writeln('OTA_CONFIG_OK');
}
