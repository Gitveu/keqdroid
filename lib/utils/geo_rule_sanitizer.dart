import '../models/app_settings.dart';
import 'geo_asset_index.dart';

typedef GeoSanitizeResult = ({AppSettings settings, List<String> dropped});

// только для генераторов: сохранённые настройки не трогаем, с другой базой правило может работать
GeoSanitizeResult stripUnknownGeoTokens(
  AppSettings settings,
  GeoAssetIndex index,
) {
  final direct = stripUnknownGeoTokensText(settings.directRules, index);
  final proxy = stripUnknownGeoTokensText(settings.proxyRules, index);
  final blocked = stripUnknownGeoTokensText(settings.blockedRules, index);
  final dropped = [...direct.dropped, ...proxy.dropped, ...blocked.dropped];

  if (dropped.isEmpty) return (settings: settings, dropped: const []);

  return (
    settings: settings.copyWith(
      directRules: direct.text,
      proxyRules: proxy.text,
      blockedRules: blocked.text,
    ),
    dropped: dropped,
  );
}

({String text, List<String> dropped}) stripUnknownGeoTokensText(
  String raw,
  GeoAssetIndex index,
) {
  if (index.isEmpty) return (text: raw, dropped: const []);
  final kept = <String>[];
  final dropped = <String>[];
  for (final token in raw.split(RegExp(r'[\r\n,]+'))) {
    final trimmed = token.trim();
    if (trimmed.isEmpty) continue;
    (isKnownGeoToken(trimmed, index) ? kept : dropped).add(trimmed);
  }
  if (dropped.isEmpty) return (text: raw, dropped: const []);
  return (text: kept.join(', '), dropped: dropped);
}

List<String> unknownGeoTokens(String raw, GeoAssetIndex index) {
  if (index.isEmpty) return const [];
  final seen = <String>{};
  final unknown = <String>[];
  for (final token in raw.split(RegExp(r'[\r\n,]+'))) {
    final trimmed = token.trim();
    if (trimmed.isEmpty) continue;
    if (isKnownGeoToken(trimmed, index)) continue;
    if (seen.add(trimmed.toLowerCase())) unknown.add(trimmed);
  }
  return unknown;
}

bool isKnownGeoToken(String token, GeoAssetIndex index) {
  final lower = token.trim().toLowerCase();
  final isGeoip = lower.startsWith('geoip:');
  final isGeosite = lower.startsWith('geosite:');
  if (!isGeoip && !isGeosite) return true;

  var code = lower.substring(lower.indexOf(':') + 1).trim();
  if (code.startsWith('!')) code = code.substring(1).trim();
  final attr = code.indexOf('@');
  if (attr >= 0) code = code.substring(0, attr).trim();
  if (code.isEmpty) return false;

  final known = isGeoip ? index.geoipCodes : index.geositeCodes;
  // база не прочиталась, не нам решать, что код неверный
  if (known.isEmpty) return true;
  return known.contains(code);
}
