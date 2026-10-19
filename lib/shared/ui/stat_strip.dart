library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'halloween/halloween_icons.dart';

import '../../utils/bidi.dart';
import 'expressive.dart';

class StatLine {
  final IconData icon;

  final String label;

  final String value;

  final String template;

  const StatLine({
    required this.icon,
    required this.label,
    required this.value,
    required this.template,
  });
}

class StatMetric {
  final String tag;

  final String label;

  final List<StatLine> lines;

  StatMetric({
    required IconData icon,
    required String label,
    required String value,
    required String template,
  })  : tag = '',
        label = label,
        lines = [
          StatLine(icon: icon, label: label, value: value, template: template),
        ];

  const StatMetric.channel({
    required this.tag,
    required this.label,
    required this.lines,
  });
}

class StatStrip extends StatelessWidget {
  final List<StatMetric> metrics;

  const StatStrip({super.key, required this.metrics});

  static const double _cellPadding = ExpressiveSpacing.medium;
  static const double _gap = 6;


  static const double _divider = 1;

  @override
  Widget build(BuildContext context) {
    if (metrics.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = metrics
            .map((m) => _cellWidth(context, m))
            .reduce(max);
        final columns = statStripColumns(
          count: metrics.length,
          cellWidth: cellWidth,
          dividerWidth: _divider,
          maxWidth: constraints.maxWidth,
        );

        final rows = <List<StatMetric>>[];
        for (var i = 0; i < metrics.length; i += columns) {
          rows.add(metrics.skip(i).take(columns).toList());
        }

        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: ExpressiveShape.radius(ExpressiveShape.large),
          ),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var r = 0; r < rows.length; r++) ...[
                  if (r > 0)
                    Divider(
                      height: _divider,
                      thickness: _divider,
                      indent: _cellPadding,
                      endIndent: _cellPadding,
                      color: scheme.outlineVariant,
                    ),
                  _buildRow(context, rows[r], cellWidth, columns),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(
    BuildContext context,
    List<StatMetric> row,
    double cellWidth,
    int columns,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < columns; i++) ...[
          if (i > 0)
            Container(
              width: _divider,
              height: 20,
              color: scheme.outlineVariant,
            ),
          SizedBox(
            width: cellWidth,
            child: i < row.length ? _buildCell(context, row[i]) : null,
          ),
        ],
      ],
    );
  }

  Widget _buildCell(BuildContext context, StatMetric metric) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final valueStyle = _valueStyle(theme);
    final tagWidth = _tagWidth(context, metric, _tagStyle(theme));
    final slotWidth = _slotWidth(context, metric, valueStyle);

    return Semantics(
      label: metric.label,
      value: metric.lines.length == 1
          ? metric.lines.first.value
          : [
              for (final line in metric.lines) '${line.label} ${line.value}',
            ].join(', '),
      // иначе для скринридера подпись ячейки слилась бы со значением в одну строку
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _cellPadding,
          vertical: 10,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (tagWidth > 0) ...[
              SizedBox(
                width: tagWidth,
                child: Text(
                  metric.tag,
                  style: _tagStyle(theme),
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: _gap),
            ],
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in metric.lines)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SeasonalIcon(
                        line.icon,
                        size: ExpressiveIconSize.inline,
                        color: color,
                      ),
                      const SizedBox(width: _gap),
                      SizedBox(
                        width: slotWidth,
                        child: Text(
                          // в фарси цифры и латиница вокруг пробела переставляются: MB/s 1.5
                          ltrIsolate(line.value),
                          style: valueStyle,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double _cellWidth(BuildContext context, StatMetric metric) {
    final theme = Theme.of(context);
    final tagWidth = _tagWidth(context, metric, _tagStyle(theme));
    return _cellPadding * 2 +
        (tagWidth > 0 ? tagWidth + _gap : 0) +
        ExpressiveIconSize.inline +
        _gap +
        _slotWidth(context, metric, _valueStyle(theme));
  }

  static TextStyle? _valueStyle(ThemeData theme) =>
      theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurface,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle? _tagStyle(ThemeData theme) =>
      theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );

  static double _tagWidth(
    BuildContext context,
    StatMetric metric,
    TextStyle? style,
  ) =>
      metric.tag.isEmpty
          ? 0
          : _measure(context, metric.tag, style).ceilToDouble();

  static double _slotWidth(
    BuildContext context,
    StatMetric metric,
    TextStyle? style,
  ) {
    var width = 0.0;
    for (final line in metric.lines) {
      // образец в той же обёртке: изоляторы для движка обычные символы со своей шириной
      width = max(width, _measure(context, ltrIsolate(line.template), style));
      width = max(width, _measure(context, ltrIsolate(line.value), style));
    }
    return width.ceilToDouble();
  }

  static double _measure(BuildContext context, String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

int statStripColumns({
  required int count,
  required double cellWidth,
  required double dividerWidth,
  required double maxWidth,
}) {
  if (count <= 1) return 1;
  bool fits(int columns) =>
      columns * cellWidth + (columns - 1) * dividerWidth <= maxWidth;

  for (final columns in <int>{count, (count / 2).ceil(), 2, 1}) {
    if (columns >= 1 && fits(columns)) return columns;
  }
  return 1;
}
