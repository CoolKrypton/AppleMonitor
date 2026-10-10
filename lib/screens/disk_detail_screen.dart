import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pc_status.dart';
import '../responsive/responsive.dart';
import '../services/monitor_provider.dart';
import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';
import '../util/format.dart';
import '../widgets/hud.dart';
import '../widgets/monitor_scaffold.dart';
import '../widgets/sparkline.dart';

/// Disk detail: one card per physical disk with live read / write, activity and
/// temperature.
///
/// Ported from `ui_disk_detail.c`. The firmware lays the cards out in 1 column
/// on the 480x480 build and 2 columns on the 800x480 build; here the column
/// count follows the available width, so the same card serves a phone and a
/// tablet.
class DiskDetailScreen extends StatelessWidget {
  const DiskDetailScreen({
    super.key,
    required this.provider,
    required this.onHome,
  });

  final MonitorProvider provider;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final PcStatus target = provider.target;
    final PcStatus display = provider.display;

    // Aggregate throughput shown in the header, matching the dashboard tile.
    final double totalRead = target.disks.fold<double>(
      0,
      (double sum, DiskStatus d) => sum + (d.readValid ? d.readMbS : 0),
    );
    final double totalWrite = target.disks.fold<double>(
      0,
      (double sum, DiskStatus d) => sum + (d.writeValid ? d.writeMbS : 0),
    );
    final bool anyRead = target.disks.any((DiskStatus d) => d.readValid);
    final bool anyWrite = target.disks.any((DiskStatus d) => d.writeValid);

