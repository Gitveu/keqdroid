import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/services/settings_backup_service.dart';

// защита адреса сервера выходит выключенной: у обновившихся и из старого бэкапа тоже,
// включает её только человек
void main() {
  test('по умолчанию выключена', () {
    expect(const AppSettings().protectServerAddress, isFalse);
  });

  test('настройки до появления ключа читаются выключенными', () {
    expect(
      AppSettings.fromJson(const {'fakeIp': true}).protectServerAddress,
      isFalse,
    );
  });

  test('включённая переживает сохранение', () {
    final json = const AppSettings(protectServerAddress: true).toJson();
    expect(AppSettings.fromJson(json).protectServerAddress, isTrue);
  });

  test('уезжает в бэкап настроек', () {
    expect(
      SettingsBackupService.portableSettingKeys,
      contains('protectServerAddress'),
    );
  });
}
