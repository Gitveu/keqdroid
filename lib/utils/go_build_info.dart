import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// своей команды version у ядер может не быть: keqrnel падает на keqrnel version (read config: open version)
class GoBuildInfo {
  const GoBuildInfo({
    required this.goVersion,
    required this.modulePath,
    required this.moduleVersion,
    required this.deps,
    this.settings = const {},
  });

  final String goVersion;

  final String? modulePath;

  final String? moduleVersion;

  final Map<String, String> deps;

  final Map<String, String> settings;

  Set<String> get buildTags {
    final raw = settings['-tags'];
    if (raw == null || raw.trim().isEmpty) return const {};
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  bool get hasBuildSettings => settings.isNotEmpty;

  // мажор Go-модуля живёт в пути (.../v3), /vN отбрасываем с обеих сторон
  String? depVersion(String suffix) {
    final wanted = _withoutMajor(suffix);
    for (final entry in deps.entries) {
      final path = _withoutMajor(entry.key);
      if (path == wanted || path.endsWith('/$wanted')) {
        return entry.value;
      }
    }
    return null;
  }

  bool isModule(String suffix) {
    final path = modulePath;
    if (path == null) return false;
    final wanted = _withoutMajor(suffix);
    final own = _withoutMajor(path);
    return own == wanted || own.endsWith('/$wanted');
  }

  static final _majorSuffix = RegExp(r'/v[2-9]\d*$');

  static String _withoutMajor(String modulePath) =>
      modulePath.replaceFirst(_majorSuffix, '');

  static const magic = <int>[
    0xff, 0x20, 0x47, 0x6f, 0x20, 0x62, 0x75, 0x69, //
    0x6c, 0x64, 0x69, 0x6e, 0x66, 0x3a,
  ];

  static const _flagVersionInline = 0x2;

  static const _headerLength = 32;

  static const _frameLength = 16;

  static GoBuildInfo? parse(Uint8List bytes) {
    if (bytes.length < _headerLength) return null;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return null;
    }
    final flags = bytes[magic.length + 1];
    if (flags & _flagVersionInline == 0) {
      return null;
    }

    final version = _readBytes(bytes, _headerLength);
    if (version == null) return null;

    final modinfo = _readBytes(bytes, version.end);
    if (modinfo == null) return null;

    return _fromModInfo(
      utf8.decode(version.value, allowMalformed: true),
      _stripFrame(modinfo.value),
    );
  }

  static Future<GoBuildInfo?> fromFile(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final length = await handle.length();
      final start = await _findMagic(handle, length);
      if (start == null) return null;
      await handle.setPosition(start);
      final window = await handle.read(
        (length - start).clamp(0, 1 << 20).toInt(),
      );
      return parse(window);
    } catch (_) {
      return null;
    } finally {
      await handle?.close();
    }
  }

  static Future<int?> _findMagic(RandomAccessFile handle, int length) async {
    const chunkSize = 1 << 20;
    final overlap = magic.length - 1;
    var position = 0;
    while (position < length) {
      await handle.setPosition(position);
      final chunk = await handle.read(chunkSize);
      if (chunk.isEmpty) return null;
      final found = _indexOfMagic(chunk);
      if (found >= 0) return position + found;
      if (chunk.length < chunkSize) return null;
      position += chunkSize - overlap;
    }
    return null;
  }

  static int _indexOfMagic(Uint8List haystack) {
    final limit = haystack.length - magic.length;
    outer:
    for (var i = 0; i <= limit; i++) {
      if (haystack[i] != magic[0]) continue;
      for (var j = 1; j < magic.length; j++) {
        if (haystack[i + j] != magic[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static GoBuildInfo _fromModInfo(String goVersion, String modinfo) {
    String? modulePath;
    String? moduleVersion;
    final deps = <String, String>{};
    final settings = <String, String>{};
    for (final line in const LineSplitter().convert(modinfo)) {
      final parts = line.split('\t');
      if (parts.length == 2 && parts[0] == 'build') {
        final eq = parts[1].indexOf('=');
        if (eq > 0) {
          settings[parts[1].substring(0, eq)] = parts[1].substring(eq + 1);
        }
        continue;
      }
      if (parts.length < 3) continue;
      switch (parts[0]) {
        case 'mod':
          modulePath = parts[1];
          moduleVersion = parts[2];
        case 'dep':
          deps[parts[1]] = parts[2];
      }
    }
    return GoBuildInfo(
      goVersion: goVersion,
      modulePath: modulePath,
      moduleVersion: moduleVersion,
      deps: Map.unmodifiable(deps),
      settings: Map.unmodifiable(settings),
    );
  }

  // режем по байтам до декодирования: маркеры не UTF-8, и после allowMalformed длина уже не 16
  static String _stripFrame(Uint8List modinfo) {
    if (modinfo.length < 2 * _frameLength + 1) return '';
    if (modinfo[modinfo.length - _frameLength - 1] != 0x0a) return '';
    return utf8.decode(
      modinfo.sublist(_frameLength, modinfo.length - _frameLength),
      allowMalformed: true,
    );
  }

  static _Slice? _readBytes(Uint8List bytes, int offset) {
    final length = _readUvarint(bytes, offset);
    if (length == null) return null;
    final start = length.end;
    final end = start + length.value;
    if (end > bytes.length) return null;
    return _Slice(bytes.sublist(start, end), end);
  }

  static _Uvarint? _readUvarint(Uint8List bytes, int offset) {
    var value = 0;
    var shift = 0;
    var index = offset;
    while (index < bytes.length) {
      final byte = bytes[index++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return _Uvarint(value, index);
      shift += 7;
      if (shift > 35) return null;
    }
    return null;
  }
}

class _Slice {
  const _Slice(this.value, this.end);
  final Uint8List value;
  final int end;
}

class _Uvarint {
  const _Uvarint(this.value, this.end);
  final int value;
  final int end;
}
