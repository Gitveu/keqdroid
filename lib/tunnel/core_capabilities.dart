import 'dart:io';

import '../utils/go_build_info.dart';

// без with_gvisor стек gvisor и mixed роняет старт ядра (gVisor is not included in this build)
class CoreCapabilities {
  CoreCapabilities._();

  // храним сам Future: подключение посреди прогрева дождётся того же чтения
  static final _cache = <String, Future<bool?>>{};

  static void resetCacheForTests() => _cache.clear();

  // null не значит нет, по нему ничего не переписываем
  static Future<bool?> hasGvisor(String? binaryPath) {
    final path = binaryPath;
    if (path == null || path.isEmpty) return Future.value();
    return _cache[path] ??= _probe(path);
  }

  static Future<void> warmUp(Future<String?> binaryPath) async {
    try {
      await hasGvisor(await binaryPath);
    } catch (_) {}
  }

  static Future<bool?> _probe(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final info = await GoBuildInfo.fromFile(file);
      if (info == null || !info.hasBuildSettings) return null;
      return info.buildTags.contains('with_gvisor');
    } catch (_) {
      return null;
    }
  }
}
