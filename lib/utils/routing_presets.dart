// routing presets for the routing settings screen.
// three mixed lists in AppSettings drive routing: directRules bypasses the vpn,
// proxyRules forces traffic through it, blockedRules gets dropped. each list may
// hold domains, ip/cidr ranges and prefixed rules; the config generators split
// them. a bare token without a dot (e.g. `ru`) is treated as a domain suffix, so
// it matches every *.ru host without shipping a geosite/geoip db.

/// which of the three routing lists a preset writes into.
enum RoutingField { direct, proxy, blocked }

/// one-tap preset that appends values into a target list.
class RoutingPreset {
  const RoutingPreset({
    required this.id,
    required this.field,
    required this.values,
    this.unmatched,
  });

  /// stable id, also used to look up the localized label/description.
  final String id;

  /// Which routing list this preset contributes to.
  final RoutingField field;

  /// Values to merge into the target list.
  final List<String> values;

  /// Куда пресет заодно ставит «Остальной трафик»; null — не трогает. Список
  /// «через VPN» сам по себе ничего не меняет, пока остальное и так идёт в VPN.
  final RoutingField? unmatched;
}

/// all presets offered in the routing screen, in display order.
class RoutingPresets {
  RoutingPresets._();

  // single source of truth for the routing baseline: AppSettings' constructor
  // defaults reference these, and the routing screen's reset writes them back.
  static const String defaultDirectRules = 'ru, yandex.ru, vk.com';
  static const String defaultProxyRules = '';
  static const String defaultBlockedRules = '';

  /// Российские сайты по базе GeoSite: `category-ru` уже несёт зоны ru, su, рф
  /// и около тысячи российских сервисов на чужих доменах, так что прежние ручные
  /// списки «сайты РФ» и «банки» были её подмножеством. geoip:ru сюда не входит
  /// намеренно: по адресу российскими выглядят и зарубежные сервисы с кэшем у
  /// провайдера (TikTok через Akamai в сети Дом.ру). Кому нужно, добавит его
  /// глобусом в строке.
  static const List<String> russia = ['geosite:category-ru'];

  /// Реклама и трекеры. Во вшитой category-ads-all нет этих шести адресов из
  /// прежнего ручного списка, остальные в ней уже есть.
  static const List<String> ads = [
    'geosite:category-ads-all',
    'scorecardresearch.com',
    'criteo.com',
    'criteo.net',
    'outbrain.com',
    'rubiconproject.com',
    'adsrvr.org',
  ];

  /// Re-filter: домены и IP, заблокированные в РФ (1andrevich/Re-filter-lists,
  /// домержено в поставляемые базы через tool/fetch_xray_geo.ps1). Оба кода
  /// вместе: часть сервисов ходит по IP без домена. Отдельные пресеты стриминга,
  /// мессенджеров и Telegram убраны: заблокированное из них здесь уже есть.
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

  /// merge additions into a comma/newline list, keeping order and skipping
  /// case-insensitive dupes. returns a clean comma-separated string.
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
