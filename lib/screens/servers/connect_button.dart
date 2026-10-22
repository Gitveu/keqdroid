part of '../servers_tab.dart';

class _ConnectButton extends StatefulWidget {
  final bool isConnected;
  final bool isConnecting;
  final VoidCallback? onTap;

  final double size;
  final Color? idleColor;

  const _ConnectButton({
    required this.isConnected,
    required this.isConnecting,
    required this.onTap,
    this.size = _ConnectButtonState._size,
    this.idleColor,
  });

  @override
  State<_ConnectButton> createState() => _ConnectButtonState();
}

// тикеров три (нажатие и два в ShapeMorphCycle), с SingleTickerProviderStateMixin падает ассерт
class _ConnectButtonState extends State<_ConnectButton>
    with TickerProviderStateMixin {
  static const double _size = 136;

  static const double _selectedCorner = ExpressiveShape.extraExtraLarge;

  static const double _pressedCorner = ExpressiveShape.extraLarge;

  static const double _iconSize = 40;

  // unbounded: пружина должна перелетать за цель
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );

  ShapeMorphCycle? _cycle;

  @override
  void initState() {
    super.initState();
    _syncCycle();
  }

  @override
  void didUpdateWidget(covariant _ConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isConnecting != widget.isConnecting ||
        oldWidget.isConnected != widget.isConnected) {
      // диалог разрешения VPN забирает окно, и onTapUp может не прийти
      _setPressed(false);
    }
    _syncCycle();
  }

  void _syncCycle() {
    if (widget.isConnecting) {
      final running = _cycle;
      if (running == null) {
        _cycle = ShapeMorphCycle(vsync: this);
      } else if (running.isSettling) {
        // во время диалога разрешения VPN статус выходит из connecting, поэтому возобновляем тот же цикл
        running.resume();
      }
      return;
    }
    final cycle = _cycle;
    if (cycle == null || cycle.isSettling) return;
    cycle.settle(
      onDone: () {
        if (!mounted) {
          cycle.dispose();
          return;
        }
        setState(() => _cycle = null);
        // AnimatedSwitcher ещё доигрывает старый кадр, подписанный на этот цикл
        Future.delayed(ExpressiveMotion.durationFast, cycle.dispose);
      },
    );
  }

  @override
  void dispose() {
    _cycle?.dispose();
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

  double get _phase => widget.isConnected ? 1 : 0;

  // углы и значок вместе с кнопкой: на 88 те же 48 dp сделали бы квадрат кругом
  double get _scale => widget.size / _size;

  @override
  Widget build(BuildContext context) {
    return TvFocusHighlight(
      radius: BorderRadius.circular(widget.size / 2),
      child: Builder(builder: _buildButton),
    );
  }

  Widget _buildButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focusFill = TvFocusHighlight.containerOf(context);
    final unselectedBg = widget.idleColor ?? scheme.surfaceContainer;
    final selectedBg = scheme.primary;

    return TweenAnimationBuilder<double>(
      tween: Tween(end: _phase),
      duration: ExpressiveMotion.durationDefault,
      curve: ExpressiveMotion.emphasized,
      builder: (context, phase, child) {
        final bg = focusFill ?? Color.lerp(unselectedBg, selectedBg, phase)!;

        return AnimatedBuilder(
          animation: Listenable.merge([_press, _cycle]),
          builder: (context, _) {
            final t = _press.value.clamp(0.0, 1.0);
            final shape = _shape(t, phase);

            return Transform.scale(
              scale: 1 - 0.04 * t,
              child: DecoratedBox(
                decoration: ShapeDecoration(shape: shape),
                child: Material(
                  color: bg,
                  shape: shape,
                  // форму меняем покадрово, неявная анимация Material перезапускалась бы на каждом кадре
                  animationDuration: Duration.zero,
                  child: InkWell(
                    onTap: widget.onTap == null
                        ? null
                        : () {
                            AppHaptics.impact();
                            widget.onTap!();
                          },
                    onTapDown: (_) => _setPressed(true),
                    onTapUp: (_) => _setPressed(false),
                    onTapCancel: () => _setPressed(false),
                    customBorder: shape,
                    child: SizedBox(
                      width: widget.size,
                      height: widget.size,
                      child: child,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
      child: _icon(context),
    );
  }

  // cycle аргументом: AnimatedSwitcher доигрывает старый кадр после обнуления поля, и _cycle! упал бы молча
  Widget _morphFigure(BuildContext context, ShapeMorphCycle cycle) =>
      RepaintBoundary(
        key: const ValueKey('morph'),
        child: AnimatedBuilder(
          animation: cycle,
          builder: (context, _) => CustomPaint(
            size: Size.square(widget.size),
            painter: MorphPainter(
              morph: cycle.morph,
              progress: cycle.progress,
              degrees: cycle.degrees,
              scale: ShapeLoadingIndicator.activeScale,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );

  ShapeBorder _shape(
    double press,
    double selected, {
    BorderSide side = BorderSide.none,
  }) {
    final rest = ShapeBorder.lerp(
      CircleBorder(side: side),
      RoundedRectangleBorder(
        borderRadius: ExpressiveShape.radius(_selectedCorner * _scale),
        side: side,
      ),
      selected,
    )!;
    return ShapeBorder.lerp(
      rest,
      RoundedRectangleBorder(
        borderRadius: ExpressiveShape.radius(_pressedCorner * _scale),
        side: side,
      ),
      press,
    )!;
  }

  Widget _icon(BuildContext context) {
    final cycle = _cycle;
    final scheme = Theme.of(context).colorScheme;
    final idleIcon = TvFocusHighlight.containerOf(context) != null
        ? scheme.onSurface
        : scheme.onSurfaceVariant;
    return AnimatedSwitcher(
      duration: ExpressiveMotion.durationFast,
      switchInCurve: ExpressiveMotion.emphasizedDecelerate,
      switchOutCurve: ExpressiveMotion.emphasizedAccelerate,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.7, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: cycle != null
          ? _morphFigure(context, cycle)
          : Icon(
              widget.isConnected
                  ? Icons.pause_rounded
                  : Icons.play_arrow_outlined,
              key: ValueKey(widget.isConnected ? 'pause' : 'play'),
              size: _iconSize * _scale,
              color: widget.isConnected ? scheme.onPrimary : idleIcon,
            ),
    );
  }
}
