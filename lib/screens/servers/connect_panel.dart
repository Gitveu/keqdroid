part of '../servers_tab.dart';

// режим «Модерн»: всё из шапки над списком собрано в одну панель, кнопка справа
class _ModernConnectPanel extends ConsumerWidget {
  const _ModernConnectPanel({
    required this.stateCtrl,
    required this.waveCtrl,
    required this.onToggle,
    required this.onJumpToActive,
  });

  final AnimationController stateCtrl;
  final AnimationController waveCtrl;

  final void Function(VpnStatus) onToggle;
  final VoidCallback onJumpToActive;

  static const double _buttonSize = 120;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vpnStatus = ref.watch(
      vpnStateProvider.select((a) => a.value?.status ?? VpnStatus.disconnected),
    );
    final vpnErrorMessage = ref.watch(
      vpnStateProvider.select((a) => a.value?.errorMessage),
    );
    final serverSwitchInProgress = ref.watch(vpnServerSwitchInProgressProvider);
    final activeServer = ref.watch(
      serversProvider.select((s) => s.activeServer),
    );
    final exitLookup = ref.watch(exitIpProvider);
    final exit = exitLookup.isLoading ? null : exitLookup.value;
    final halloween = ref.watch(halloweenActiveProvider);

    final isConnected =
        vpnStatus == VpnStatus.connected && !serverSwitchInProgress;
    final isConnecting =
        serverSwitchInProgress || vpnStatus == VpnStatus.connecting;
    final isError = vpnStatus == VpnStatus.error && !serverSwitchInProgress;

    // connecting тапабелен: это отмена попытки
    final VoidCallback? onTap =
        vpnStatus == VpnStatus.disconnecting ? null : () => onToggle(vpnStatus);

    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final topPad = PlatformBootstrap.isDesktop
        ? 16.0
        : MediaQuery.paddingOf(context).top + 12;

    final button = halloween
        ? SizedBox.square(
            dimension: _buttonSize,
            child: FittedBox(
              child: PumpkinConnectButton(
                isConnected: isConnected,
                isConnecting: isConnecting,
                isError: isError,
                onTap: onTap,
              ),
            ),
          )
        : _ConnectButton(
            isConnected: isConnected,
            isConnecting: isConnecting,
            onTap: onTap,
            size: _buttonSize,
            // на подложке панели обычный серый кнопки сливался бы с ней
            idleColor: scheme.surfaceContainerHighest,
          );

