import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../models/app_settings.dart';
import '../tunnel/desktop_core_paths.dart';
import '../utils/geo_asset_index.dart';
import '../utils/geo_dat_reader.dart';
import '../utils/geo_rule_sanitizer.dart';

class GeoAssetService {
  GeoAssetService._();

  static Future<GeoAssetIndex>? _cached;
  static Future<List<GeoDomain>>? _chinaDns;

  static Future<GeoAssetIndex> index() => _cached ??= _load();

  static void invalidate() {
    _cached = null;
    _chinaDns = null;
  }

  /// Only the CN DNS rule is expanded; routing continues to use geosite.dat.
  /// Missing data must not silently send domestic queries to the other DNS.
  static Future<List<GeoDomain>> chinaDnsDomains() =>
      _chinaDns ??= _loadChinaDnsDomains();

  static Future<List<GeoDomain>> _loadChinaDnsDomains() async {
    final dir = await _geoDir();
    if (dir == null) {
      throw const FormatException('geosite:cn DNS database is unavailable');
    }
    final domains = await GeoDatReader.domains(File('$dir/geosite.dat'), 'cn');
    if (domains.isEmpty) {
      throw const FormatException('geosite:cn DNS data is missing or empty');
    }
    return List.unmodifiable(domains);
  }

  static void resetCacheForTests() => invalidate();

  static Future<GeoAssetIndex> _load() async {
    try {
      final dir = await _geoDir();
      if (dir == null) return GeoAssetIndex.empty;
      final index = await GeoAssetIndex.fromDirectory(dir);
      AppLogger.instance.debug(
        'Geo assets in $dir: ${index.geoipCodes.length} geoip, '
        '${index.geositeCodes.length} geosite codes',
      );
      return index;
    } catch (e) {
      AppLogger.instance.warn('Geo asset index unavailable: $e');
      return GeoAssetIndex.empty;
    }
  }

  static Future<String?> geoDir() => _geoDir();

  static Future<String?> _geoDir() async {
    if (Platform.isAndroid) {
      return (await getApplicationSupportDirectory()).path;
    }
    if (DesktopCorePaths.supported) return DesktopCorePaths.geoAssetDir();
    return null;
  }

  static Future<AppSettings> sanitizeRules(AppSettings settings) async {
    final assets = await index();
    final result = stripUnknownGeoTokens(settings, assets);
    if (result.dropped.isNotEmpty) {
      final trimmedBase = !assets.hasFullGeoip &&
          result.dropped.any((t) => t.toLowerCase().startsWith('geoip:'));
      AppLogger.instance.warn(
        'Routing rules: dropped ${result.dropped.length} geo entries missing '
        'from the bundled geoip/geosite databases (they would abort the core '
        'at config load): ${result.dropped.join(', ')}'
        '${trimmedBase ? ' — the bundled country database is the trimmed one; '
            'download the full base in Settings -> About -> Internals' : ''}',
      );
    }
    return result.settings;
  }

  static Future<bool> hasFullGeoip() async => (await index()).hasFullGeoip;
}
