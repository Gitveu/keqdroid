sealed class ServerFlag {
  const ServerFlag();
}

final class FlagArt extends ServerFlag {
  final String code;

  const FlagArt(this.code);

  // CountryFlag.fromCountryCode не знает eu, un и ещё десяток кодов из пакета
  // и рисует на них квадрат с вопросом
  String get assetPath => 'packages/country_flags/res/si/$code.si';

  String? get countryCode {
    final base = code.split('-').first;
    return base.length == 2 ? base.toUpperCase() : null;
  }

  @override
  bool operator ==(Object other) => other is FlagArt && other.code == code;

  @override
  int get hashCode => Object.hash(FlagArt, code);

  @override
  String toString() => 'FlagArt($code)';
}

final class FlagGlyph extends ServerFlag {
  final String emoji;

  const FlagGlyph(this.emoji);

  @override
  bool operator ==(Object other) => other is FlagGlyph && other.emoji == emoji;

  @override
  int get hashCode => Object.hash(FlagGlyph, emoji);

  @override
  String toString() => 'FlagGlyph($emoji)';
}

class FlagMatch {
  final ServerFlag flag;
  final int start;
  final int end;

  const FlagMatch(this.flag, this.start, this.end);
}

const _risFirst = 0x1F1E6;
const _risLast = 0x1F1FF;
const _tagBase = 0xE0000;
const _tagFirst = 0xE0020;
const _tagLast = 0xE007E;
const _tagTerm = 0xE007F;
const _flagBlack = 0x1F3F4;
const _flagWhite = 0x1F3F3;
const _zwj = 0x200D;
const _vs16 = 0xFE0F;

const _loneFlags = {0x1F3C1, 0x1F6A9, 0x1F38C};

Iterable<FlagMatch> findFlags(String text) sync* {
  final runes = text.runes.toList(growable: false);
  var i = 0;
  while (i < runes.length) {
    final rune = runes[i];

    if (_isRegionalIndicator(rune)) {
      if (i + 1 < runes.length && _isRegionalIndicator(runes[i + 1])) {
        final code = String.fromCharCodes([
          0x61 + rune - _risFirst,
          0x61 + runes[i + 1] - _risFirst,
        ]);
        yield FlagMatch(_artOrGlyph(code, runes, i, i + 2), i, i + 2);
        i += 2;
        continue;
      }
      i++;
      continue;
    }

    if (rune == _flagBlack || rune == _flagWhite) {
      final tagged = rune == _flagBlack ? _readTags(runes, i) : null;
      if (tagged != null) {
        yield FlagMatch(
          _artOrGlyph(tagged.code, runes, i, tagged.end),
          i,
          tagged.end,
        );
        i = tagged.end;
        continue;
      }
      final end = _endOfZwjSequence(runes, i);
      yield FlagMatch(FlagGlyph(_slice(runes, i, end)), i, end);
      i = end;
      continue;
    }

    if (_loneFlags.contains(rune)) {
      final end = i + 1 < runes.length && runes[i + 1] == _vs16 ? i + 2 : i + 1;
      yield FlagMatch(FlagGlyph(_slice(runes, i, end)), i, end);
      i = end;
      continue;
    }

    i++;
  }
}

ServerFlag? firstFlagIn(String text) {
  for (final match in findFlags(text)) {
    return match.flag;
  }
  return null;
}

String stripFlags(String text) {
  final runes = text.runes.toList(growable: false);
  final drop = List<bool>.filled(runes.length, false);
  var found = false;

  for (final match in findFlags(text)) {
    found = true;
    for (var i = match.start; i < match.end; i++) {
      drop[i] = true;
    }
  }
  for (var i = 0; i < runes.length; i++) {
    if (_isRegionalIndicator(runes[i])) {
      drop[i] = true;
      found = true;
    }
  }
  if (!found) return text;

  final kept = <int>[];
  for (var i = 0; i < runes.length; i++) {
    if (!drop[i]) kept.add(runes[i]);
  }
  return String.fromCharCodes(kept).replaceAll(RegExp(r' {2,}'), ' ');
}

bool _isRegionalIndicator(int rune) => rune >= _risFirst && rune <= _risLast;

String _slice(List<int> runes, int start, int end) =>
    String.fromCharCodes(runes.getRange(start, end));

ServerFlag _artOrGlyph(String code, List<int> runes, int start, int end) =>
    flagArtCodes.contains(code)
    ? FlagArt(code)
    : FlagGlyph(_slice(runes, start, end));

({String code, int end})? _readTags(List<int> runes, int start) {
  final tags = StringBuffer();
  var i = start + 1;
  while (i < runes.length && runes[i] >= _tagFirst && runes[i] <= _tagLast) {
    tags.writeCharCode(runes[i] - _tagBase);
    i++;
  }
  if (tags.isEmpty || i >= runes.length || runes[i] != _tagTerm) return null;
  final raw = tags.toString().toLowerCase();
  return (
    code: raw.length > 2 ? '${raw.substring(0, 2)}-${raw.substring(2)}' : raw,
    end: i + 1,
  );
}

int _endOfZwjSequence(List<int> runes, int start) {
  var i = start + 1;
  if (i < runes.length && runes[i] == _vs16) i++;
  while (i + 1 < runes.length && runes[i] == _zwj) {
    i += 2;
    if (i < runes.length && runes[i] == _vs16) i++;
  }
  return i;
}

final Set<String> flagArtCodes = Set.unmodifiable(_artCodes.split(' '));

const _artCodes =
    'ac ad ae af ag ai al am ao aq ar as at au aw ax az '
    'ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bv bw by bz '
    'ca cc cd cefta cf cg ch ci ck cl cm cn co cp cr cu cv cw cx cy cz '
    'de dg dj dk dm do dz ea ec ee eg eh er es es-ct es-ga et eu '
    'fi fj fk fm fo fr ga gb gb-eng gb-nir gb-sct gb-wls gd ge gf gg gh gi '
    'gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu '
    'ic id ie il im in io iq ir is it je jm jo jp '
    'ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly '
    'ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz '
    'na nc ne nf ng ni nl no np nr nu nz om '
    'pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw '
    'sa sb sc sd se sg sh si sj sk sl sm sn so sr ss st sv sx sy sz '
    'ta tc td tf tg th tj tk tl tm tn to tr tt tv tw tz '
    'ua ug um un us uy uz va vc ve vg vi vn vu wf ws xk xx ye yt za zm zw';
