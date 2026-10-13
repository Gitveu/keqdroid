// штатно шапка меняет цвет рывком, а animateColor у SliverAppBar нет, поэтому прогресс по смещению
library;

import 'package:flutter/material.dart';

class ExpressiveScrolledUnderBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, Color background) builder;

  final double distance;

  const ExpressiveScrolledUnderBuilder({
    super.key,
    required this.builder,
    this.distance = 32,
  });

  @override
  State<ExpressiveScrolledUnderBuilder> createState() =>
      _ExpressiveScrolledUnderBuilderState();
}

class _ExpressiveScrolledUnderBuilderState
    extends State<ExpressiveScrolledUnderBuilder> {
  ScrollNotificationObserverState? _observer;
  double _progress = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (observer == _observer) return;
    _observer?.removeListener(_onNotification);
    _observer = observer;
    _observer?.addListener(_onNotification);
  }

  @override
  void dispose() {
    _observer?.removeListener(_onNotification);
    _observer = null;
    super.dispose();
  }

  void _onNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return;
    if (notification.depth != 0) return;

    final next = (metrics.extentBefore / widget.distance).clamp(0.0, 1.0);
    if ((next - _progress).abs() < 0.0025) return;
    setState(() => _progress = next);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, scrolledUnderColour(context, _progress));
}

class ExpressiveScrolledUnderBar extends StatelessWidget
    implements PreferredSizeWidget {
  final Widget Function(BuildContext context, Color background) builder;

  @override
  final Size preferredSize;

  const ExpressiveScrolledUnderBar({
    super.key,
    required this.builder,
    this.preferredSize = const Size.fromHeight(kToolbarHeight),
  });

  @override
  Widget build(BuildContext context) =>
      ExpressiveScrolledUnderBuilder(builder: builder);
}

Color scrolledUnderColour(BuildContext context, double t) {
  final scheme = Theme.of(context).colorScheme;
  return Color.lerp(scheme.surface, scheme.surfaceContainer, t)!;
}
