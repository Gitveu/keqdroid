part of '../servers_tab.dart';

class _WavePaintWidget extends ConsumerStatefulWidget {
  final AnimationController waveCtrl;
  final AnimationController stateCtrl;
  final double height;

  const _WavePaintWidget({
    required this.waveCtrl,
    required this.stateCtrl,
    this.height = 36,
  });

  @override
  ConsumerState<_WavePaintWidget> createState() => _WavePaintWidgetState();
}

class _WavePaintWidgetState extends ConsumerState<_WavePaintWidget>
    with SingleTickerProviderStateMixin {
  double _amp = 0;

  late final AnimationController _settleCtrl = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  (double, double) _settleFrom = (0, 1);

  @override
  void dispose() {
    _settleCtrl.dispose();
    super.dispose();
  }

  static bool _isRunning(VpnStatus? status) =>
      status == VpnStatus.connecting || status == VpnStatus.disconnecting;

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final waveCtrl = widget.waveCtrl;
    final stateCtrl = widget.stateCtrl;
    final height = widget.height;

    ref.listen<VpnStatus?>(
      vpnStateProvider.select((s) => s.value?.status),
      (prev, next) {
        final was = _isRunning(prev);
        final now = _isRunning(next);
        if (was == now) return;
        if (now) {
          _settleCtrl.value = 1;
          return;
        }
        _settleFrom = waveRunningWindow(waveCtrl.value);
        _settleCtrl.value = 0;
        ExpressiveMotion.springTo(
          _settleCtrl,
          1,
          spring: ExpressiveMotion.spatialSlow,
        );
      },
    );

    final status = ref.watch(vpnStateProvider.select((s) => s.value?.status));
    final isConnecting = _isRunning(status);

    final server = ref.watch(serversProvider.select((s) => s.activeServer));
    final settings =
        ref.watch(settingsNotifierProvider).value ?? const AppSettings();

    final showTraffic = settings.showTrafficStats || settings.showTrafficSplit;
    final bytesPerSec = showTraffic
        ? ref.watch(
            vpnStateProvider.select((s) {
              final v = s.value;
              return (v?.downloadSpeed ?? 0) + (v?.uploadSpeed ?? 0);
            }),
          )
        : 0;
    final activeColor = _latencyColor(context, server, settings);
    final trackColor = Theme.of(context).colorScheme.secondaryContainer;

    final compact = height <= 24;
    final thickness = compact ? 8.0 : 12.0;

    final load = showTraffic ? _loadFactor(bytesPerSec) : _steadyLoad;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([waveCtrl, stateCtrl, _settleCtrl]),
          builder: (context, _) {
            final t = stateCtrl.value;
            final target = isConnecting
                ? _M3ProgressPainter.maxAmplitude
                : t *
                    _M3ProgressPainter.maxAmplitude *
                    (_idleWaveFloor + (1 - _idleWaveFloor) * load);
            _amp += (target - _amp) * 0.12;
            if ((target - _amp).abs() < 0.02) _amp = target;

            final (start, end) = isConnecting
                ? waveRunningWindow(waveCtrl.value)
                : waveExpandedWindow(_settleFrom, _settleCtrl.value);

            final tail = isConnecting
                ? 0.0
                : _M3ProgressPainter.maxTail *
                    _settleCtrl.value.clamp(0.0, 1.0) *
                    t;

            return CustomPaint(
              painter: _M3ProgressPainter(
                progress: waveCtrl.value,
                amplitude: _amp,
                thickness: thickness,
                color: Color.lerp(trackColor, activeColor, t)!,
                trackColor: trackColor,
                windowStart: start,
                windowEnd: end,
                tail: tail,
              ),
              size: Size(double.infinity, height),
            );
          },
        ),
      ),
    );
  }

  static const double _steadyLoad = 0.45;

  static const double _idleWaveFloor = 0.35;


  static double _loadFactor(int bytesPerSec) {
    if (bytesPerSec <= 0) return 0;
    const ceiling = 8 * 1024 * 1024;
    final normalized = log(1 + bytesPerSec) / log(1 + ceiling);
    return normalized.clamp(0.0, 1.0);
  }
}

Color _latencyColor(
  BuildContext context,
  ServerItem? server,
  AppSettings settings,
) {
  if (!settings.waveLatencyColor) return AppTheme.accent(context);
  final ping = server?.pingMs;
  if (server == null || ping == null || ping <= 0) {
    return AppTheme.accent(context);
  }
  final type = PingService.pingColorTypeForServer(server, settings);
  return switch (PingService.pingLatencyQuality(ping, type)) {
    PingLatencyQuality.good => AppTheme.green(context),
    PingLatencyQuality.fair => AppTheme.orange(context),
    PingLatencyQuality.poor => AppTheme.red(context),
  };
}

class _M3ProgressPainter extends CustomPainter {
  _M3ProgressPainter({
    required this.progress,
    required this.amplitude,
    required this.thickness,
    required this.color,
    required this.trackColor,
    required this.windowStart,
    required this.windowEnd,
    required this.tail,
  });

  final double progress;
  final double amplitude;
  final double thickness;
  final Color color;
  final Color trackColor;

  final double tail;

  final double windowStart;
  final double windowEnd;

  static const double maxAmplitude = 4;

  static const double maxTail = 48;

  // λ не анимировать: от неё зависит фаза sin(2πx/λ), и волна прыгает по ширине
  static const double _wavelength = 40;

  static const double _gap = 4;

  static const double _stopIndicator = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final mid = size.height / 2;
    final cap = thickness / 2;
    final left = cap;
    final right = w - cap;
    if (right <= left) return;

    final track = Paint()
      ..color = trackColor
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final active = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final activeRight = max(left, right - tail);
    double at(double fraction) => left + (activeRight - left) * fraction;
    final start = at(windowStart);
    final end = at(windowEnd);

    // drawLine берёт центры торцов, круглый торец добавляет радиус с каждой стороны стыка
    final trackInset = _gap + thickness;
    if (start - trackInset > left) {
      canvas.drawLine(Offset(left, mid), Offset(start - trackInset, mid), track);
    }
    if (end + trackInset < right) {
      canvas.drawLine(Offset(end + trackInset, mid), Offset(right, mid), track);
      canvas.drawCircle(
        Offset(right, mid),
        _stopIndicator / 2,
        Paint()..color = color,
      );
    }

    if (end - start < 0.5) return;

    if (amplitude < 0.05) {
      canvas.drawLine(Offset(start, mid), Offset(end, mid), active);
      return;
    }

    final path = Path();
    const step = 3.0;
    double yAt(double x) =>
        mid + amplitude * sin(2 * pi * (x / _wavelength - progress));

    path.moveTo(start, yAt(start));
    for (double x = start; x < end; x += step) {
      final next = (x + step).clamp(start, end);
      final midX = (x + next) / 2;
      path.quadraticBezierTo(x, yAt(x), midX, yAt(midX));
    }
    path.lineTo(end, yAt(end));
    canvas.drawPath(path, active);
  }

  @override
  bool shouldRepaint(_M3ProgressPainter old) =>
      old.progress != progress ||
      old.amplitude != amplitude ||
      old.thickness != thickness ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.windowStart != windowStart ||
      old.windowEnd != windowEnd ||
      old.tail != tail;
}

