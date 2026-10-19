import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/server_group.dart';
import '../../models/subscription_card_theme.dart';
import '../../providers/providers.dart';
import '../../services/subscription_accent_service.dart';
import '../../shared/ui/expressive.dart';
import '../../shared/ui/halloween/halloween_icons.dart';
import '../../shared/ui/server_group_anchors.dart';

class SidebarGroupNav extends ConsumerWidget {
  final bool compact;

  final VoidCallback onOpenServers;

  const SidebarGroupNav({
    super.key,
    required this.compact,
    required this.onOpenServers,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serversProvider.select((s) => s.servers));
    final subs = ref.watch(subscriptionsProvider).value ?? const [];

    final groups = buildServerGroups(servers: servers, subscriptions: subs);
    if (groups.length < 2) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;

    return Expanded(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 14, 16, 6),
                child: Text(
                  l10n.sidebarJumpTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              )
            else
              const SizedBox(height: 12),
            Flexible(
              child: ValueListenableBuilder<String?>(
                valueListenable: ServerGroupAnchors.instance.currentGroup,
                builder: (context, currentKey, _) => ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    return _GroupJumpTile(
                      group: group,
                      compact: compact,
                      selected: group.key == currentKey,
                      title: _titleFor(group, l10n),
                      onTap: () {
                        onOpenServers();
                        // список мог ещё ни разу не строиться, прыгаем после кадра, когда якоря на месте
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          unawaited(
                            ServerGroupAnchors.instance.jumpTo(group.key),
                          );
                        });
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _titleFor(ServerGroupRef group, AppLocalizations l10n) =>
      switch (group.kind) {
        ServerGroupKind.chains => l10n.chainGroupTitle,
        ServerGroupKind.manual => l10n.serversManualGroup,
        ServerGroupKind.subscription => group.subscriptionName.isEmpty
            ? l10n.serversManualGroup
            : group.subscriptionName,
      };
}

class _GroupJumpTile extends StatefulWidget {
  final ServerGroupRef group;
  final String title;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  const _GroupJumpTile({
    required this.group,
    required this.title,
    required this.compact,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_GroupJumpTile> createState() => _GroupJumpTileState();
}

class _GroupJumpTileState extends State<_GroupJumpTile> {
  Color? _seed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAccent();
  }

  @override
  void didUpdateWidget(_GroupJumpTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.subscription?.cardThemeId !=
        widget.group.subscription?.cardThemeId) {
      _syncAccent();
    }
  }

  void _syncAccent() {
    final themeId = widget.group.subscription?.cardThemeId ?? '';
    if (themeId.isEmpty || resolveCardTheme(themeId).isPlain) {
      if (_seed != null) setState(() => _seed = null);
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    final cached = SubscriptionAccentService.cached(
      themeId: themeId,
      scheme: scheme,
    );
    if (cached != null) {
      if (cached.seed != _seed) setState(() => _seed = cached.seed);
      return;
    }
    unawaited(() async {
      final accent = await SubscriptionAccentService.resolve(
        themeId: themeId,
        scheme: scheme,
      );
      if (!mounted) return;
      if ((widget.group.subscription?.cardThemeId ?? '') != themeId) return;
      if (accent?.seed != _seed) setState(() => _seed = accent?.seed);
    }());
  }

  IconData get _icon => switch (widget.group.kind) {
        ServerGroupKind.chains => Icons.link_rounded,
        ServerGroupKind.manual => Icons.edit_rounded,
        ServerGroupKind.subscription => Icons.cloud_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final shape = BorderRadius.circular(ExpressiveShape.full);
    final accent = _seed ?? scheme.primary;
    final fg =
        widget.selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    final count = widget.group.servers.length;

    final pill = Material(
      color: widget.selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: shape,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: shape,
        child: widget.compact
            ? SizedBox(height: 40, child: SeasonalIcon(_icon, size: 20, color: accent))
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (widget.selected
                                ? textTheme.emphasized(textTheme.labelMedium)
                                : textTheme.labelMedium)
                            ?.copyWith(color: fg),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$count',
                      style: textTheme.labelSmall?.copyWith(
                        color: fg.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: widget.compact
          ? Tooltip(
              message: '${widget.title}  ($count)',
              waitDuration: const Duration(milliseconds: 400),
              child: pill,
            )
          : pill,
    );
  }
}
