import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Invisible macOS test windows can enter App Nap while awaiting native events.
/// Keep device checks running even when Flutter cannot foreground their window.
Future<void> holdTestProcessActivity() async {
  if (!Platform.isMacOS) return;
  const channel = MethodChannel('relay_reader/supertonic3');
  await channel.invokeMethod<void>('beginBenchmark');
  addTearDown(() => channel.invokeMethod<void>('endBenchmark'));
}
