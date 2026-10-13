import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'expressive.dart';

class ScrollHiddenFab extends StatefulWidget {
  final Widget child;

  final Widget fab;

  final double right;
  final double bottom;

  const ScrollHiddenFab({
    super.key,
    required this.child,
    required this.fab,
    this.right = 16,
    this.bottom = 16,
  });

  @override
  State<ScrollHiddenFab> createState() => _ScrollHiddenFabState();
}

class _ScrollHiddenFabState extends State<ScrollHiddenFab> {
  bool _visible = true;

  void _show() {
    if (!_visible) setState(() => _visible = true);
  }

  void _hide() {
    if (_visible) setState(() => _visible = false);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;

    if (notification is UserScrollNotification) {
      switch (notification.direction) {
        case ScrollDirection.reverse:
          _hide();
        case ScrollDirection.forward:
          _show();
        // idle приходит и на отпускании пальца, по нему кнопка вернулась бы сразу
        case ScrollDirection.idle:
          break;
      }
      return false;
    }

    // у самого верха показываем всегда: после прыжка или фильтра прокрутки вверх уже не будет
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      final metrics = notification.metrics;
      if (!metrics.hasContentDimensions ||
          metrics.pixels <= metrics.minScrollExtent) {
        _show();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned(
            right: widget.right,
            bottom: widget.bottom,
            child: IgnorePointer(
              ignoring: !_visible,
              child: AnimatedScale(
                scale: _visible ? 1 : 0.7,
                duration: const Duration(milliseconds: 180),
                curve: ExpressiveMotion.emphasized,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: widget.fab,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
