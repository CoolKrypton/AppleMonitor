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

/// The GPU device list.
///
/// Behaviour is copied from `ui_gpu_detail.c`:
/// * one card per adapter, showing a traffic-light metric summary;
/// * the adapter currently feeding the dashboard carries a `HOME` badge;
/// * **tapping a card both promotes it to the dashboard adapter and opens its
///   detail page** - a single tap does two things, matching `choose_gpu()`.
class GpuSelectorScreen extends StatelessWidget {
  const GpuSelectorScreen({
    super.key,
    required this.provider,
    required this.onHome,
    required this.onChoose,
  });

  final MonitorProvider provider;
  final VoidCallback onHome;
  final void Function(int index) onChoose;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final PcStatus target = provider.target;
    final int homeIndex = provider.selectedGpuIndex;

    return MonitorScaffold(
      title: 'GPU / DEVICES',
      subtitle: target.gpuCount == 0
          ? 'SELECT AN ADAPTER'
          : '${target.gpuCount} ADAPTERS / SELECT A GPU',
      accent: theme.gpu,
      leading: BackButtonHud(label: 'HOME', onPressed: onHome, accent: theme.text),
      body: target.gpuCount == 0
          ? _empty(theme, metrics)
          : _list(context, theme, metrics, target, homeIndex, provider),
    );
  }

  Widget _empty(MonitorTheme theme, LayoutMetrics metrics) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.developer_board_outlined, color: theme.muted, size: metrics.px(40)),
          SizedBox(height: metrics.gutter),
          Text(
            'No GPU data',
            style: TextStyle(color: theme.muted, fontSize: metrics.font(13)),
          ),
        ],
      ),
    );
  }

  Widget _list(
    BuildContext context,
    MonitorTheme theme,
    LayoutMetrics metrics,
    PcStatus target,
    int homeIndex,
    MonitorProvider provider,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        metrics.pagePadding,
        0,
        metrics.pagePadding,
        metrics.gutter,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columns = metrics.cardColumns(constraints.maxWidth);
          final int rows = (target.gpuCount + columns - 1) ~/ columns;
          final double spacing = metrics.gutter * (columns - 1);
          final double cardWidth =
              (constraints.maxWidth - spacing) / columns;
          // Card height follows the space the viewport actually offers so the
          // grid never pokes past the screen edges. On a short (landscape)
          // viewport a fixed floor would overflow and force scrolling, so the
          // floor gives way and the row gap is counted once.
          final double rowGap = metrics.gutter;
          final double perRow =
              (constraints.maxHeight - rowGap * (rows - 1)) / rows;
          const double comfortable = 140.0;
          const double need = 130.0;
          const double minimum = 110.0;
          final double cardHeight = perRow >= comfortable
              ? math.min(perRow, 300.0)
              : math.max(minimum, perRow);
          // The card's curve sits in an Expanded slot, so the contents already
          // follow the card height; only the chrome is compressed here, and
          // only when the row cannot give the labels their comfortable room.
          final double factor =
              math.max(0.80, math.min(1.0, cardHeight / need));
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
                    if (index >= target.gpuCount) {
                      return SizedBox(width: cardWidth);
                    }
                    return Padding(
                      padding: EdgeInsets.only(
                        right: column == columns - 1 ? 0 : metrics.gutter,
                      ),
                      child: SizedBox(
                        width: cardWidth,
                        height: cardHeight,
                        child: LayoutScope(
                          metrics: cardMetrics,
                          child: _GpuCard(
                            gpu: target.gpus[index],
                            index: index,
                            isHome: index == homeIndex,
                            history: provider.gpuHistoryFor(
                              target.gpus[index].protocolId,
                            ),
                            onTap: () => onChoose(index),
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
      ),
    );
  }
}

class _GpuCard extends StatelessWidget {
  const _GpuCard({
    required this.gpu,
    required this.index,
    required this.isHome,
    required this.history,
    required this.onTap,
  });

  final GpuStatus gpu;
  final int index;
  final bool isHome;

  /// This adapter's own 60 s window, drawn as the card's dynamic curve.
  final List<double?> history;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    // The device list compares whole adapters, so every visual on the card -
    // headline number, bar and curve - reads the adapter-level total. Reading
    // the busiest engine here used to make the card disagree with the adapter
    // the user picked, and produced the misleading `PEAK: <engine>` caption.
    final bool usageValid = gpu.usageValid;
    final int usage = gpu.usage;

    final List<String> metricsParts = <String>[
      usageValid ? '$usage%' : Ph.percent,
      fmtTemp(gpu.temp, gpu.tempValid, digits: 0),
      fmtPower(gpu.power, gpu.powerValid),
    ];

    return HudPanel(
      radius: metrics.panelRadius,
      accent: isHome ? theme.gpu : theme.border,
      borderWidth: isHome ? 2 : 1,
      glow: isHome ? 0.7 : 0,
      padding: EdgeInsets.all(metrics.panelPadding),
      onTap: onTap,
      semanticLabel: '${gpu.name}, ${metricsParts.join(', ')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  gpu.name.isEmpty ? 'Unknown adapter' : gpu.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(14),
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
              SizedBox(width: metrics.px(8)),
              if (isHome) HudBadge(label: 'HOME', color: theme.gpu),
            ],
          ),
          SizedBox(height: metrics.px(6)),
          Row(
            children: <Widget>[
              if (gpu.discreteValid)
                HudBadge(
                  label: gpu.isDiscrete ? 'DISCRETE' : 'INTEGRATED',
                  color: gpu.isDiscrete ? theme.gpu : theme.muted,
                  fontSize: metrics.font(8),
                  horizontalPadding: metrics.px(5),
                ),
              if (gpu.discreteValid) SizedBox(width: metrics.px(6)),
              Expanded(
                child: Text(
                  gpu.vendor.isEmpty ? '' : gpu.vendor.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(9),
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: theme.muted, size: metrics.px(16)),
            ],
          ),
          // The tall cards used to leave a dead band here. It now carries this
          // adapter's own 60 s load curve, which is what the device list is
          // actually for: comparing adapters at a glance.
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: metrics.px(8)),
              child: Sparkline(
                points: history,
                color: theme.gpu,
                thresholdColor: theme.hot,
              ),
            ),
          ),
          Text(
            metricsParts.join('   /   '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.gpu,
              fontSize: metrics.font(16),
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          SizedBox(height: metrics.px(6)),
          Text(
            'TOTAL LOAD',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.muted,
              fontSize: metrics.font(9),
              letterSpacing: 0.7,
            ),
          ),
          SizedBox(height: metrics.px(10)),
          HudBar(
            value: usage.toDouble(),
            color: theme.gpu,
            valid: usageValid,
            height: metrics.px(6),
            gradientTo: theme.cpu,
          ),
        ],
      ),
    );
  }
}