    return Padding(
      padding: EdgeInsets.fromLTRB(16, topPad, 16, 8),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: scheme.surfaceContainerLow,
          shape: ExpressiveShape.border(ExpressiveShape.extraLarge),
        ),
        child: ClipRRect(
          borderRadius: ExpressiveShape.radius(ExpressiveShape.extraLarge),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      end: isConnected || isConnecting
                          ? scheme.primary
                          : AppTheme.textLight(context),
                    ),
                    duration: ExpressiveMotion.durationDefault,
                    // своим слоем: волна рядом перерисовывает панель каждый кадр
                    builder: (context, color, _) => RepaintBoundary(
                      child: _PanelShapes(color: color!),
                    ),
                  ),
                ),
              ),
              Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnimatedSwitcher(
                              duration: ExpressiveMotion.durationFast,
                              layoutBuilder: (current, previous) => Stack(
                                alignment: AlignmentDirectional.centerStart,
                                children: [...previous, ?current],
                              ),
                              child: _serverLine(
                                context,
                                isConnected ? activeServer : null,
                                activeServer,
                                exit,
                              ),
                            ),
                            if (activeServer != null)
                              _ServerTags(server: activeServer),
                          ],
                        ),
                      ),
                      const SizedBox(width: ExpressiveSpacing.large),
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: ExpressiveSpacing.medium,
                        ),
                        child: RepaintBoundary(child: button),
                      ),
                    ],
                  ),
                  if (isError && vpnErrorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: ExpressiveSpacing.small),
                      child: Text(
                        friendlyError(vpnErrorMessage, context),
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: AppTheme.red(context),
                        ),
                      ),
                    ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: isConnected
                        ? const _ConnectionStats(key: ValueKey('stats'), fill: true)
                        : const SizedBox(
                            key: ValueKey('stats-hidden'),
                            width: double.infinity,
                          ),
                  ),
                  const SizedBox(height: ExpressiveSpacing.large),
                  _WavePaintWidget(
                    waveCtrl: waveCtrl,
                    stateCtrl: stateCtrl,
                    height: 24,
                  ),
                ],
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serverLine(
    BuildContext context,
    ServerItem? connectedServer,
    ServerItem? activeServer,
    ExitIp? exit,
  ) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    if (activeServer == null) {
      return Text(
        l10n.vpnSelectServer,
        key: const ValueKey('no-server'),
        style: textTheme.bodyMedium?.copyWith(
          color: AppTheme.textLight(context),
        ),
      );
    }
    final name = ServerNameUtils.formatForDisplay(
      ServerNameUtils.cleanDisplayName(activeServer.displayName),
    );
    // тот же чип, что в легаси: по флагу раскрывает IP выхода, по остальному ведёт к серверу в списке
    if (connectedServer != null) {
      return ConnectedStatusChip(
        key: const ValueKey('connected'),
        label: name,
        exit: exit,
        onJumpToActive: onJumpToActive,
        textStyle: _ServersTabState._statusChipTextStyle(textTheme),
        verticalPadding: _ServersTabState._statusChipVerticalPadding,
      );
    }
    return InkWell(
      key: const ValueKey('ready'),
      onTap: onJumpToActive,
      borderRadius: ExpressiveShape.radius(ExpressiveShape.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ExpressiveSpacing.extraSmall),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ServerAvatar(
              flag: activeServer.flag,
              protocol: activeServer.protocol,
              size: 28,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textDirection: contentDirection(
                  name,
                  fallback: Directionality.of(context),
                ),
                style: textTheme
                    .emphasized(textTheme.titleMedium)
                    ?.copyWith(color: AppTheme.text(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerTags extends ConsumerWidget {
  const _ServerTags({required this.server});

  final ServerItem server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(
      settingsNotifierProvider.select(
        (async) => async.value ?? const AppSettings(),
      ),
    );
    final pingMs = server.pingMs;
    final protocolColor = serverProtocolColor(context, server.protocol);
    final pingType = PingService.pingColorTypeForServer(server, settings);
    final pingColor = pingMs != null
        ? pingQualityColor(context, pingMs, pingType)
        : AppTheme.textLight(context);
    return Padding(
      padding: const EdgeInsets.only(top: ExpressiveSpacing.small),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          if (pingMs != null || server.lastTestedAt != null)
            _tag(
              context,
              ltrIsolate(
                pingMs != null
                    ? PingService.formatPingValue(pingMs, pingType)
                    : 'N/A',
              ),
              pingColor,
            ),
          _tag(context, server.protocol.toUpperCase(), protocolColor),
        ],
      ),
    );
  }

  Widget _tag(BuildContext context, String text, Color color) {
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: ExpressiveShape.radius(ExpressiveShape.full),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: ExpressiveSpacing.extraSmall,
        ),
        child: Text(
          text,
          style: textTheme.emphasized(textTheme.labelMedium)?.copyWith(
            color: color,
          ),
        ),
      ),
    );
  }
}

// бледные фигуры M3 по краям карточки, выбраны по макету 22.10. наборов три, раз в полминуты
// один гаснет, следующий проявляется. места заданы долей ширины: на ПК карточка шире макета
class _ShapeSpot {
  const _ShapeSpot(
    this.polygon,
    this.size,
    this.alpha,
    this.degrees,
    this.alignment,
    this.nudge,
  );

