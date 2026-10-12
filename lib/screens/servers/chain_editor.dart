import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/shared/extensions/build_context_l10n.dart';
import 'package:keqdroid/shared/ui/app_theme.dart';
import 'package:keqdroid/shared/ui/expressive.dart';
import 'package:keqdroid/shared/ui/expressive_group.dart';
import 'package:keqdroid/shared/ui/haptics.dart';
import 'package:keqdroid/shared/ui/server_avatar.dart';
import 'package:keqdroid/shared/ui/scrolled_under.dart';
import 'package:keqdroid/shared/ui/server_picker_sheet.dart';
import 'package:keqdroid/shared/ui/shape_loading_indicator.dart';
import 'package:keqdroid/shared/ui/smooth_scroll.dart';

import '../../models/server_item.dart';
import '../../models/server_name_utils.dart';
import '../../providers/providers.dart';
import '../../utils/bidi.dart';
import '../../utils/error_messages.dart';
import '../../utils/proxy_chain.dart';

/// Сборка цепочки прокси: имя + порядок узлов.
///
/// Маршрут показан вертикально сверху вниз — «это устройство», узлы, «интернет»
/// — и живёт одной карточкой, как группа серверов на главной. Порядок и есть
/// смысл цепочки (первый узел набирает устройство, последний виден сайтам),
/// поэтому он и вынесен в главный элемент экрана, а не спрятан в список с
/// номерами.
class ChainEditorScreen extends ConsumerStatefulWidget {
  /// id уже существующей цепочки; null — создаём новую.
  final String? serverId;

  const ChainEditorScreen({super.key, this.serverId});

  @override
  ConsumerState<ChainEditorScreen> createState() => _ChainEditorScreenState();
}

class _ChainEditorScreenState extends ConsumerState<ChainEditorScreen> {
  final TextEditingController _name = TextEditingController();

  /// Узлы по порядку: вход → выход. Каждый — сервер (из списка либо
  /// восстановленный из снимка, если сервера уже нет).
  final List<ServerItem> _hops = [];

  /// Узлы, которых больше нет в списке серверов: подписываются отдельно, чтобы
  /// «сервер пропал» не выглядело как «цепочка сломалась».
  final Set<int> _detachedHopIndexes = {};

  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final id = widget.serverId;
    if (id == null) return;

    final servers = ref.read(serversProvider);
    final chain = servers.byId[id]?.chainConfig;
    if (chain == null) return;

    _name.text = chain.name;
    for (final hop in chain.hops) {
      final live = hop.serverId == null ? null : servers.byId[hop.serverId!];
      if (live != null) {
        _hops.add(live);
        continue;
      }
      // Сервер уехал вместе с подпиской — узел живёт снимком ссылки. Цепочка
      // от этого не ломается, но сказать об этом стоит.
      _detachedHopIndexes.add(_hops.length);
      _hops.add(ServerItem(
        id: hop.serverId ?? '',
        config: hop.config,
        type: ServerItemType.manual,
        customName: hop.name.isEmpty ? null : hop.name,
      ));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _isNew => widget.serverId == null;
  bool get _canSave => _hops.length >= 2 && !_saving;

  Future<void> _addHop() async {
    final all = ref.read(serversProvider).servers;
    final taken = {for (final h in _hops) h.id};
    final candidates = all
        .where((s) => ProxyChainConfig.canBeHop(s.protocol))
        // Один сервер дважды подряд смысла не имеет, но через один — вполне
        // (вход и выход через одну страну). Отсекаем только уже добавленные.
        .where((s) => !taken.contains(s.id))
        .toList();

    final picked = await showModalBottomSheet<ServerItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ServerPickerSheet(
        title: context.l10n.chainPickNode,
        searchHint: context.l10n.chainPickSearch,
        emptyText: context.l10n.chainPickEmpty,
        candidates: candidates,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _hops.add(picked);
      _error = null;
    });
    AppHaptics.selection();
  }

  void _removeHop(int index) {
    setState(() {
      _hops.removeAt(index);
      _detachedHopIndexes.remove(index);
      // Индексы «оторванных» узлов сдвигаются вместе со списком.
      final shifted =
          _detachedHopIndexes.map((i) => i > index ? i - 1 : i).toSet();
      _detachedHopIndexes
        ..clear()
        ..addAll(shifted);
      _error = null;
    });
  }

  /// [newIndex] уже пересчитан под удалённый элемент — это контракт
  /// `onReorderItem` (в отличие от старого `onReorder`).
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final hop = _hops.removeAt(oldIndex);
      _hops.insert(newIndex, hop);

