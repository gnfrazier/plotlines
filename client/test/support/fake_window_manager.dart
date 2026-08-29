// Answers the `window_manager` platform channel with sane defaults and
// records what was called, so widgets that drive it — `AppTitleBar`,
// `DesktopWindowFrame` — can be pumped in a widget test with no real desktop
// embedder attached. Install it in `setUp` and tear it down in `tearDown`.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeWindowManager {
  FakeWindowManager() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static const MethodChannel _channel = MethodChannel('window_manager');

  /// Every method name invoked on the channel, in order.
  final List<String> calls = <String>[];

  bool isMaximized = false;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'isMaximized':
        return isMaximized;
      case 'isFocused':
      case 'isMinimized':
      case 'isFullScreen':
      case 'isPreventClose':
        return false;
      case 'maximize':
        isMaximized = true;
        return null;
      case 'unmaximize':
      case 'restore':
        isMaximized = false;
        return null;
      default:
        return null;
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
