import 'package:flutter/material.dart';
import 'halloween/halloween_icons.dart';

import 'expressive.dart';
import 'haptics.dart';

class ExpressiveSegment<T> {
  const ExpressiveSegment({
    required this.value,
    required this.label,
    this.icon,
    this.iconColor,
  });

  final T value;
  final String label;
  final IconData? icon;

  final Color? iconColor;
}

class ExpressiveConnectedButtons<T> extends StatelessWidget {
  const ExpressiveConnectedButtons({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.height = 40,
  });

  final List<ExpressiveSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height;

  static const double _gap = ExpressiveSpacing.hairline;

  static const double _innerCorner = ExpressiveShape.small;

  // половина высоты, а не full: лерп от 999 почти всю дорогу держится выше потолка,
  // и форма возвращается рывком
  static double _pillCorner(double height) => height / 2;

  static BorderRadius _restRadius(int index, int count, double height) {
    final outer = Radius.circular(_pillCorner(height));
    const inner = Radius.circular(_innerCorner);
    return BorderRadius.horizontal(
      left: index == 0 ? outer : inner,
      right: index == count - 1 ? outer : inner,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) const SizedBox(width: _gap),
            Expanded(
              child: _Segment(
                segment: segments[i],
                selected: segments[i].value == selected,
                radius: _restRadius(i, segments.length, height),
                pillCorner: _pillCorner(height),
                scheme: scheme,
                onTap: () {
                  if (segments[i].value == selected) return;
                  AppHaptics.selection();
                  onChanged(segments[i].value);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Segment<T> extends StatefulWidget {
  const _Segment({
    required this.segment,
    required this.selected,
    required this.radius,
    required this.pillCorner,
    required this.scheme,
    required this.onTap,
  });

  final ExpressiveSegment<T> segment;
  final bool selected;
  final BorderRadius radius;

  final double pillCorner;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  State<_Segment<T>> createState() => _SegmentState<T>();
}

class _SegmentState<T> extends State<_Segment<T>>
    with TickerProviderStateMixin {
  late final AnimationController _shape = AnimationController.unbounded(
    vsync: this,
  )..value = widget.selected ? 1 : 0;
  late final AnimationController _tint = AnimationController.unbounded(
    vsync: this,
  )..value = widget.selected ? 1 : 0;
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );

  @override
  void didUpdateWidget(covariant _Segment<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected) return;
    final target = widget.selected ? 1.0 : 0.0;
    ExpressiveMotion.springTo(
      _shape,
      target,
      spring: ExpressiveMotion.spatialDefault,
    );
    ExpressiveMotion.springTo(
      _tint,
      target,
      spring: ExpressiveMotion.effectsDefault,
    );
  }

  @override
  void dispose() {
    _shape.dispose();
    _tint.dispose();
    _press.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    ExpressiveMotion.springTo(
      _press,
      pressed ? 1 : 0,
      spring: pressed
          ? ExpressiveMotion.effectsFast
          : ExpressiveMotion.spatialDefault,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final textTheme = Theme.of(context).textTheme;
    final labelBase = textTheme.labelLarge ?? const TextStyle();
    final selectedRadius = BorderRadius.circular(widget.pillCorner);

    final restStyle = labelBase.copyWith(color: scheme.onSurfaceVariant);
    final selectedStyle = textTheme
        .emphasized(labelBase)!
        .copyWith(color: scheme.onPrimary);

    return AnimatedBuilder(
      animation: Listenable.merge([_shape, _tint, _press]),
      builder: (context, _) {
        final shapeT = _shape.value.clamp(0.0, 1.0);
        final tint = _tint.value.clamp(0.0, 1.0);
        final press = _press.value.clamp(0.0, 1.0);

        final rest = BorderRadius.lerp(widget.radius, selectedRadius, shapeT)!;
        final radius = BorderRadius.lerp(
          rest,
          ExpressiveShape.pressedRadius(rest),
          press,
        )!;
        final shape = RoundedRectangleBorder(borderRadius: radius);
        final iconColor = Color.lerp(
          widget.segment.iconColor ?? scheme.onSurfaceVariant,
          scheme.onPrimary,
          tint,
        )!;

        return Transform.scale(
          scale: 1 - 0.04 * press,
          child: Material(
            color: Color.lerp(
              scheme.surfaceContainerHighest,
              scheme.primary,
              tint,
            ),
            shape: shape,
            clipBehavior: Clip.antiAlias,
            // форму и цвет меняем покадрово, неявная анимация Material только перезапускалась бы
            animationDuration: Duration.zero,
            child: InkWell(
              onTap: widget.onTap,
              onTapDown: (_) => _setPressed(true),
              onTapUp: (_) => _setPressed(false),
              onTapCancel: () => _setPressed(false),
              customBorder: shape,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.segment.icon != null) ...[
                      SeasonalIcon(
                        widget.segment.icon,
                        size: ExpressiveIconSize.inline,
                        color: iconColor,
                      ),
                      const SizedBox(width: ExpressiveSpacing.small),
                    ],
                    Flexible(
                      child: Text(
                        widget.segment.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle.lerp(restStyle, selectedStyle, tint),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
