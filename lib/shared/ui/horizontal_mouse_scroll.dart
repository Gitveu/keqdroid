import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

// колесо шлёт только dy, а горизонтальный Scrollable берёт dx, и мыши нет в dragDevices
class HorizontalMouseScroll extends StatelessWidget {
  const HorizontalMouseScroll({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.mouse,
        },
      ),
      child: Listener(onPointerSignal: _onPointerSignal, child: child),
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // только dy: горизонтальную дельту Scrollable разбирает сам
    final delta = event.scrollDelta.dy;
    if (delta == 0 || !controller.hasClients) return;
    // pointerScroll, а не jumpTo: тот же вход, что у Scrollable, сглаживание остаётся
    controller.position.pointerScroll(delta);
  }
}
