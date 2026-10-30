import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

/// Executable живут в проверенном bundle; не распаковываем их в общий /tmp
/// и не подхватываем одноимённые программы из PATH.
class MacOSCorePaths {
  MacOSCorePaths._();

  static const binariesHint =
      'Install the complete macOS package. Its application bundle must contain keqrnel and mihomo.';
  static const installedRuntime =
      '/Library/Application Support/com.keqdroid.keqdroid';

  static List<String> get _arches =>
      Abi.current() == Abi.macosArm64 ? const ['arm64', 'x64'] : const ['x64', 'arm64'];

  /// Both installed session cores and ordinary-user measurement cores bypass
  /// the TUN. Full paths avoid exempting an unrelated process with the same name.
  static List<String> get bypassExecutablePaths {
    final paths = <String>{
      Platform.resolvedExecutable,
      for (final name in ['keqrnel', 'mihomo']) ...[
        p.join(installedRuntime, 'bin', name),
        p.join(coresDirectory(), name),
      ],
    };
    final execFile = File(Platform.resolvedExecutable);
    var searchDir = execFile.parent;
    for (var i = 0; i < 10; i++) {
      for (final arch in _arches) {
        for (final name in ['keqrnel', 'mihomo']) {
          final pth = p.join(searchDir.path, 'build', 'macos-cores', arch, name);
          if (File(pth).existsSync()) paths.add(pth);
        }
      }
      if (searchDir.parent.path == searchDir.path) break;
      searchDir = searchDir.parent;
    }
    return paths.toList();
  }

  static String bundleContents({String? executablePath}) =>
      p.dirname(p.dirname(executablePath ?? Platform.resolvedExecutable));

  static String coresDirectory({String? executablePath}) => p.join(
    bundleContents(executablePath: executablePath),
    'Resources',
    'cores',
  );

  static Future<String?> executable(
    String name, {
    String? executablePath,
  }) async {
    if (!const {'keqrnel', 'mihomo', 'xray'}.contains(name)) {
      throw ArgumentError.value(name, 'name', 'Unknown bundled core');
    }
    final bundlePath = p.join(coresDirectory(executablePath: executablePath), name);
    if (await File(bundlePath).exists()) return bundlePath;
    final installedPath = p.join(installedRuntime, 'bin', name);
    if (await File(installedPath).exists()) return installedPath;

    // Search relative to executable (e.g. running from build/macos/Build/Products/...)
    final execFile = File(executablePath ?? Platform.resolvedExecutable);
    var searchDir = execFile.parent;
    for (var i = 0; i < 10; i++) {
      for (final arch in _arches) {
        final devPath = p.join(searchDir.path, 'build', 'macos-cores', arch, name);
        if (await File(devPath).exists()) return devPath;
      }
      if (searchDir.parent.path == searchDir.path) break;
      searchDir = searchDir.parent;
    }

    // Search relative to working directory (e.g. running from terminal or inside tool/)
    var workDir = Directory.current;
    for (var i = 0; i < 6; i++) {
      for (final arch in _arches) {
        final devPath = p.join(workDir.path, 'build', 'macos-cores', arch, name);
        if (await File(devPath).exists()) return devPath;
      }
      if (workDir.parent.path == workDir.path) break;
      workDir = workDir.parent;
    }

    return null;
  }

  static Future<String?> keqrnelExecutable() => executable('keqrnel');
  static Future<String?> xrayExecutable() async =>
      await executable('keqrnel') ?? await executable('xray');
  static Future<String?> mihomoExecutable() => executable('mihomo');

  static Future<Directory> sessionDir() async {
    final dir = await Directory.systemTemp.createTemp('keqdroid_macos_');
    final result = await Process.run('/bin/chmod', ['0700', dir.path]);
    if (result.exitCode != 0) {
      await dir.delete();
      throw const FileSystemException(
        'Could not protect the core session directory.',
      );
    }
    return dir;
  }

  static Future<String?> geoAssetDir() async {
    final resources = p.join(bundleContents(), 'Resources');
    for (final directory in [
      p.join(resources, 'geo'),
      p.join(resources, 'cores'),
      p.join(installedRuntime, 'geo'),
    ]) {
      if (await File(p.join(directory, 'geoip.dat')).exists() ||
          await File(p.join(directory, 'geosite.dat')).exists()) {
        return directory;
      }
    }

    // Search relative to executable
    final execFile = File(Platform.resolvedExecutable);
    var searchDir = execFile.parent;
    for (var i = 0; i < 10; i++) {
      final geoDir = p.join(searchDir.path, 'assets', 'bin', 'linux');
      if (await File(p.join(geoDir, 'geoip.dat')).exists() ||
          await File(p.join(geoDir, 'geosite.dat')).exists()) {
        return geoDir;
      }
      if (searchDir.parent.path == searchDir.path) break;
      searchDir = searchDir.parent;
    }

    // Search relative to working directory
    var workDir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final geoDir = p.join(workDir.path, 'assets', 'bin', 'linux');
      if (await File(p.join(geoDir, 'geoip.dat')).exists() ||
          await File(p.join(geoDir, 'geosite.dat')).exists()) {
        return geoDir;
      }
      if (workDir.parent.path == workDir.path) break;
      workDir = workDir.parent;
    }

    return null;
  }
}
