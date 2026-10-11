import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/utils/geo_dat_reader.dart';
import 'package:keqdroid/utils/routing_presets.dart';

/// Пресеты держатся на кодах geosite: неизвестный код санитайзер выбрасывает
/// молча, и карточка в шторке перестаёт делать хоть что-то. Эта же база едет и
/// в APK, и на десктоп.
void main() {
  final geosite = File('assets/bin/windows/geosite.dat');

  test('каждый geosite-код пресетов есть во вшитой базе', () async {
    final present = await GeoDatReader.codes(geosite);
    final used = {
      for (final preset in RoutingPresets.all)
        for (final v in preset.values)
          if (v.toLowerCase().startsWith('geosite:'))
            v.substring('geosite:'.length).toLowerCase(),
    };
    expect(used.difference(present), isEmpty);
  });

  test('«Российские сайты» по-прежнему берут зоны .ru, .su и .рф', () async {
    // Прежний ручной пресет держался на этих трёх зонах, а «банки» целиком
    // лежали в .ru. Пропади они из category-ru, склейка потеряла бы главное.
    final domains = await GeoDatReader.domains(geosite, 'category-ru');
    final zones = {
      for (final d in domains)
        if (d.type == GeoDomainType.domain) d.value,
    };
    expect(zones, containsAll(['ru', 'su', 'xn--p1ai']));
  });
}
