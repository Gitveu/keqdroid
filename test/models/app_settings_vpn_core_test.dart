import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';

/// До 15.10.2026 в выборе ядра был пункт «Автоматически» (`auto`). Ядро он
/// выбирал то же, что xray, и был убран; сохранённое `auto` читается как xray.
void main() {
  test('по умолчанию auto', () {
    expect(const AppSettings().vpnCore, AppSettings.vpnCoreAuto);
  });

  test('сохранённое auto остаётся auto', () {
    expect(
      AppSettings.fromJson(const {'vpnCore': 'auto'}).vpnCore,
      AppSettings.vpnCoreAuto,
    );
  });

  test('выбранный mihomo остаётся mihomo', () {
    expect(
      AppSettings.fromJson(const {'vpnCore': 'mihomo'}).vpnCore,
      AppSettings.vpnCoreMihomo,
    );
  });

  test('выбранный xray остаётся xray', () {
    expect(
      AppSettings.fromJson(const {'vpnCore': 'xray'}).vpnCore,
      AppSettings.vpnCoreXray,
    );
  });
}
