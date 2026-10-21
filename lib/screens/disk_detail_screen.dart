import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/history_window.dart';
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
                  final String historyKey = MonitorProvider.diskHistoryKey(disk);
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
                          readHistory: provider.diskReadHistoryFor(historyKey),
                          writeHistory: provider.diskWriteHistoryFor(historyKey),
                          showChart: _showsChart(metrics, cardHeight),
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

  /// Whether a card gets the throughput plot.
  ///
  /// Portrait only. The plot is the only part of the card that can be given up
  /// without losing a reading, and landscape is exactly where the card has no
  /// height to give: there the grid is two or three columns of short cards, so
  /// a curve would cost the card its numbers instead of filling slack.
  ///
  /// [kChartMinCardHeight] is the height at which a card can carry the caption,
  /// the plot and its own six lines without any of them being squeezed -
  /// measured against the card's content, not guessed. Below it the card keeps
  /// its numbers and drops the plot, which is the honest trade for a phone with
  /// more disks than screen.
  static const double kChartMinCardHeight = 150.0;

  static bool _showsChart(LayoutMetrics metrics, double cardHeight) =>
      metrics.isPortrait && cardHeight >= kChartMinCardHeight;
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({
    required this.disk,
    required this.displayDisk,
    required this.readHistory,
    required this.writeHistory,
    required this.showChart,
  });

  final DiskStatus disk;
  final DiskStatus? displayDisk;

  /// This disk's own 60 s windows, drawn as the card's dynamic plot. Whole
  /// windows, times included: the plot is placed by time, not by index.
  final HistoryWindow readHistory;
  final HistoryWindow writeHistory;

  /// Portrait cards only: whether the card is tall enough to carry the plot.
  final bool showChart;

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
          // The curve sits directly under the two numbers it is the history
          // of, in the same two colours, and takes whatever height the card
          // was given beyond its text: that dead band is what the tall
          // portrait card had, and the reason the plot lives here at all.
          if (showChart)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: metrics.px(8)),
                child: DiskIoChart(
                  readWindow: readHistory,
                  writeWindow: writeHistory,
                  readColor: theme.cpu,
                  writeColor: theme.gpu,
                ),
              ),
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

/// The per-disk dynamic plot: read and write throughput over the last 60 s.
///
/// Replaces the unused `DiskSparkline` stub that stood here - it was left as a
/// placeholder for exactly this expansion, and it had a hard-coded 0..100
/// scale that only made sense while the plot was going to be activity, not
/// throughput.
///
/// Read and write share one plot because they share one unit and one disk:
/// separate plots would halve the resolution of both, and a stacked one would
/// make the two indistinguishable at this size. The colours are the card's own
/// Read and Write colours, so the legend is a restatement rather than news.
class DiskIoChart extends StatelessWidget {
  const DiskIoChart({
    super.key,
    required this.readWindow,
    required this.writeWindow,
    required this.readColor,
    required this.writeColor,
  });

  final HistoryWindow readWindow;
  final HistoryWindow writeWindow;
  final Color readColor;
  final Color writeColor;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '60s',
              style: TextStyle(
                color: theme.muted,
                fontSize: metrics.font(9),
                letterSpacing: 0.6,
              ),
            ),
            const Spacer(),
            _SeriesKey(label: 'READ', color: readColor),
            SizedBox(width: metrics.px(8)),
            _SeriesKey(label: 'WRITE', color: writeColor),
          ],
        ),
        SizedBox(height: metrics.px(4)),
        Expanded(
          child: Sparkline(
            points: readWindow.values,
            times: readWindow.timesMs,
            color: readColor,
            secondaryPoints: writeWindow.values,
            secondaryTimes: writeWindow.timesMs,
            secondaryColor: writeColor,
            maxY: sparklineCeiling(
              <List<double?>>[readWindow.values, writeWindow.values],
            ),
            strokeWidth: 1.3,
          ),
        ),
      ],
    );
  }
}

/// One entry of the plot's legend: a short dash in the series colour and its
/// name. Sized to stay legible next to the axis label without becoming the
/// loudest thing on the card.
class _SeriesKey extends StatelessWidget {
  const _SeriesKey({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: metrics.px(8),
          height: metrics.px(2.5),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(metrics.px(1.5)),
          ),
        ),
        SizedBox(width: metrics.px(4)),
        Text(
          label,
          style: TextStyle(
            color: theme.muted,
            fontSize: metrics.font(9),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}
