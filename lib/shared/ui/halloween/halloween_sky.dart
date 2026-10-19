import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../platform/platform_bootstrap.dart';

/// Небо за кнопкой-тыквой: ночью полумесяц в облаках, днём закатное солнце,
/// облака и три птицы вдалеке.
///
/// Небо рисуется шире кнопки и выходит за её границы, но место в шапке
/// занимает ровно как кнопка: раскладка экрана от праздника не меняется.
/// Неподвижно и стоит в своём слое отрисовки — тыква мерцает каждый кадр, а
/// размытие неба дорогое, перерисовывать его вместе с ней незачем.
class HalloweenSky extends StatelessWidget {
  const HalloweenSky({super.key, required this.child});

  /// Кнопка, перед которой висит небо.
  final Widget child;

  static const double _side = 136;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: _side,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -_SkyPainter.dx,
            top: -_SkyPainter.dy,
            width: _SkyPainter.width,
            height: _SkyPainter.height,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _SkyPainter(scheme, desktop: PlatformBootstrap.isDesktop)),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.scheme, {required this.desktop});

  final ColorScheme scheme;
  final bool desktop;

  // Холст сдвинут относительно кнопки; координаты ниже — в системе кнопки.
  static const dx = 190.0, dy = 40.0, width = 516.0, height = 210.0;

  static Rect _o(double x, double y, double w, double h) => Rect.fromCenter(center: Offset(x, y), width: w, height: h);

  /// Ночное облако: строго плоский низ, крупный клуб, пара поменьше и тонкий
  /// хвост. Клубы — овалы разного размера с сильным перекрытием: одинаковые
  /// круги рядком читались как бусы из пузырей.
  static Path _night(double baseY, List<Rect> lobes) {
    var p = Path();
    for (final r in lobes) {
      p = Path.combine(PathOperation.union, p, Path()..addOval(r));
    }
    return Path.combine(PathOperation.intersect, p, Path()..addRect(Rect.fromLTRB(-1000, -1000, 1000, baseY)));
  }

  /// Дневное облако: вытянутое тело с заострёнными хвостами, тянущимися к
  /// тыкве, и приплюснутые клубы, сбитые к дальнему краю.
  static (Path, List<Rect>) _day(double left, double right, double baseY, double thick, List<Rect> lobes) {
    final w = right - left;
    var p = Path()
      ..moveTo(left, baseY - 2)
      ..cubicTo(left + w * .3, baseY + 3, left + w * .7, baseY + 3, right, baseY - 2)
      ..cubicTo(left + w * .7, baseY - thick, left + w * .3, baseY - thick, left, baseY - 2)
      ..close();
    for (final r in lobes) {
      p = Path.combine(PathOperation.union, p, Path()..addOval(r));
    }
    return (p, lobes);
  }

  static final _nightClouds = [
    _night(46, [_o(-64, 32, 36, 32), _o(-85, 40, 26, 18), _o(-44, 38, 28, 20), _o(-26, 43, 34, 8), _o(-100, 44, 20, 6)]),
    _night(76, [_o(-78, 70, 18, 14), _o(-65, 73, 18, 8), _o(-90, 74, 14, 5)]),
    _night(34, [_o(196, 20, 36, 32), _o(175, 27, 26, 18), _o(215, 26, 24, 18), _o(236, 31, 36, 8), _o(158, 32, 18, 6)]),
    _night(86, [_o(216, 80, 18, 13), _o(229, 83, 20, 7), _o(204, 84, 12, 5)]),
    _night(104, [_o(182, 99, 13, 10), _o(191, 102, 16, 5)]),
  ];

  static final _dayClouds = [
    _day(146, 258, 64, 14, [_o(214, 42, 46, 34), _o(236, 52, 30, 20), _o(192, 50, 34, 20), _o(172, 57, 22, 10)]),
    _day(-120, -30, 74, 10, [_o(-92, 63, 34, 20), _o(-74, 66, 24, 12), _o(-106, 68, 18, 9)]),
    _day(-82, -22, 30, 8, [_o(-56, 21, 26, 16), _o(-42, 25, 18, 9), _o(-68, 26, 14, 7)]),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Матовое стекло между небом и тыквой: всё небо уходит в слегка размытый слой.
    canvas.saveLayer(Offset.zero & size, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 1.2, sigmaY: 1.2));
    // На ПК над кнопкой меньше места, и ореол упирался в край окна.
    canvas.translate(dx, dy + (desktop ? 12 : 0));
    final dark = scheme.brightness == Brightness.dark;
    final center = dark ? const Offset(-64, 20) : const Offset(196, 30);
    final light = dark ? const Color(0xFFF1EAFF) : const Color(0xFFFFC09A);
    final halo = dark ? scheme.secondary : const Color(0xFFFFB27E);
    final body = dark
        ? Path.combine(
            PathOperation.difference,
            Path()..addOval(Rect.fromCircle(center: center, radius: 24)),
            Path()..addOval(Rect.fromCircle(center: center + const Offset(11, -7), radius: 21)),
          )
        : (Path()..addOval(Rect.fromCircle(center: center, radius: 21)));

    // Светило с ореолом. Внутри облака оно рисуется ещё раз размытым — так свет
    // проходит сквозь облако, как сквозь стекло.
    void drawLight({double blur = 0, double alpha = 1, BlendMode mode = BlendMode.srcOver}) {
      canvas.drawCircle(
        center,
        52,
        Paint()
          ..blendMode = mode
          ..shader = RadialGradient(colors: [halo.withValues(alpha: (dark ? .22 : .35) * alpha), halo.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: 52)),
      );
      final p = Paint()
        ..blendMode = mode
        ..color = light.withValues(alpha: alpha);
      if (blur > 0) p.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
      canvas.drawPath(body, p);
    }

    drawLight();
    if (dark) {
      _paintNight(canvas, drawLight);
    } else {
      _paintDay(canvas, drawLight);
    }
    canvas.restore();
  }

  void _paintNight(Canvas canvas, void Function({double blur, double alpha, BlendMode mode}) drawLight) {
    final top = Color.lerp(scheme.surfaceContainerHigh, scheme.onSurface, .26)!.withValues(alpha: .84);
    final bottom = Color.lerp(scheme.surfaceContainerHigh, scheme.onSurface, .1)!.withValues(alpha: .8);
    for (final cloud in _nightClouds) {
      final b = cloud.getBounds().inflate(12);
      // Край растушёван: размытый контур ложится маской, заливка — только на неё
      // (srcIn), просвечивающая луна — поверх, не выходя за маску (srcATop).
      // Жёсткий край делал облака мультяшными, а бликов ночью нет совсем —
      // с ними облака выглядели пластмассовыми.
      canvas.saveLayer(b, Paint());
      canvas.drawPath(cloud, Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.6));
      canvas.drawRect(
        b,
        Paint()
          ..blendMode = BlendMode.srcIn
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom])
              .createShader(cloud.getBounds()),
      );
      drawLight(blur: 7, alpha: .6, mode: BlendMode.srcATop);
      canvas.restore();
    }
  }

  void _paintDay(Canvas canvas, void Function({double blur, double alpha, BlendMode mode}) drawLight) {
    // Светлый верх, тёмное брюхо и подсветка клубов со стороны солнца.
    final top = Colors.white.withValues(alpha: .9);
    final bottom = Color.lerp(Colors.white, scheme.onSurfaceVariant, .5)!.withValues(alpha: .88);
    final rim = Colors.white.withValues(alpha: .6);
    for (final (cloud, lobes) in _dayClouds) {
      final b = cloud.getBounds();
      canvas.save();
      canvas.clipPath(cloud);
      canvas.drawRect(
        b,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [top, Color.lerp(top, bottom, .45)!, bottom],
            stops: const [0, .5, 1],
          ).createShader(b),
      );
      for (final r in lobes) {
        final c = r.center + Offset(r.width * .22, -r.height * .3);
        final hr = Rect.fromCenter(center: c, width: r.width * .8, height: r.height * .7);
        canvas.drawOval(hr, Paint()..shader = RadialGradient(colors: [rim, rim.withValues(alpha: 0)]).createShader(hr));
      }
      drawLight(blur: 7, alpha: .6);
      canvas.restore();
    }
    // Три птицы улетают вдаль: чем дальше, тем мельче и выше.
    final bird = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 1.4
      ..color = scheme.onSurfaceVariant.withValues(alpha: .5);
    for (final (x, y, w) in const [(-32.0, 4.0, 7.0), (-48.0, -6.0, 5.4), (-36.0, -14.0, 4.2)]) {
      canvas.drawPath(
        Path()
          ..moveTo(x - w, y - w * .25)
          ..quadraticBezierTo(x - w * .45, y - w * .6, x, y)
          ..quadraticBezierTo(x + w * .45, y - w * .6, x + w, y - w * .25),
        bird,
      );
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) => old.scheme != scheme || old.desktop != desktop;
}
