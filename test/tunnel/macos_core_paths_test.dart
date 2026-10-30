import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/services/app_internals_service.dart';
import 'package:keqdroid/tunnel/macos_core_paths.dart';

void main() {
  test('MacOSCorePaths finds verified cores and geo assets on macOS', () async {
    if (!Platform.isMacOS) return;

    final keqrnel = await MacOSCorePaths.keqrnelExecutable();
    final mihomo = await MacOSCorePaths.mihomoExecutable();
    final geo = await MacOSCorePaths.geoAssetDir();

    expect(keqrnel, isNotNull);
    expect(File(keqrnel!).existsSync(), isTrue);

    expect(mihomo, isNotNull);
    expect(File(mihomo!).existsSync(), isTrue);

    expect(geo, isNotNull);
    expect(Directory(geo!).existsSync(), isTrue);

    final internals = await AppInternalsService.collect(
      settings: const AppSettings(),
      state: null,
    );

    expect(internals.cores.length, equals(2));
    final coreNames = internals.cores.map((c) => c.name).toList();
    expect(coreNames, anyOf(contains('xray'), contains('keqrnel')));
    expect(coreNames, contains('mihomo'));

    for (final core in internals.cores) {
      expect(core.missing, isFalse, reason: '${core.name} should be found');
      expect(core.path, isNotNull);
      expect(core.sizeBytes, isNotNull);
      expect(core.sizeBytes!, greaterThan(10 * 1024 * 1024));
    }
  });
}
