class PingSample {
  const PingSample({required this.at, required this.ms, required this.type});

  static const keep = 5;

  static const latencyTypes = {'tcp', 'url', 'icmp'};

  static List<PingSample> append(List<PingSample> history, PingSample next) {
    final out = [...history, next];
    return out.length > keep ? out.sublist(out.length - keep) : out;
  }

  final DateTime at;

  final int? ms;

  final String type;

  List<Object?> toJson() => [at.millisecondsSinceEpoch ~/ 1000, ms, type];

  static PingSample? fromJson(Object? raw) {
    if (raw is! List || raw.length != 3) return null;
    final seconds = raw[0];
    final ms = raw[1];
    final type = raw[2];
    if (seconds is! int || (ms != null && ms is! int) || type is! String) {
      return null;
    }
    return PingSample(
      at: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      ms: ms as int?,
      type: type,
    );
  }
}
