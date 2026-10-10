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

/// CPU detail: package sensors on top, then the logical core list.
///
/// The firmware places 4-6 headline numbers in a fixed 448x128 card and the
/// cores in a scrollable list below. Here the headline block is a responsive
/// wrap of tiles (2 across on phones, 6 across on wide layouts) and the core
/// list picks 2 / 3 / 4 columns from the available width.
class CpuDetailScreen extends StatelessWidget {
  const CpuDetailScreen({
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

    const List<double> coreWeights = <double>[];

    return MonitorScaffold(
      title: 'CPU / DETAIL',
      subtitle: target.cpuName.isEmpty ? 'PROCESSOR' : target.cpuName,
      accent: theme.cpu,
      leading: BackButtonHud(label: 'HOME', onPressed: onHome, accent: theme.text),
      actions: <Widget>[_modeHint(metrics, theme)],
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
            _PackageBlock(
              target: target,
              display: display,
              accent: theme.cpu,
              coreWeights: coreWeights,
            ),
            SizedBox(height: metrics.gutter),
            SectionHeader(
              title: 'Logical cores / threads',
              accent: theme.cpu,
              trailing: Text(
                '${target.cpuCoreCount} TOTAL',
                style: TextStyle(
                  color: theme.muted,
                  fontSize: metrics.font(10),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            SizedBox(height: metrics.gutter * 0.8),
            Expanded(
              child: _CoreList(
                target: target,
                display: display,
                accent: theme.cpu,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeHint(LayoutMetrics metrics, MonitorTheme theme) {
    return Text(
      '${metrics.screenClass.name.toUpperCase()} / ${metrics.isPortrait ? 'PORTRAIT' : 'LANDSCAPE'}',
      style: TextStyle(
        color: theme.muted,
        fontSize: metrics.font(9),
        letterSpacing: 0.8,
      ),
    );
  }
}

/// The headline sensor block: total load, temperature, power, frequency,
/// threads. Each field degrades to its own placeholder when invalid.
class _PackageBlock extends StatelessWidget {
  const _PackageBlock({
    required this.target,
    required this.display,
    required this.accent,
    required this.coreWeights,
  });

  final PcStatus target;
  final PcStatus display;
  final Color accent;
  final List<double> coreWeights;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    // Columns follow the AVAILABLE WIDTH, not the short side - otherwise a
    // landscape phone (852 wide) would wrap five numbers into two cramped
    // rows and eat 40% of the screen height.
    return HudPanel(
      radius: metrics.panelRadius,
      accent: accent.withValues(alpha: 0.5),
      padding: EdgeInsets.all(metrics.panelPadding),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool landscape = metrics.isLandscape;

          final List<Widget> tiles = <Widget>[
            MetricLine(
              label: 'Total load',
              value: fmtPercent(target.cpuUsage, target.cpuUsageValid),
              valueColor: theme.text,
              valueFontSize: metrics.font(landscape ? 18 : 22),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'Temperature',
              value: fmtTemp(target.cpuTemp, target.cpuTempValid),
              valueColor: isHot(target.cpuTemp, target.cpuTempValid)
                  ? theme.hot
                  : theme.text,
              valueFontSize: metrics.font(landscape ? 13 : 15),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'Power',
              value: fmtPower(target.cpuPower, target.cpuPowerValid),
              valueFontSize: metrics.font(landscape ? 13 : 15),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'Frequency',
              value: fmtClock(target.cpuClock, target.cpuClockValid),
              valueColor: accent,
              valueFontSize: metrics.font(landscape ? 13 : 15),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'Threads',
              value: target.cpuCoreCount == 0
                  ? Ph.count
                  : '${target.cpuCoreCount}',
              valueFontSize: metrics.font(landscape ? 13 : 15),
              labelFontSize: metrics.font(10),
            ),
          ];

          // Landscape summary is a strict two-row block: every parameter on
          // one line, the bar on the second. The core list below gets the
          // vertical space the wrapped second row used to burn.
          final int columns = landscape
              ? tiles.length
              : (constraints.maxWidth / (150 * metrics.scale))
                  .floor()
                  .clamp(2, 5);
          final double tileWidth = (constraints.maxWidth -
                  metrics.gutter * (columns - 1)) /
              columns;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                spacing: metrics.gutter,
                runSpacing: metrics.gutter * 0.5,
                children: tiles
                    .map((Widget tile) =>
                        SizedBox(width: tileWidth, child: tile))
                    .toList(),
              ),
              SizedBox(height: metrics.gutter * 0.7),
              HudBar(
                value: display.cpuUsage.toDouble(),
                color: accent,
                valid: target.cpuUsageValid,
                height: metrics.px(6),
                gradientTo: accent.withValues(alpha: 0.6),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The scrollable core list. Column count is derived from width, so a phone
/// shows two cores per row and a tablet landscape shows four - the same
/// 2/4 split the two firmware builds use.
class _CoreList extends StatelessWidget {
  const _CoreList({
    required this.target,
    required this.display,
    required this.accent,
  });

  final PcStatus target;
  final PcStatus display;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    if (target.cpuCoreCount == 0) {
      return Center(
        child: Text(
          'No logical core data',
          style: TextStyle(color: theme.muted, fontSize: metrics.font(13)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = metrics.listColumns(
          constraints.maxWidth,
          minItemWidth: constraints.maxWidth < 380 ? 130 : 150,
        );
        final double totalSpacing = metrics.gutter * (columns - 1);
        final double itemWidth =
            (constraints.maxWidth - totalSpacing) / columns;
        const double rowHeight = 46;
        // ListView hands its items an unbounded height. A stretch Row with no
        // fixed extent collapses to zero inside that, which erased the whole
        // core grid on device - so every row is given an explicit height.
        final double rowExtent = rowHeight * metrics.scale.clamp(0.85, 1.6);

        return ListView.builder(
          padding: EdgeInsets.only(bottom: metrics.gutter),
          itemCount: (target.cpuCoreCount / columns).ceil(),
          itemBuilder: (BuildContext context, int row) {
            return Padding(
              padding: EdgeInsets.only(bottom: metrics.gutter * 0.75),
              child: SizedBox(
                height: rowExtent,
                child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: List<Widget>.generate(columns, (int column) {
                  final int index = row * columns + column;
                  if (index >= target.cpuCoreCount) {
                    return SizedBox(width: itemWidth);
                  }
                  return Padding(
                    padding: EdgeInsets.only(
                      right: column == columns - 1 ? 0 : metrics.gutter,
                    ),
                    child: SizedBox(
                      width: itemWidth,
                      child: _CoreRow(
                        index: index,
                        target: target,
                        display: display,
                        accent: accent,
                        height: rowHeight * metrics.scale.clamp(0.85, 1.6),
                      ),
                    ),
                  );
                }),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CoreRow extends StatelessWidget {
  const _CoreRow({
    required this.index,
    required this.target,
    required this.display,
    required this.accent,
    required this.height,
  });

  final int index;
  final PcStatus target;
  final PcStatus display;
  final Color accent;
  final double height;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    final bool valid =
        index < target.cpuCoreValid.length && target.cpuCoreValid[index];
    final int value =
        index < target.cpuCoreValues.length ? target.cpuCoreValues[index] : 0;
    final int id = index < target.cpuCoreIds.length
        ? target.cpuCoreIds[index]
        : index + 1;
    final double displayValue = index < display.cpuCoreValues.length
        ? display.cpuCoreValues[index].toDouble()
        : value.toDouble();

    return HudPanel(
      radius: metrics.panelRadius * 0.65,
      accent: theme.border,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.px(10),
        vertical: metrics.px(8),
      ),
      semanticLabel: 'Core $id',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Core $id',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(11),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                valid ? '$value%' : Ph.percent,
                style: TextStyle(
                  color: theme.text,
                  fontSize: metrics.font(12),
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: metrics.px(6)),
          HudBar(
            value: displayValue,
            color: accent,
            valid: valid,
            height: metrics.px(4),
            glow: 0.3,
          ),
        ],
      ),
    );
  }
}

/// Unused but kept for parity with the firmware's "SCROLL TO EXPLORE" hint.
class CoreScrollHint extends StatelessWidget {
  const CoreScrollHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    return Row(
      children: <Widget>[
        Icon(Icons.swipe_vertical, size: 13, color: theme.muted),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(color: theme.muted, fontSize: 10, letterSpacing: 0.7),
        ),
      ],
    );
  }
}

/// Re-exported so the detail screens share one sparkline import site.
typedef DetailSparkline = Sparkline;
