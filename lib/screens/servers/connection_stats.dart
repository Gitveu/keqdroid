part of '../servers_tab.dart';

String _formatVpnRate(int? bytesPerSec) {
  if (bytesPerSec == null || bytesPerSec <= 0) return '0 B/s';
  return '${_formatVpnBytes(bytesPerSec)}/s';
}

String _formatVpnBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '0 B';
  const kb = 1024.0;
  const mb = kb * 1024;
  const gb = mb * 1024;
  final b = bytes.toDouble();
  if (b >= gb) return '${(b / gb).toStringAsFixed(2)} GB';
  if (b >= mb) return '${(b / mb).toStringAsFixed(1)} MB';
  if (b >= kb) return '${(b / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}

String _formatVpnDuration(Duration? d) {
  if (d == null) return '0s';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

class _ConnectionStats extends ConsumerWidget {
  const _ConnectionStats({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (showTraffic, showTime, showSplit) = ref.watch(
      settingsNotifierProvider.select((async) {
        final s = async.value ?? const AppSettings();
        return (s.showTrafficStats, s.showConnectionTime, s.showTrafficSplit);
      }),
    );
    final showAnyTraffic = showTraffic || showSplit;
    if (!showAnyTraffic && !showTime) return const SizedBox.shrink();

    final stats = ref.watch(
      vpnStateProvider.select((a) {
        final v = a.value;
        if (v == null) return (null, null, null, null);
        return (v.downloadSpeed, v.uploadSpeed, v.totalDownload, v.duration);
      }),
    );

    final split = showSplit ? ref.watch(trafficSplitProvider).value : null;

    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: ExpressiveSpacing.medium),
      child: StatStrip(
        metrics: [
          if (showAnyTraffic) ...[
            if (split != null) ...[
              _channelMetric(
                l10n,
                tag: l10n.statsSplitVpnTag,
                label: l10n.statsSplitVpnLabel,
                traffic: split.vpn,
              ),
              _channelMetric(
                l10n,
                tag: l10n.statsSplitDirectTag,
                label: l10n.statsSplitDirectLabel,
                traffic: split.direct,
              ),
            ] else ...[
              StatMetric(
                icon: Icons.arrow_downward_rounded,
                label: l10n.statsDownloadLabel,
                value: _formatVpnRate(stats.$1),
                template: _kRateTemplate,
              ),
              StatMetric(
                icon: Icons.arrow_upward_rounded,
                label: l10n.statsUploadLabel,
                value: _formatVpnRate(stats.$2),
                template: _kRateTemplate,
              ),
              StatMetric(
                icon: Icons.data_usage_rounded,
                label: l10n.statsInLabel,
                value: _formatVpnBytes(stats.$3),
                template: _kBytesTemplate,
              ),
            ],
          ],
          if (showTime)
            StatMetric(
              icon: Icons.schedule_rounded,
              label: l10n.statsTimeLabel,
              value: _formatVpnDuration(stats.$4),
              template: _kDurationTemplate,
            ),
        ],
      ),
    );
  }
}

StatMetric _channelMetric(
  AppLocalizations l10n, {
  required String tag,
  required String label,
  required ChannelTraffic traffic,
}) =>
    StatMetric.channel(
      tag: tag,
      label: label,
      lines: [
        StatLine(
          icon: Icons.arrow_downward_rounded,
          label: l10n.statsDownloadLabel,
          value: _formatVpnRate(traffic.downloadSpeed),
          template: _kRateTemplate,
        ),
        StatLine(
          icon: Icons.arrow_upward_rounded,
          label: l10n.statsUploadLabel,
          value: _formatVpnRate(traffic.uploadSpeed),
          template: _kRateTemplate,
        ),
        StatLine(
          icon: Icons.data_usage_rounded,
          label: l10n.statsSplitTotalLabel,
          value: _formatVpnBytes(traffic.total),
          template: _kBytesTemplate,
        ),
      ],
    );

const _kRateTemplate = '999.9 MB/s';
const _kBytesTemplate = '999.99 GB';
const _kDurationTemplate = '59m 59s';

