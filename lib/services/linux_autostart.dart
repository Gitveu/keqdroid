import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import 'linux_appimage_updater.dart';
import 'linux_desktop_entry.dart';

class LinuxAutostart {
  LinuxAutostart._();

  static const flag = '--autostart';
  static const _fileName = 'keqdroid.desktop';

  static const _marker = 'X-KeqDroid-Autostart=true';

  static File _file() {
    final home = Platform.environment['HOME'] ?? '';
    final config =
        Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
    return File(p.join(config, 'autostart', _fileName));
  }

  // сам AppImage: бинарь во временном монте исчезает вместе с процессом
  static String _target() =>
      LinuxAppImageUpdater.currentAppImagePath() ?? Platform.resolvedExecutable;

  static bool isEnabled() {
    try {
      final file = _file();
      return file.existsSync() && file.readAsStringSync().contains(_marker);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> setEnabled(bool enabled) async {
    try {
      final file = _file();
      if (!enabled) {
        if (isEnabled()) await file.delete();
        return true;
      }
      if (file.existsSync() && !isEnabled()) return false;
      await file.parent.create(recursive: true);
      await file.writeAsString(contentFor(_target()));
      return true;
    } catch (e, st) {
      AppLogger.instance.warn(
        'Could not change Linux autostart',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  static Future<void> refresh() async {
    if (!isEnabled()) return;
    final content = contentFor(_target());
    try {
      if (await _file().readAsString() != content) {
        await _file().writeAsString(content);
      }
    } catch (_) {}
  }

  // раннер аргументы в Dart не передаёт, читаем /proc/self/cmdline
  static bool launchedAtLogin() {
    try {
      final raw = File('/proc/self/cmdline').readAsStringSync();
      return raw.split('\u0000').contains(flag);
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static String contentFor(String target) => [
        '[Desktop Entry]',
        'Type=Application',
        'Name=KeqDroid',
        'Exec=${LinuxDesktopEntry.execArgument(target)} $flag',
        'Icon=keqdroid',
        'Terminal=false',
        'X-GNOME-Autostart-enabled=true',
        _marker,
        '',
      ].join('\n');
}