  final RoundedPolygon polygon;
  final double size;
  final double alpha;
  final double degrees;
  final AlignmentDirectional alignment;
  final Offset nudge;
}

final _shapePresets = [
  [
    _ShapeSpot(MaterialShapes.sunny, 46, 0.10, 17,
        AlignmentDirectional(-0.1, -1), Offset(0, -14)),
    _ShapeSpot(MaterialShapes.pill, 30, 0.10, 46,
        AlignmentDirectional(0.1, 1), Offset(0, -6)),
    _ShapeSpot(MaterialShapes.flower, 52, 0.08, -11,
        AlignmentDirectional(-1, 1), Offset(-10, -34)),
    _ShapeSpot(MaterialShapes.clover4Leaf, 38, 0.12, 29,
        AlignmentDirectional(1, 1), Offset(-6, -44)),
  ],
  [
    _ShapeSpot(MaterialShapes.cookie9Sided, 50, 0.10, 10,
        AlignmentDirectional(0.45, -1), Offset(0, -18)),
    _ShapeSpot(MaterialShapes.softBurst, 34, 0.10, 0,
        AlignmentDirectional(-0.35, 1), Offset(0, -4)),
    _ShapeSpot(MaterialShapes.puffy, 56, 0.08, -15,
        AlignmentDirectional(-1, -1), Offset(-14, -12)),
    _ShapeSpot(MaterialShapes.gem, 30, 0.12, 20,
        AlignmentDirectional(1, 0.2), Offset(-4, 0)),
  ],
  [
    _ShapeSpot(MaterialShapes.flower, 48, 0.09, 0,
        AlignmentDirectional(-1, -1), Offset(-12, -10)),
    _ShapeSpot(MaterialShapes.sunny, 54, 0.09, -10,
        AlignmentDirectional(0.35, 1), Offset(0, 14)),
    _ShapeSpot(MaterialShapes.clover4Leaf, 32, 0.12, 35,
        AlignmentDirectional(-0.2, -1), Offset(0, -6)),
    _ShapeSpot(MaterialShapes.cookie7Sided, 40, 0.10, 15,
        AlignmentDirectional(1, -1), Offset(-10, -8)),
  ],
];

class _PanelShapes extends StatefulWidget {
  const _PanelShapes({required this.color});

  final Color color;

  static const every = Duration(seconds: 30);

  @override
  State<_PanelShapes> createState() => _PanelShapesState();
}

class _PanelShapesState extends State<_PanelShapes>
    with SingleTickerProviderStateMixin {
  late final _change = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  Timer? _timer;
  var _from = 0;
  var _to = 1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_PanelShapes.every, (_) => _next());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _change.dispose();
    super.dispose();
  }

  void _next() {
    // за другой вкладкой не листаем: вернёшься, а наборы прокручены
    if (!mounted || !TickerMode.valuesOf(context).enabled) return;
    if (_change.isAnimating) return;
    if (_change.isCompleted) {
      setState(() {
        _from = _to;
        _to = (_to + 1) % _shapePresets.length;
      });
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _change.value = 1;
    } else {
      _change.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: _change,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_change.value);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (preset, fade) in [(_from, 1 - t), (_to, t)])
              if (fade > 0)
                for (final spot in _shapePresets[preset])
                  _spot(spot, fade, rtl),
          ],
        );
      },
    );
  }

  // прозрачность в цвете, а не Opacity: без лишнего слоя на время смены
  Widget _spot(_ShapeSpot spot, double fade, bool rtl) => Align(
        alignment: spot.alignment,
        child: Transform.translate(
          offset: Offset(rtl ? -spot.nudge.dx : spot.nudge.dx, spot.nudge.dy),
          child: Transform.rotate(
            angle: spot.degrees * pi / 180,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: widget.color.withValues(alpha: spot.alpha * fade),
                shape: RoundedPolygonBorder(polygon: spot.polygon),
              ),
              child: SizedBox.square(dimension: spot.size),
            ),
          ),
        ),
      );
}