    return MonitorScaffold(
      title: 'DISK / DETAIL',
      subtitle: target.diskCount == 0
          ? 'PHYSICAL DISKS / LIVE I/O'
          : '${target.diskCount} PHYSICAL DISKS / LIVE I/O',
      accent: theme.cpu,
      leading: BackButtonHud(label: 'HOME', onPressed: onHome, accent: theme.text),
      body: Padding(
        padding: EdgeInsets.fromLTRB(
          metrics.pagePadding,
          0,
          metrics.pagePadding,
          metrics.gutter,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            HudPanel(
              radius: metrics.panelRadius,
              accent: theme.cpu.withValues(alpha: 0.5),
              padding: EdgeInsets.all(metrics.panelPadding),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: MetricLine(
                      label: 'Total read',
                      value: uiFormatRate(totalRead, anyRead),
                      valueColor: theme.cpu,
                      valueFontSize: metrics.font(16),
                      labelFontSize: metrics.font(10),
                    ),
                  ),
                  SizedBox(width: metrics.gutter),
                  Expanded(
                    child: MetricLine(
                      label: 'Total write',
                      value: uiFormatRate(totalWrite, anyWrite),
                      valueColor: theme.gpu,
                      valueFontSize: metrics.font(16),
                      labelFontSize: metrics.font(10),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: metrics.gutter),
            Expanded(
              child: target.diskCount == 0
                  ? _empty(theme, metrics)
                  : _list(context, metrics, target, display),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(MonitorTheme theme, LayoutMetrics metrics) {
    return Center(
      child: Text(
        'No physical disk data',
        style: TextStyle(color: theme.muted, fontSize: metrics.font(13)),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    LayoutMetrics metrics,
    PcStatus target,
    PcStatus display,
  ) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = metrics.cardColumns(constraints.maxWidth);
        final int rows = (target.diskCount + columns - 1) ~/ columns;
        final double cardWidth =
            (constraints.maxWidth - metrics.gutter * (columns - 1)) / columns;
        // A landscape phone leaves very little height, so the cards take
        // exactly what their row can afford rather than a fixed floor that
        // would spill past the bottom edge and force the grid to scroll. The
        // gap is counted once, and the trailing row carries no extra gap, so
        // `rows * cardHeight + gaps` lands exactly on the viewport height.
        final double rowGap = metrics.gutter;
        final double perRow =
            (constraints.maxHeight - rowGap * (rows - 1)) / rows;
        // `comfortable` is the height the card likes, `need` the height it can
        // still render five lines in, `minimum` the floor for a tiny viewport.
        const double comfortable = 140.0;
        const double need = 112.0;
        const double minimum = 100.0;
        final double cardHeight = perRow >= comfortable
            ? math.min(perRow, 300.0)
            : math.max(minimum, perRow);
        // Only when the row cannot even give the card `need` do the contents
        // (fonts, padding, bar) compress, and then only as far as required, so
        // a landscape phone gets short cards without shrinking every label.
        // The outer geometry keeps the uncompressed metrics.
        final double factor =
            math.max(0.78, math.min(1.0, cardHeight / need));
        final LayoutMetrics cardMetrics =
            cardHeight < need ? metrics.compressed(factor) : metrics;
        // Centre the grid vertically when it is shorter than the viewport.
        final double gridHeight = rows * cardHeight + rowGap * (rows - 1);
        final double topPadding =
            math.max(0, (constraints.maxHeight - gridHeight) / 2);

        return ListView.builder(
          padding: EdgeInsets.only(top: topPadding),
          itemCount: rows,
          itemBuilder: (BuildContext context, int row) {
            return Padding(
              padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : rowGap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List<Widget>.generate(columns, (int column) {
                  final int index = row * columns + column;
                  if (index >= target.diskCount) {
                    return SizedBox(width: cardWidth);
                  }
                  final DiskStatus disk = target.disks[index];
                  final DiskStatus? displayDisk = _matchDisk(display, disk);
                  return Padding(
                    padding: EdgeInsets.only(
                      right: column == columns - 1 ? 0 : metrics.gutter,
                    ),
                    child: SizedBox(
                      width: cardWidth,
                      height: cardHeight,
                      child: LayoutScope(
                        metrics: cardMetrics,
                        child: _DiskCard(
                          disk: disk,
                          displayDisk: displayDisk,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            );
          },
        );
      },
    );
  }

  /// Disks pair by protocol id, falling back to name - same rule as the
  /// smoother uses.
  static DiskStatus? _matchDisk(PcStatus display, DiskStatus target) {
    if (target.protocolId.isNotEmpty) {
      for (final DiskStatus candidate in display.disks) {
        if (candidate.protocolId == target.protocolId) return candidate;
      }
    }
    for (final DiskStatus candidate in display.disks) {
      if (candidate.name.isNotEmpty && candidate.name == target.name) {
        return candidate;
      }
    }
    return null;
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({required this.disk, required this.displayDisk});

  final DiskStatus disk;
  final DiskStatus? displayDisk;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    final double activity = displayDisk?.activity.toDouble() ?? 0;

    return HudPanel(
      radius: metrics.panelRadius,
      accent: theme.border,
      padding: EdgeInsets.all(metrics.panelPadding),
      semanticLabel: disk.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        // Spread evenly so a stretched card (fill layout) distributes the
        // slack across two balanced gaps instead of one dead band.
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.storage, color: theme.muted, size: metrics.px(14)),
              SizedBox(width: metrics.px(6)),
              Expanded(
                child: Text(
                  disk.name.isEmpty ? 'Unknown disk' : disk.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(13),
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: MetricLine(
                  label: 'Read',
                  value: uiFormatRate(disk.readMbS, disk.readValid),
                  valueColor: theme.cpu,
                  valueFontSize: metrics.font(15),
                  labelFontSize: metrics.font(10),
                ),
              ),
              SizedBox(width: metrics.gutter),
              Expanded(
                child: MetricLine(
                  label: 'Write',
                  value: uiFormatRate(disk.writeMbS, disk.writeValid),
                  valueColor: theme.gpu,
                  valueFontSize: metrics.font(15),
                  labelFontSize: metrics.font(10),
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      disk.activityValid
                          ? 'Activity  ${disk.activity}%'
                          : 'Activity  --%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.muted,
                        fontSize: metrics.font(11),
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: metrics.px(8)),
                  Text(
                    disk.tempValid
                        ? 'Temp  ${disk.temp.toStringAsFixed(1)} C'
                        : 'Temp  -- C',
                    maxLines: 1,
                    style: TextStyle(
                      color: isHot(disk.temp, disk.tempValid) ? theme.hot : theme.muted,
                      fontSize: metrics.font(11),
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: metrics.px(8)),
              HudBar(
                value: activity,
                color: theme.cpu,
                valid: disk.activityValid,
                height: metrics.px(5),
                glow: 0.35,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The per-disk throughput sparkline shown in the wide layout, retained as a
/// building block for a future disk-detail expansion.
class DiskSparkline extends StatelessWidget {
  const DiskSparkline({super.key, required this.points, required this.color});

  final List<double?> points;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Sparkline(points: points, color: color, maxY: 100);
  }
}