      final moved = _detachedHopIndexes.contains(oldIndex);
      final rest = <int>{};
      for (final i in _detachedHopIndexes) {
        if (i == oldIndex) continue;
        var next = i;
        if (i > oldIndex) next -= 1;
        if (next >= newIndex) next += 1;
        rest.add(next);
      }
      if (moved) rest.add(newIndex);
      _detachedHopIndexes
        ..clear()
        ..addAll(rest);
    });
    AppHaptics.selection();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref.read(serversProvider.notifier).saveChain(
            id: widget.serverId,
            name: _name.text,
            hops: _hops,
          );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = explainErrorLocalized(e, l10n).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final textColor = AppTheme.text(context);
    final textLight = AppTheme.textLight(context);

    return Scaffold(
      backgroundColor: AppTheme.bg(context),
      appBar: ExpressiveScrolledUnderBar(
        builder: (context, background) => AppBar(
          backgroundColor: background,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isNew ? l10n.chainNew : l10n.chainTitle,
                style: theme.textTheme
                    .emphasized(theme.textTheme.titleMedium)
                    ?.copyWith(color: textColor),
              ),
              Text(
                l10n.chainNodesCount(_hops.length),
                style: theme.textTheme.bodySmall?.copyWith(color: textLight),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        // Один скролл на весь экран: маршрут — это sliver-карточка, внутри
        // которой перетаскиваемый список. Так декорация карточки рисуется на
        // всю длину маршрута (как у группы серверов), а не собирается из кусков
        // вокруг ReorderableListView.
        child: SmoothScroll(
          builder: (context, controller) => CustomScrollView(
            controller: controller,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                sliver: SliverToBoxAdapter(child: _nameField(l10n)),
              ),
              SliverToBoxAdapter(
                child: ExpressiveSectionHeader(
                  l10n.chainRouteLabel,
                  icon: Icons.route_rounded,
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                sliver: _routeCard(l10n),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverToBoxAdapter(child: _footnotes(l10n)),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _saveBar(l10n),
    );
  }

  Widget _nameField(AppLocalizations l10n) {
    final radius = ExpressiveShape.radius(ExpressiveShape.large);
    return TextField(
      controller: _name,
      maxLines: 1,
      textInputAction: TextInputAction.done,
      style: Theme.of(context)
          .textTheme
          .bodyLarge
          ?.copyWith(color: AppTheme.text(context)),
      decoration: InputDecoration(
        labelText: l10n.chainNameLabel,
        hintText: l10n.chainNameHint,
        prefixIcon: Icon(Icons.link_rounded, color: AppTheme.textLight(context)),
        filled: true,
        fillColor: AppTheme.card(context),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: AppTheme.divider(context)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: AppTheme.divider(context)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: AppTheme.accent(context), width: 2),
        ),
      ),
    );
  }

  /// Маршрут одной карточкой: «это устройство» → узлы → «добавить» → «интернет».
  ///
  /// Кнопка добавления стоит перед «интернетом», а не после: новый узел уходит
  /// в конец списка и становится выходным — там, где кнопка и нарисована.
  Widget _routeCard(AppLocalizations l10n) {
    return DecoratedSliver(
      decoration: BoxDecoration(
        color: AppTheme.card(context),
        borderRadius: ExpressiveShape.radius(ExpressiveShape.extraLarge),
        border: Border.all(color: AppTheme.divider(context), width: 1),
        // Нейтральная тень как высота — см. то же в server_groups.
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.10),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      sliver: SliverPadding(
        // 1px — чтобы содержимое не наезжало на рамку декорации.
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 1),
        sliver: SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: _EndpointNode(
                icon: Icons.smartphone_rounded,
                label: l10n.chainDeviceNode,
                lineAbove: false,
                lineBelow: true,
              ),
            ),
            SliverReorderableList(
              itemCount: _hops.length,
              onReorderItem: _reorder,
              proxyDecorator: (child, index, animation) => Material(
                color: AppTheme.card(context),
                elevation: 6,
                borderRadius:
                    ExpressiveShape.radius(ExpressiveShape.largeIncreased),
                shadowColor: AppTheme.accent(context).withValues(alpha: 0.4),
                child: child,
              ),
              itemBuilder: (context, index) => _HopRow(
                // Один сервер может стоять в цепочке дважды — ключ учитывает
                // и место.
                key: ValueKey('chain-hop-$index-${_hops[index].id}'),
                index: index,
                server: _hops[index],
                detached: _detachedHopIndexes.contains(index),
                isExit: index == _hops.length - 1,
                onRemove: () => _removeHop(index),
              ),
            ),
            SliverToBoxAdapter(child: _addNodeRow(l10n)),
            SliverToBoxAdapter(
              child: _EndpointNode(
                icon: Icons.public_rounded,
                label: l10n.chainInternetNode,
                lineAbove: true,
                lineBelow: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addNodeRow(AppLocalizations l10n) {
    final full = _hops.length >= ProxyChainConfig.maxHops;
    final accent = AppTheme.accent(context);
    final color = full ? AppTheme.textLight(context) : accent;

    return InkWell(
      onTap: full ? null : _addHop,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            _Rail(
              lineAbove: true,
              lineBelow: true,
              node: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // Смешиваем с фоном карточки, а не кладём полупрозрачным:
                  // кружок стоит поверх линии маршрута, и сквозь прозрачный
                  // фон она просвечивала — кнопка выглядела перечёркнутой.
                  color: Color.alphaBlend(
                    color.withValues(alpha: 0.15),
                    AppTheme.card(context),
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.add_rounded, size: 17, color: color),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                full
                    ? l10n.chainMaxNodes(ProxyChainConfig.maxHops)
                    : l10n.chainAddNode,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _footnotes(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error != null) ...[
          _banner(error, AppTheme.red(context), Icons.error_outline_rounded),
          const SizedBox(height: 8),
        ] else if (_hops.length < 2) ...[
          // Не ошибка, а требование к маршруту: красный баннер тут пугал бы
          // ровно в тот момент, когда пользователь ещё просто собирает цепочку.
          _banner(
            l10n.chainNeedsTwoNodes,
            AppTheme.textLight(context),
            Icons.info_outline_rounded,
          ),
          const SizedBox(height: 8),
        ],
        Text(
          l10n.chainHint,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppTheme.textLight(context), height: 1.35),
        ),
      ],
    );
  }

  Widget _banner(String message, Color color, IconData icon) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: ExpressiveShape.radius(ExpressiveShape.medium),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.text(context)),
              ),
            ),
          ],
        ),
      );

  Widget _saveBar(AppLocalizations l10n) => SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: FilledButton(
          onPressed: _canSave ? _save : null,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accentContainer(context),
            foregroundColor: AppTheme.onAccentContainer(context),
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: ExpressiveShape.radius(ExpressiveShape.large),
            ),
          ),
          child: _saving
              ? ShapeLoadingIndicator(
                  size: 20,
                  color: AppTheme.onAccentContainer(context),
                )
              : Text(l10n.chainSave),
        ),
      );
}