/// GPU detail page.
///
/// The firmware shows total load, temperature, power, VRAM and then the engine
/// list. The summary describes the WHOLE adapter - its load tile is the
/// adapter-level total utilisation, matching the GPU device list - while the
/// list below keeps each engine's own reading.
class GpuDetailScreen extends StatelessWidget {
  const GpuDetailScreen({
    super.key,
    required this.provider,
    required this.onHome,
    required this.onBackToDevices,
  });

  final MonitorProvider provider;
  final VoidCallback onHome;
  final VoidCallback onBackToDevices;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final PcStatus target = provider.target;
    final PcStatus display = provider.display;

    final int? index = provider.openGpuIndex;
    final GpuStatus? gpu =
        index == null ? null : (index < target.gpuCount ? target.gpus[index] : null);
    final GpuEngine? engine = PcStatus.busiestEngine(gpu);
    final GpuStatus? displayGpu =
        gpu == null ? null : display.findGpu(gpu.protocolId);

    return MonitorScaffold(
      title: 'GPU / DETAIL',
      subtitle: gpu == null
          ? 'ADAPTER UNAVAILABLE'
          : (gpu.name.isEmpty ? 'ADAPTER' : gpu.name),
      accent: theme.gpu,
      leading: BackButtonHud(
        label: 'HOME',
        onPressed: onHome,
        accent: theme.text,
      ),
      actions: <Widget>[
        BackButtonHud(
          label: 'DEVICES',
          onPressed: onBackToDevices,
          accent: theme.gpu,
        ),
      ],
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
            _SummaryBlock(
              gpu: gpu,
              displayGpu: displayGpu,
            ),
            SizedBox(height: metrics.gutter),
            SectionHeader(
              title: 'Engine utilisation',
              accent: theme.gpu,
              trailing: Text(
                gpu == null ? Ph.count : '${gpu.engines.length} ENGINES',
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
              child: gpu == null
                  ? _unavailable(theme, metrics)
                  : engine == null
                      ? _noEngines(theme, metrics)
                      : _EngineList(
                          target: target,
                          gpu: gpu,
                          displayGpu: displayGpu,
                          accent: theme.gpu,
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unavailable(MonitorTheme theme, LayoutMetrics metrics) {
    return Center(
      child: Text(
        'GPU unavailable / select another device',
        textAlign: TextAlign.center,
        style: TextStyle(color: theme.muted, fontSize: metrics.font(13)),
      ),
    );
  }

  Widget _noEngines(MonitorTheme theme, LayoutMetrics metrics) {
    return Center(
      child: Text(
        'No engine data',
        style: TextStyle(color: theme.muted, fontSize: metrics.font(13)),
      ),
    );
  }
}

class _SummaryBlock extends StatelessWidget {
  const _SummaryBlock({
    required this.gpu,
    required this.displayGpu,
  });

  final GpuStatus? gpu;
  final GpuStatus? displayGpu;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    // Instance fields cannot be promoted by a null check (they are not
    // provably stable across the read), so hoist them into locals first.
    final GpuStatus? gpu = this.gpu;
    final GpuStatus? displayGpu = this.displayGpu;

    // The headline is the adapter's own total utilisation, not its busiest
    // engine. This panel sits above the engine list and describes the whole
    // adapter; the per-engine readings have their own rows below.
    final bool usageValid = gpu?.usageValid ?? false;
    final int usage = gpu?.usage ?? 0;
    final double displayUsage = displayGpu?.usage.toDouble() ?? 0;

    // Columns follow the AVAILABLE WIDTH, not the short side - same rule as
    // the CPU summary block.
    return HudPanel(
      radius: metrics.panelRadius,
      accent: theme.gpu.withValues(alpha: 0.5),
      padding: EdgeInsets.all(metrics.panelPadding),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool landscape = metrics.isLandscape;

          final List<Widget> tiles = <Widget>[
            MetricLine(
              label: 'GPU load',
              value: usageValid ? '$usage%' : Ph.percent,
              valueColor: theme.text,
              valueFontSize: metrics.font(landscape ? 18 : 22),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'Temperature',
              value: fmtTemp(gpu?.temp ?? 0, gpu?.tempValid ?? false),
              valueColor: isHot(gpu?.temp ?? 0, gpu?.tempValid ?? false)
                  ? theme.hot
                  : theme.text,
              valueFontSize: metrics.font(landscape ? 13 : 15),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'Power',
              value: fmtPower(gpu?.power ?? 0, gpu?.powerValid ?? false),
              valueFontSize: metrics.font(landscape ? 13 : 15),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'VRAM usage',
              value: fmtPercent(gpu?.vramUsage ?? 0, gpu?.vramUsageValid ?? false),
              valueColor: theme.vram,
              valueFontSize: metrics.font(landscape ? 13 : 15),
              labelFontSize: metrics.font(10),
            ),
            MetricLine(
              label: 'VRAM',
              value: gpu == null
                  ? Ph.gib
                  : fmtCapacityPair(
                      gpu.vramUsed,
                      gpu.vramUsedValid,
                      gpu.vramTotal,
                      gpu.vramTotalValid,
                    ),
              valueFontSize: metrics.font(landscape ? 12 : 14),
              labelFontSize: metrics.font(10),
            ),
          ];

          // Landscape summary is a strict two-row block - parameters on one
          // line, bar on the second - so the engine grid below keeps the
          // vertical space. Portrait wraps into however many rows the width
          // allows.
          final int columns = landscape
              ? tiles.length
              : (constraints.maxWidth / (150 * metrics.scale))
                  .floor()
                  .clamp(2, 5);
          final double tileWidth =
              (constraints.maxWidth - metrics.gutter * (columns - 1)) / columns;

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
                value: displayUsage,
                color: theme.gpu,
                valid: usageValid,
                height: metrics.px(6),
                gradientTo: theme.cpu,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The engine list. Unlike the dashboard - which reads only the busiest engine -
/// this page shows every engine's own smoothed value, each matched by protocol
/// id so the numbers stay attached to the right row across samples.
class _EngineList extends StatelessWidget {
  const _EngineList({
    required this.target,
    required this.gpu,
    required this.displayGpu,
    required this.accent,
  });

  final PcStatus target;
  final GpuStatus gpu;
  final GpuStatus? displayGpu;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final LayoutMetrics metrics = context.layout;

        return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = metrics.listColumns(
          constraints.maxWidth,
          minItemWidth: constraints.maxWidth < 380 ? 140 : 160,
        );
        final double itemWidth =
            (constraints.maxWidth - metrics.gutter * (columns - 1)) / columns;
        // Same fix as the CPU core list: an unbounded ListView plus a stretch
        // Row collapses to zero, so the engine grid gets an explicit height.
        const double rowHeight = 54;
        final double rowExtent = rowHeight * metrics.scale.clamp(0.85, 1.6);

        return ListView.builder(
          padding: EdgeInsets.only(bottom: metrics.gutter),
          itemCount: (gpu.engines.length / columns).ceil(),
          itemBuilder: (BuildContext context, int row) {
            return Padding(
              padding: EdgeInsets.only(bottom: metrics.gutter * 0.75),
              child: SizedBox(
                height: rowExtent,
                child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: List<Widget>.generate(columns, (int column) {
                  final int index = row * columns + column;
                  if (index >= gpu.engines.length) {
                    return SizedBox(width: itemWidth);
                  }
                  final GpuEngine engine = gpu.engines[index];
                  final GpuEngine? displayEngine =
                      PcStatus.findEngine(displayGpu, engine.protocolId);
                  return Padding(
                    padding: EdgeInsets.only(
                      right: column == columns - 1 ? 0 : metrics.gutter,
                    ),
                    child: SizedBox(
                      width: itemWidth,
                      child: _EngineRow(
                        engine: engine,
                        displayUsage:
                            displayEngine?.usage.toDouble() ?? engine.usage.toDouble(),
                        accent: accent,
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

class _EngineRow extends StatelessWidget {
  const _EngineRow({
    required this.engine,
    required this.displayUsage,
    required this.accent,
  });

  final GpuEngine engine;
  final double displayUsage;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    return HudPanel(
      radius: metrics.panelRadius * 0.65,
      accent: theme.border,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.px(10),
        vertical: metrics.px(8),
      ),
      semanticLabel: engine.name,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  engine.name.isEmpty ? 'Engine' : engine.name,
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
                engine.usageValid ? '${engine.usage}%' : Ph.percent,
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
            value: displayUsage,
            color: accent,
            valid: engine.usageValid,
            height: metrics.px(4),
            glow: 0.3,
          ),
        ],
      ),
    );
  }
}

/// Unused forward-declaration kept so the file exports a stable surface.
typedef GpuDetailSparkline = Sparkline;
