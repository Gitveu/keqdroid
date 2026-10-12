import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/app_info.dart';
import '../../services/app_icon_cache.dart';
import 'app_theme.dart';
import 'expressive.dart';
import 'expressive_group.dart';
import 'haptics.dart';

/// Строка приложения — сегмент списка M3E. Общая у сплита и у шторки «Кто»
/// маршрута: одно и то же приложение выглядит одинаково везде.
///
/// Была карточка с собственной рамкой: невыбранная в полупрозрачный
/// `outlineVariant`, выбранная — в акцент толщиной 1.5px поверх заливки на 10%
/// альфы. Рамка на каждой строке и есть тот самый шум, от которого у M3E
/// уходят к контейнерам: теперь строку отделяет заливка, а выбор несут морф
/// формы и `secondaryContainer` — ровно как у строк серверов.
class AppListTile extends StatelessWidget {
  final AppInfo app;
  final bool checked;

  /// Цвет отметки выбора; null — строка без отметки (выбирать нечего).
  final Color? markColor;

  /// Форма сегмента: считает её список — только он знает, где у строки сосед,
  /// а где край группы.
  final BorderRadius radius;

  /// Поля сегмента внутри шага списка; из них набирается зазор между строками.
  final EdgeInsets margin;

  final VoidCallback? onTap;

  /// Кэш иконок приходит сверху, один на список: строка с собственным
  /// `ConsumerStatefulWidget` тащила бы за собой ещё и область зависимостей
  /// Riverpod, а строк бывают сотни.
  final AppIconCache iconCache;

  /// Шаг списка вместе с зазором — от него живёт `SliverFixedExtentList`.
  /// 40dp иконки и две строки текста укладываются в 72 с полями по 8.
  static const double height = 72;

  /// Размер индикатора выбора: XSmall-контейнер иконки M3E.
  static const double _markSize = 24;

