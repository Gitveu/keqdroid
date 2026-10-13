// голое слово без точки (ru) это суффикс домена: ловит все *.ru без geo-базы

enum RoutingField { direct, proxy, blocked }

class RoutingPreset {
  const RoutingPreset({
    required this.id,
    required this.field,
    required this.values,
    this.unmatched,
  });

  final String id;

  final RoutingField field;

  final List<String> values;

  // через VPN сам по себе ничего не меняет, пока остальное и так идёт в VPN
  final RoutingField? unmatched;
}

class RoutingPresets {
  RoutingPresets._();

  // единственный источник дефолтов: на них ссылаются AppSettings и сброс экрана
  static const String defaultDirectRules = 'ru, yandex.ru, vk.com';
  static const String defaultProxyRules = '';
  static const String defaultBlockedRules = '';

  // category-ru уже несёт зоны ru, su, рф и около тысячи российских сервисов на чужих доменах.
  // geoip:ru не входит намеренно: российскими по адресу выглядят и кэши у провайдера (TikTok через Akamai в Дом.ру)
  static const List<String> russia = ['geosite:category-ru'];

  // этих шести адресов во вшитой category-ads-all нет
  static const List<String> ads = [
    'geosite:category-ads-all',
    'scorecardresearch.com',
    'criteo.com',
    'criteo.net',
    'outbrain.com',
    'rubiconproject.com',
    'adsrvr.org',
  ];

  // Re-filter (1andrevich) домержен в базы через tool/fetch_xray_geo.ps1. оба кода: часть сервисов ходит по IP без домена
  static const List<String> reFilter = [
    'geosite:refilter',
    'geoip:refilter',
  ];

  static const List<RoutingPreset> all = [
    RoutingPreset(
      id: 'ru',
      field: RoutingField.direct,
      values: russia,
    ),
    RoutingPreset(
      id: 'ads',
      field: RoutingField.blocked,
      values: ads,
    ),
    RoutingPreset(
      id: 'refilter',
      field: RoutingField.proxy,
      values: reFilter,
      unmatched: RoutingField.direct,
    ),
  ];

  static String mergeValues(String existing, List<String> additions) {
    final result = <String>[];
    final seen = <String>{};

    void addAll(Iterable<String> items) {
      for (final raw in items) {
        final v = raw.trim();
        if (v.isEmpty) continue;
        final key = v.toLowerCase();
        if (seen.add(key)) result.add(v);
      }
    }

    addAll(existing.split(RegExp(r'[\n,]')));
    addAll(additions);
    return result.join(', ');
  }
}
