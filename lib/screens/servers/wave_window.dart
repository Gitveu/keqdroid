library;

const double kWaveRunningWindowFraction = 0.4;

(double, double) waveRunningWindow(double progress) {
  final travel = (progress * 2) % 2;
  final position = travel <= 1 ? travel : 2 - travel;
  final start =
      (1 + kWaveRunningWindowFraction) * position - kWaveRunningWindowFraction;
  return (
    start.clamp(0.0, 1.0),
    (start + kWaveRunningWindowFraction).clamp(0.0, 1.0),
  );
}

(double, double) waveExpandedWindow((double, double) from, double t) {
  double lerp(double a, double b) => a + (b - a) * t;
  return (
    lerp(from.$1, 0).clamp(0.0, 1.0),
    lerp(from.$2, 1).clamp(0.0, 1.0),
  );
}