  const AppListTile({
    super.key,
    required this.app,
    required this.checked,
    required this.markColor,
    required this.radius,
    required this.margin,
    required this.onTap,
    required this.iconCache,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground =
        checked ? scheme.onSecondaryContainer : scheme.onSurface;
    final muted = checked
        ? scheme.onSecondaryContainer.withValues(alpha: 0.7)
        : scheme.onSurfaceVariant;
    final titleStyle = checked
        ? theme.textTheme.emphasized(theme.textTheme.bodyLarge)
        : theme.textTheme.bodyLarge;

    return RepaintBoundary(
      child: MergeSemantics(
        child: Padding(
          padding: margin,
          child: ExpressiveListSegment(
            radius: radius,
            selected: checked,
            color: scheme.surfaceContainerHigh,
            selectedColor: scheme.secondaryContainer,
            onTap: onTap == null
                ? null
                : () {
                    AppHaptics.selection();
                    onTap!();
                  },
            splashColor: scheme.primary.withValues(alpha: 0.2),
            highlightColor: scheme.primary.withValues(alpha: 0.08),
            child: Padding(
              // Отступ leading-слота по спеке списка — 16dp от края контейнера.
              padding: const EdgeInsets.symmetric(
                horizontal: ExpressiveSpacing.large,
              ),
              child: Row(
                children: [
                  AppIconView(
                    iconBase64: app.iconBase64,
                    appName: app.appName,
                    iconPath: app.installPath,
                    cache: iconCache,
                  ),
                  const SizedBox(width: ExpressiveSpacing.medium),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                app.appName,
                                style: titleStyle?.copyWith(color: foreground),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // Процесс запущен — точка, а не «●» в плашке:
                            // символ жил на своей типографике и прыгал по
                            // базовой линии между шрифтами тем.
                            if (app.isRunning) ...[
                              const SizedBox(width: ExpressiveSpacing.small),
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: AppTheme.green(context),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          app.installPath ?? app.packageName,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (markColor case final color?) ...[
                    const SizedBox(width: ExpressiveSpacing.medium),
                    AppSelectionMark(checked: checked, color: color),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Отметка выбора. Цвет решает список: у сплита он смысловой — «в туннель»
/// и «мимо него» перепутать дорого.
class AppSelectionMark extends StatelessWidget {
  final bool checked;
  final Color color;
  const AppSelectionMark({super.key, required this.checked, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedSwitcher(
      duration: ExpressiveMotion.durationFast,
      switchInCurve: ExpressiveMotion.emphasized,
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: checked
          ? Container(
              key: const ValueKey('checked'),
              width: AppListTile._markSize,
              height: AppListTile._markSize,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(
                Icons.check_rounded,
                size: ExpressiveIconSize.inline,
                color: scheme.surface,
              ),
            )
          : Container(
              key: const ValueKey('unchecked'),
              width: AppListTile._markSize,
              height: AppListTile._markSize,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outline, width: 2),
                shape: BoxShape.circle,
              ),
            ),
    );
  }
}

/// Иконка приложения. exe-иконки на Windows подгружаются лениво, вне горячего
/// пути списка.
class AppIconView extends StatefulWidget {
  final String? iconBase64;
  final String appName;
  final String? iconPath;

  /// Кэш приходит сверху, а не берётся из провайдера здесь: строка списка не
  /// должна тащить за собой область зависимостей Riverpod ради одного чтения.
  final AppIconCache cache;

  const AppIconView({
    super.key,
    required this.iconBase64,
    required this.appName,
    required this.cache,
    this.iconPath,
  });

  @override
  State<AppIconView> createState() => _AppIconViewState();
}

class _AppIconViewState extends State<AppIconView> {
  Uint8List? _bytes;

  AppIconCache get _cache => widget.cache;

  /// Путь, по которому мы сейчас числимся в очереди кэша: по нему же и
  /// отписываемся. Хранить отдельно от `widget.iconPath` обязательно — в
  /// `dispose` виджет может уже нести другой путь.
  String? _pendingPath;

  @override
  void initState() {
    super.initState();
    _applyIcon(widget.iconBase64);
    if (_bytes == null) _loadIcon();
  }

  @override
  void didUpdateWidget(AppIconView old) {
    super.didUpdateWidget(old);
    if (old.iconBase64 != widget.iconBase64) {
      _applyIcon(widget.iconBase64);
    }
    if (old.iconPath != widget.iconPath) {
      _releasePending();
      if (_bytes == null) _loadIcon();
    }
  }

  @override
  void dispose() {
    _releasePending();
    super.dispose();
  }

  void _applyIcon(String? src) {
    if (src != null && src.isNotEmpty) {
      try {
        _bytes = base64Decode(src);
      } catch (_) {
        _bytes = null;
      }
    } else {
      _bytes = null;
    }
  }

  void _releasePending() {
    final path = _pendingPath;
    if (path == null) return;
    _pendingPath = null;
    _cache.release(path);
  }

  /// Иконка через общий кэш.
  ///
  /// Раньше каждая строка при появлении дёргала нативную выемку сама, без
  /// кэша: на быстрой прокрутке поток платформы разбирал десятки таких
  /// вызовов подряд, и список рвало. Уже добытая иконка теперь ставится
  /// сразу, без кадра с буквой-заглушкой, а строка, улетевшая с экрана до
  /// своей очереди, запрос забирает.
  void _loadIcon() {
    final path = widget.iconPath;
    if (path == null || path.isEmpty) return;
    if (_cache.has(path)) {
      _bytes = _cache.peek(path);
      return;
    }
    _pendingPath = path;
    _cache.request(path).then((bytes) {
      if (!mounted || bytes == null) return;
      setState(() => _bytes = bytes);
    });
  }

  /// Leading-слот строки по спеке списка M3E.
  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return ClipRRect(
        borderRadius: ExpressiveShape.radius(ExpressiveShape.medium),
        child: Image.memory(
          _bytes!,
          width: _size,
          height: _size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // Иконка приезжает крупнее слота (нативная часть просит 128 и
          // спускается вниз), поэтому здесь она уменьшается — а на уменьшении
          // качество фильтра как раз и видно.
          filterQuality: FilterQuality.medium,
          // Декодируем под фактический размер слота: исходные иконки бывают до
          // 512×512, полноразмерный декод раздувал image cache в разы.
          cacheWidth: (_size * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (context, error, stackTrace) => _fallback(context),
        ),
      );
    }
    return _fallback(context);
  }

  /// Приложение без иконки — буква в контейнере роли, а не акцент на 30%
  /// альфы: полупрозрачность сводилась с заливкой строки, и на выбранной
  /// кружок съезжал в другой оттенок.
  Widget _fallback(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: ExpressiveShape.radius(ExpressiveShape.medium),
      ),
      child: Center(
        child: Text(
          widget.appName.isNotEmpty ? widget.appName[0].toUpperCase() : '?',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
        ),
      ),
    );
  }
}