/// Ширина «рельса» маршрута — колонки с линией и кружком узла.
const double _railWidth = 44;
const double _nodeSize = 34;

/// Вертикальная линия маршрута плюс кружок узла поверх неё.
class _Rail extends StatelessWidget {
  final bool lineAbove;
  final bool lineBelow;
  final Widget node;

  const _Rail({
    required this.lineAbove,
    required this.lineBelow,
    required this.node,
  });

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.divider(context);
    Widget half(bool visible) => Expanded(
          child: Center(
            child: SizedBox(
              width: 2,
              height: double.infinity,
              child: ColoredBox(color: visible ? color : Colors.transparent),
            ),
          ),
        );

    return SizedBox(
      width: _railWidth,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: Column(children: [half(lineAbove), half(lineBelow)]),
          ),
          node,
        ],
      ),
    );
  }
}

/// Концевые точки маршрута — устройство и интернет. Не узлы цепочки, поэтому
/// они не перетаскиваются и не удаляются: это границы, а не звенья.
class _EndpointNode extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool lineAbove;
  final bool lineBelow;

  const _EndpointNode({
    required this.icon,
    required this.label,
    required this.lineAbove,
    required this.lineBelow,
  });

  @override
  Widget build(BuildContext context) {
    final textLight = AppTheme.textLight(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          _Rail(
            lineAbove: lineAbove,
            lineBelow: lineBelow,
            node: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.inset(context),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 15, color: textLight),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: textLight),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

/// Узел цепочки: кружок на рельсе + имя, адрес и ручка перетаскивания.
///
/// Высоту задаёт содержимое, а не константа: при крупном системном шрифте
/// фиксированные 72px не вмещали две строки, и ряд рвало на overflow.
/// `IntrinsicHeight` делает высоту Row известной — только поэтому здесь
/// допустим `stretch`, которым рельс дотягивается до краёв строки.
class _HopRow extends StatelessWidget {
  final int index;
  final ServerItem server;
  final bool detached;
  final bool isExit;
  final VoidCallback onRemove;

  const _HopRow({
    super.key,
    required this.index,
    required this.server,
    required this.detached,
    required this.isExit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final textLight = AppTheme.textLight(context);
    final name = ServerNameUtils.formatForDisplay(
      ServerNameUtils.cleanDisplayName(server.displayName),
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Rail(
            lineAbove: true,
            lineBelow: true,
            node: ServerAvatar(
              flag: server.flag,
              protocol: server.protocol,
              size: _nodeSize,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(color: AppTheme.text(context)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detached
                              ? l10n.chainNodeMissing
                              : ltrIsolate('${server.address}:${server.port}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color:
                                detached ? AppTheme.orange(context) : textLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isExit)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 4),
                      child: Tooltip(
                        message: l10n.chainExitNodeHint,
                        child: Icon(
                          Icons.public_rounded,
                          size: 16,
                          color: AppTheme.accent(context),
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: l10n.chainRemoveNode,
                    onPressed: onRemove,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded, size: 18, color: textLight),
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 8,
                      ),
                      child: Icon(
                        Icons.drag_handle_rounded,
                        size: 20,
                        color: textLight,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
