import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/pc_status.dart';
import '../responsive/responsive.dart';
import '../services/monitor_provider.dart';
import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';
import '../util/format.dart';
import '../widgets/hud.dart';
import '../widgets/sparkline.dart';
import 'monitor_shell.dart';

/// The dashboard.
///
/// Layout mirrors the firmware exactly in structure - two processor cards, a
/// clock card, RAM/VRAM and NET/DISK tiles - but the container adapts:
///
/// * **compactStack** (phone portrait) - a single vertical column that fills
///   the viewport: the two processor cards, the clock band, then the memory and
///   I/O bands. The two memory tiles and the two I/O tiles pair up side by
///   side, which is what buys back enough height for the column to fit without
///   a scrollbar.
/// * **splitColumns** (tablet portrait) - the same column, sized for the wider
///   viewport.
/// * **gridWide** (phone landscape / large tablet portrait) - the 2-up grid from
///   the wide firmware layout.
/// * **gridExtraWide** (tablet landscape) - the wide grid with the clock and
///   memory tiles promoted to a third column.
///
/// The dashboard never scrolls. Every variant is a fill layout: panels are
/// handed a share of the viewport and grow into it.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.provider,
    required this.onOpenCpu,
    required this.onOpenGpus,
    required this.onOpenDisks,
    required this.onOpenHosts,
  });

  final MonitorProvider provider;
  final VoidCallback onOpenCpu;
  final VoidCallback onOpenGpus;
  final VoidCallback onOpenDisks;

  /// Opens the discovery / pairing page, tapped from the status pill.
  final VoidCallback onOpenHosts;

  @override
  Widget build(BuildContext context) {
    final LayoutMetrics metrics = context.layout;

    final Widget content = switch (metrics.variant) {
      LayoutVariant.compactStack ||
      LayoutVariant.splitColumns =>
        _CompactDashboard(
          provider: provider,
          onOpenCpu: onOpenCpu,
          onOpenGpus: onOpenGpus,
          onOpenDisks: onOpenDisks,
        ),
      LayoutVariant.gridWide || LayoutVariant.gridExtraWide => _GridDashboard(
          provider: provider,
          onOpenCpu: onOpenCpu,
          onOpenGpus: onOpenGpus,
          onOpenDisks: onOpenDisks,
        ),
    };

    return HudBackground(
      accent: context.theme.cpu,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                metrics.pagePadding,
                metrics.gutter,
                metrics.pagePadding,
                metrics.gutter * 0.6,
              ),
              child: DashboardStatusBar(
                provider: provider,
                onOpenHosts: onOpenHosts,
              ),
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Processor card
// ---------------------------------------------------------------------------

/// One of the two big processor cards (CPU / GPU).
class ProcessorCard extends StatelessWidget {
  const ProcessorCard({
    super.key,
    required this.title,
    required this.tag,
    required this.model,
    required this.usage,
    required this.usageValid,
    required this.accent,
    required this.detailText,
    required this.detailHot,
    required this.displayUsage,
    required this.history,
    required this.onTap,
    this.compact = false,
  });

  final String title;

  /// `ALL CORES` or `MAX / <engine>`.
  final String tag;

  final String model;
  final int usage;
  final bool usageValid;
  final Color accent;
  final String detailText;
  final bool detailHot;

  /// Smoothed value driving the bar (the number itself uses [usage]).
  final double displayUsage;

  final List<double?> history;
  final VoidCallback onTap;

  /// Stacked variant for narrow screens: the chart drops below the detail row.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final String usageText = usageValid ? '$usage' : '--';

    return HudPanel(
      radius: metrics.panelRadius,
      accent: accent.withValues(alpha: 0.6),
      glow: 0.55,
      padding: EdgeInsets.all(metrics.panelPadding),
      onTap: onTap,
      semanticLabel: '$title ${tag.isEmpty ? '' : tag}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AccentChip(color: accent, width: 3, height: metrics.font(15)),
              SizedBox(width: metrics.px(10)),
              Text(
                title,
                style: TextStyle(
                  color: theme.text,
                  fontSize: metrics.font(15),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              SizedBox(width: metrics.px(8)),
              Expanded(
                child: Text(
                  tag,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent,
                    fontSize: metrics.font(10),
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.7,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: metrics.px(6)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                usageText,
                style: TextStyle(
                  color: theme.text,
                  // Landscape cards are height-starved: a 44 pt numeral plus
                  // its caption rows used to eat the chart's whole vertical
                  // budget. A smaller numeral in landscape returns that space
                  // to the sparkline without touching the portrait look.
                  fontSize: metrics.font(metrics.isLandscape ? 34 : 44),
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(
                  bottom: metrics.px(7),
                  left: metrics.px(3),
                ),
                child: Text(
                  '%',
                  style: TextStyle(
                    color: accent,
                    fontSize: metrics.font(metrics.isLandscape ? 13 : 17),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(width: metrics.px(14)),
              // The model name lives in what used to be the card's largest dead
              // band - the whole right half, level with the big percentage. It
              // is the biggest secondary string on the card, so it is set well
              // above the caption sizes and allowed two lines.
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: metrics.px(5)),
                  child: Text(
                    model,
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.text.withValues(alpha: 0.85),
                      fontSize: metrics.font(15),
                      fontWeight: FontWeight.w600,
                      height: 1.18,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: metrics.px(6)),
          Text(
            detailText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: detailHot ? theme.hot : theme.muted,
              fontSize: metrics.font(metrics.isLandscape ? 11 : 12),
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          SizedBox(height: metrics.px(metrics.isLandscape ? 6 : 8)),
          HudBar(
            value: displayUsage,
            color: accent,
            valid: usageValid,
            height: metrics.px(6),
            gradientTo: accent.withValues(alpha: 0.65),
          ),
          SizedBox(height: metrics.px(6)),
          // The sparkline row absorbs any slack when the card is stretched
          // taller than its content (fill layouts), so the card never shows a
          // dead band at the bottom. On the compact column it also has to be
          // able to collapse to nothing - the column fills the viewport and a
          // hard minimum here would turn a tight screen into an overflow.
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // The label is boxed (rather than merely aligned) so it can
                // shrink with the row instead of forcing it taller.
                SizedBox(
                  width: metrics.px(28),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.bottomLeft,
                    child: Text(
                      '60s',
                      maxLines: 1,
                      style: TextStyle(
                        color: theme.muted,
                        fontSize: metrics.font(9),
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: metrics.px(6)),
                Expanded(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: compact ? 0 : metrics.px(28),
                    ),
                    child: Sparkline(
                      points: history,
                      color: accent,
                      thresholdColor: theme.hot,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Memory / IO tiles
// ---------------------------------------------------------------------------

class MemoryTile extends StatelessWidget {
  const MemoryTile({
    super.key,
    required this.title,
    required this.accent,
    required this.usage,
    required this.usageValid,
    required this.displayUsage,
    required this.capacityText,
  });

  final String title;
  final Color accent;
  final int usage;
  final bool usageValid;
  final double displayUsage;
  final String capacityText;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    return HudPanel(
      radius: metrics.panelRadius,
      accent: accent.withValues(alpha: 0.5),
      padding: EdgeInsets.all(metrics.panelPadding),
      semanticLabel: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              color: accent,
              fontSize: metrics.font(11),
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: metrics.px(4)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                usageValid ? '$usage%' : Ph.percent,
                style: TextStyle(
                  color: theme.text,
                  fontSize: metrics.font(24),
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  capacityText,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(10),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: metrics.px(8)),
          HudBar(
            value: displayUsage,
            color: accent,
            valid: usageValid,
            height: metrics.px(5),
          ),
        ],
      ),
    );
  }
}

/// The NET / DISK tile: two labelled rates stacked vertically.
class IoTile extends StatelessWidget {
  const IoTile({
    super.key,
    required this.title,
    required this.accent,
    required this.primaryLabel,
    required this.primaryValue,
    required this.primaryColor,
    required this.secondaryLabel,
    required this.secondaryValue,
    required this.secondaryColor,
    this.onTap,
  });

  final String title;
  final Color accent;
  final String primaryLabel;
  final String primaryValue;
  final Color primaryColor;
  final String secondaryLabel;
  final String secondaryValue;
  final Color secondaryColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    return HudPanel(
      radius: metrics.panelRadius,
      accent: accent.withValues(alpha: 0.5),
      padding: EdgeInsets.all(metrics.panelPadding),
      onTap: onTap,
      semanticLabel: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: theme.muted,
                  fontSize: metrics.font(11),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              const Spacer(),
              if (onTap != null)
                Icon(Icons.chevron_right, color: theme.muted, size: metrics.px(15)),
            ],
          ),
          SizedBox(height: metrics.px(8)),
          _IoLine(
            label: primaryLabel,
            value: primaryValue,
            color: primaryColor,
            metrics: metrics,
          ),
          SizedBox(height: metrics.px(5)),
          _IoLine(
            label: secondaryLabel,
            value: secondaryValue,
            color: secondaryColor,
            metrics: metrics,
          ),
        ],
      ),
    );
  }
}

class _IoLine extends StatelessWidget {
  const _IoLine({
    required this.label,
    required this.value,
    required this.color,
    required this.metrics,
  });

  final String label;
  final String value;
  final Color color;
  final LayoutMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: metrics.px(22),
          child: Text(
            label,
            style: TextStyle(
              color: theme.muted,
              fontSize: metrics.font(10),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: metrics.font(13),
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Data derivation shared by both dashboard layouts
// ---------------------------------------------------------------------------

/// The exact set of values the dashboard renders, derived once per frame.
///
/// Keeping this in one place guarantees the number, the bar and the sparkline
/// always describe the *same* engine - the firmware is explicit that they must
/// not diverge.
class DashboardData {
  const DashboardData({
    required this.cpuTitle,
    required this.cpuTag,
    required this.cpuModel,
    required this.cpuUsage,
    required this.cpuUsageValid,
    required this.cpuDisplayUsage,
    required this.cpuDetail,
    required this.cpuDetailHot,
    required this.gpuTitle,
    required this.gpuTag,
    required this.gpuModel,
    required this.gpuUsage,
    required this.gpuUsageValid,
    required this.gpuDisplayUsage,
    required this.gpuDetail,
    required this.gpuDetailHot,
    required this.ramUsage,
    required this.ramUsageValid,
    required this.ramDisplayUsage,
    required this.ramCapacity,
    required this.vramUsage,
    required this.vramUsageValid,
    required this.vramDisplayUsage,
    required this.vramCapacity,
    required this.netDown,
    required this.netUp,
    required this.diskRead,
    required this.diskWrite,
    required this.cpuHistory,
    required this.gpuHistory,
  });

  final String cpuTitle;
  final String cpuTag;
  final String cpuModel;
  final int cpuUsage;
  final bool cpuUsageValid;
  final double cpuDisplayUsage;
  final String cpuDetail;
  final bool cpuDetailHot;

  final String gpuTitle;
  final String gpuTag;
  final String gpuModel;
  final int gpuUsage;
  final bool gpuUsageValid;
  final double gpuDisplayUsage;
  final String gpuDetail;
  final bool gpuDetailHot;

  final int ramUsage;
  final bool ramUsageValid;
  final double ramDisplayUsage;
  final String ramCapacity;

  final int vramUsage;
  final bool vramUsageValid;
  final double vramDisplayUsage;
  final String vramCapacity;

  final String netDown;
  final String netUp;
  final String diskRead;
  final String diskWrite;

  final List<double?> cpuHistory;
  final List<double?> gpuHistory;

  static DashboardData derive(MonitorProvider provider, LayoutMetrics metrics) {
    final PcStatus target = provider.target;
    final PcStatus display = provider.display;

    final GpuStatus? gpu = provider.selectedGpu;
    final GpuEngine? engine = provider.selectedEngine;

    // The display-side counterparts are matched by protocol id, never index.
    final GpuStatus? displayGpu = display.findGpu(gpu?.protocolId ?? '');

    final GpuEngine? displayEngine = PcStatus.findEngine(
      displayGpu,
      engine?.protocolId ?? '',
    );

    // GPU usage: the busiest engine wins; only when no engine reports a valid
    // reading does the adapter-level sensor get a say.
    final bool gpuUsageValid =
        engine != null ? engine.usageValid : (gpu?.usageValid ?? false);
    final int gpuUsage = engine != null ? engine.usage : (gpu?.usage ?? 0);
    final double displayEngineUsage = displayEngine != null
        ? displayEngine.usage.toDouble()
        : (displayGpu?.usage.toDouble() ?? 0);

    final String gpuTag = engine != null
        ? 'MAX / ${clampName(engine.name, 24)}'
        : 'TOTAL';

    // Detail row: temperature and power, each degrading independently.
    final String gpuDetail =
        '${fmtTempShort(gpu?.temp ?? 0, gpu?.tempValid ?? false)} C   /   '
        '${fmtPowerShort(gpu?.power ?? 0, gpu?.powerValid ?? false)} W';

    return DashboardData(
      cpuTitle: 'CPU',
      cpuTag: 'ALL CORES',
      cpuModel: wrapModelText(
        clampName(target.cpuName, 48),
        (74 * metrics.scale).round().clamp(24, 140),
      ),
      cpuUsage: target.cpuUsage,
      cpuUsageValid: target.cpuUsageValid,
      cpuDisplayUsage: display.cpuUsage.toDouble(),
      cpuDetail: '${fmtTempShort(target.cpuTemp, target.cpuTempValid)} C   /   '
          '${fmtPowerShort(target.cpuPower, target.cpuPowerValid)} W',
      cpuDetailHot: isHot(target.cpuTemp, target.cpuTempValid),
      gpuTitle: 'GPU',
      gpuTag: gpuTag,
      gpuModel: gpu == null
          ? 'No GPU'
          : wrapModelText(
              clampName(gpu.name, 48),
              (74 * metrics.scale).round().clamp(24, 140),
            ),
      gpuUsage: gpuUsage,
      gpuUsageValid: gpuUsageValid,
      gpuDisplayUsage: displayEngineUsage,
      gpuDetail: gpu == null ? '-- C   /   -- W' : gpuDetail,
      gpuDetailHot: isHot(gpu?.temp ?? 0, gpu?.tempValid ?? false),
      ramUsage: target.ramUsage,
      ramUsageValid: target.ramUsageValid,
      ramDisplayUsage: display.ramUsage.toDouble(),
      ramCapacity: fmtCapacityPair(
        target.ramUsed,
        target.ramUsedValid,
        target.ramTotal,
        target.ramTotalValid,
      ),
      vramUsage: gpu?.vramUsage ?? 0,
      vramUsageValid: gpu?.vramUsageValid ?? false,
      vramDisplayUsage: displayGpu?.vramUsage.toDouble() ?? 0,
      vramCapacity: gpu == null
          ? Ph.gib
          : fmtCapacityPair(
              gpu.vramUsed,
              gpu.vramUsedValid,
              gpu.vramTotal,
              gpu.vramTotalValid,
            ),
      netDown: uiFormatRate(target.netDownMbS, target.netDownValid),
      netUp: uiFormatRate(target.netUpMbS, target.netUpValid),
      diskRead: uiFormatRate(target.diskReadMbS, target.diskReadValid),
      diskWrite: uiFormatRate(target.diskWriteMbS, target.diskWriteValid),
      cpuHistory: provider.cpuHistory,
      gpuHistory: provider.gpuHistory,
    );
  }
}

/// Aggregate disk throughput across every physical disk, as the dashboard shows.
extension on PcStatus {
  double get diskReadMbS => disks.fold<double>(
        0,
        (double sum, DiskStatus d) => sum + (d.readValid ? d.readMbS : 0),
      );

  double get diskWriteMbS => disks.fold<double>(
        0,
        (double sum, DiskStatus d) => sum + (d.writeValid ? d.writeMbS : 0),
      );

  bool get diskReadValid => disks.any((DiskStatus d) => d.readValid);
  bool get diskWriteValid => disks.any((DiskStatus d) => d.writeValid);
}

// ---------------------------------------------------------------------------
// Compact (single column) layout
// ---------------------------------------------------------------------------

class _CompactDashboard extends StatelessWidget {
  const _CompactDashboard({
    required this.provider,
    required this.onOpenCpu,
    required this.onOpenGpus,
    required this.onOpenDisks,
  });

  final MonitorProvider provider;
  final VoidCallback onOpenCpu;
  final VoidCallback onOpenGpus;
  final VoidCallback onOpenDisks;

  /// The vertical budgets the column is divided with, in "firmware units"
  /// (i.e. before [LayoutMetrics.scale] is applied).
  ///
  /// These sit a little *above* the true content minimum on purpose: the slack
  /// is what the sparkline grows into, and the margin is what keeps a short
  /// viewport compressing rather than overflowing.
  static const double _cardUnits = 210;
  static const double _tileUnits = 92;
  static const double _gapUnits = 10;

  /// A tile needs this much width before two of them can sit side by side.
  static const double _tileMinWidth = 160;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints viewport) {
        final double horizontal = math.max(
          0,
          viewport.maxWidth - metrics.pagePadding * 2,
        );

        // Two tiles per row once the width allows it. Halving the tile band is
        // what buys a portrait screen the height it needs, and it is also how
        // a wide tablet stops wasting a full row on a single short tile.
        final bool twoUp =
            horizontal / 2 >= _tileMinWidth * metrics.scale;
        final double bandUnits = twoUp ? _tileUnits : _tileUnits * 2;
        final double gapUnits = _gapUnits * (twoUp ? 4 : 6);

        // Total design height this column wants. When the viewport is shorter
        // the whole thing - fonts included - is compressed to match, because
        // the dashboard is not allowed to scroll.
        //
        // The clock gets exactly one tile's worth of height, so it matches the
        // RAM / VRAM tiles whether those are side by side or stacked.
        final double nominal =
            (2 * _cardUnits + 2 * bandUnits + _tileUnits + gapUnits) *
                metrics.scale;
        final double available = math.max(
          0,
          viewport.maxHeight - metrics.gutter * 2,
        );
        final LayoutMetrics m = metrics.compressed(available / nominal);

        final DashboardData data = DashboardData.derive(provider, m);
        final int bandFlex = bandUnits.round();
        final int clockFlex = _tileUnits.round();

        return LayoutScope(
          metrics: m,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              m.pagePadding,
              0,
              m.pagePadding,
              m.gutter * 2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  flex: _cardUnits.round(),
                  child: ProcessorCard(
                    title: data.cpuTitle,
                    tag: data.cpuTag,
                    model: data.cpuModel,
                    usage: data.cpuUsage,
                    usageValid: data.cpuUsageValid,
                    displayUsage: data.cpuDisplayUsage,
                    accent: theme.cpu,
                    detailText: data.cpuDetail,
                    detailHot: data.cpuDetailHot,
                    history: data.cpuHistory,
                    onTap: onOpenCpu,
                    compact: true,
                  ),
                ),
                SizedBox(height: m.gutter),
                Expanded(
                  flex: _cardUnits.round(),
                  child: ProcessorCard(
                    title: data.gpuTitle,
                    tag: data.gpuTag,
                    model: data.gpuModel,
                    usage: data.gpuUsage,
                    usageValid: data.gpuUsageValid,
                    displayUsage: data.gpuDisplayUsage,
                    accent: theme.gpu,
                    detailText: data.gpuDetail,
                    detailHot: data.gpuDetailHot,
                    history: data.gpuHistory,
                    onTap: onOpenGpus,
                    compact: true,
                  ),
                ),
                SizedBox(height: m.gutter),
                // The clock keeps the firmware's position - it leads the tile
                // group - but on a portrait phone it spans the full column, so
                // it is exactly as wide as the processor cards and exactly as
                // tall as one memory tile.
                Expanded(
                  flex: clockFlex,
                  child: _ClockCard(provider: provider, compact: true),
                ),
                SizedBox(height: m.gutter),
                Expanded(
                  flex: bandFlex,
                  child: _MemoryRow(data: data, twoUp: twoUp),
                ),
                SizedBox(height: m.gutter),
                Expanded(
                  flex: bandFlex,
                  child: _IoRow(data: data, onOpenDisks: onOpenDisks, twoUp: twoUp),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Grid (wide) layout
// ---------------------------------------------------------------------------

class _GridDashboard extends StatelessWidget {
  const _GridDashboard({
    required this.provider,
    required this.onOpenCpu,
    required this.onOpenGpus,
    required this.onOpenDisks,
  });

  final MonitorProvider provider;
  final VoidCallback onOpenCpu;
  final VoidCallback onOpenGpus;
  final VoidCallback onOpenDisks;

  /// Vertical budget of one rate tile and of the gap between two stacked
  /// tiles, in firmware units - the same numbers the compact layout sizes its
  /// tile band with. The lower row is content-sized, unlike the processor
  /// cards above it, so this is what decides whether it fits.
  static const double _tileUnits = 92;
  static const double _gapUnits = 10;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final DashboardData data = DashboardData.derive(provider, metrics);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        metrics.pagePadding,
        0,
        metrics.pagePadding,
        metrics.gutter,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool threeColumns =
              metrics.variant == LayoutVariant.gridExtraWide &&
                  constraints.maxWidth > 900 * metrics.scale;

          final Widget processors = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ProcessorCard(
                  title: data.cpuTitle,
                  tag: data.cpuTag,
                  model: data.cpuModel,
                  usage: data.cpuUsage,
                  usageValid: data.cpuUsageValid,
                  displayUsage: data.cpuDisplayUsage,
                  accent: theme.cpu,
                  detailText: data.cpuDetail,
                  detailHot: data.cpuDetailHot,
                  history: data.cpuHistory,
                  onTap: onOpenCpu,
                ),
              ),
              SizedBox(width: metrics.gutter),
              Expanded(
                child: ProcessorCard(
                  title: data.gpuTitle,
                  tag: data.gpuTag,
                  model: data.gpuModel,
                  usage: data.gpuUsage,
                  usageValid: data.gpuUsageValid,
                  displayUsage: data.gpuDisplayUsage,
                  accent: theme.gpu,
                  detailText: data.gpuDetail,
                  detailHot: data.gpuDetailHot,
                  history: data.gpuHistory,
                  onTap: onOpenGpus,
                ),
              ),
              if (threeColumns) ...<Widget>[
                SizedBox(width: metrics.gutter),
                Expanded(child: _ClockCard(provider: provider)),
              ],
            ],
          );

          final Widget lower = threeColumns
              ? _LowerGridThreeWide(data: data, onOpenDisks: onOpenDisks)
              : _LowerGridTwoWide(
                  data: data,
                  provider: provider,
                  onOpenDisks: onOpenDisks,
                );

          // Landscape viewports are height-starved: the processor cards used
          // to take 11/18 of the column and squeezed the memory / IO tiles
          // below what their content needs. Give the lower row a bigger share
          // in landscape while keeping the original balance in portrait.
          final bool landscape = metrics.isLandscape;
          final int processorFlex = landscape ? 9 : 11;
          final int lowerFlex = landscape ? 8 : 7;

          // The lower row is the one place the grid can still overflow: its
          // tiles are content-sized (two stacked rate tiles in the two-wide
          // grid), and a short landscape viewport hands it less than that.
          // Compress the metrics for this subtree only - the same escape hatch
          // the compact portrait layout uses - so the tiles shrink their fonts
          // and paddings to fit instead of painting past the panel edge.
          final int stackedTiles = threeColumns ? 1 : 2;
          final double lowerNominal =
              (stackedTiles * _tileUnits + (stackedTiles - 1) * _gapUnits) *
                  metrics.scale;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(flex: processorFlex, child: processors),
              SizedBox(height: metrics.gutter),
              Expanded(
                flex: lowerFlex,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints lowerBox) {
                    final double available = math.max(0, lowerBox.maxHeight);
                    final LayoutMetrics m =
                        metrics.compressed(available / lowerNominal);
                    return LayoutScope(metrics: m, child: lower);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LowerGridTwoWide extends StatelessWidget {
  const _LowerGridTwoWide({
    required this.data,
    required this.provider,
    required this.onOpenDisks,
  });

  final DashboardData data;
  final MonitorProvider provider;
  final VoidCallback onOpenDisks;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: _ClockCard(provider: provider)),
        SizedBox(width: metrics.gutter),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: MemoryTile(
                  title: 'RAM',
                  accent: theme.ram,
                  usage: data.ramUsage,
                  usageValid: data.ramUsageValid,
                  displayUsage: data.ramDisplayUsage,
                  capacityText: data.ramCapacity,
                ),
              ),
              SizedBox(height: metrics.gutter),
              Expanded(
                child: MemoryTile(
                  title: 'VRAM',
                  accent: theme.vram,
                  usage: data.vramUsage,
                  usageValid: data.vramUsageValid,
                  displayUsage: data.vramDisplayUsage,
                  capacityText: data.vramCapacity,
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: metrics.gutter),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: IoTile(
                  title: 'NETWORK',
                  accent: theme.cpu,
                  primaryLabel: 'DL',
                  primaryValue: data.netDown,
                  primaryColor: theme.text,
                  secondaryLabel: 'UL',
                  secondaryValue: data.netUp,
                  secondaryColor: theme.text,
                ),
              ),
              SizedBox(height: metrics.gutter),
              Expanded(
                child: IoTile(
                  title: 'DISK',
                  accent: theme.gpu,
                  primaryLabel: 'R',
                  primaryValue: data.diskRead,
                  primaryColor: theme.cpu,
                  secondaryLabel: 'W',
                  secondaryValue: data.diskWrite,
                  secondaryColor: theme.gpu,
                  onTap: onOpenDisks,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LowerGridThreeWide extends StatelessWidget {
  const _LowerGridThreeWide({required this.data, required this.onOpenDisks});

  final DashboardData data;
  final VoidCallback onOpenDisks;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: MemoryTile(
            title: 'RAM',
            accent: theme.ram,
            usage: data.ramUsage,
            usageValid: data.ramUsageValid,
            displayUsage: data.ramDisplayUsage,
            capacityText: data.ramCapacity,
          ),
        ),
        SizedBox(width: metrics.gutter),
        Expanded(
          child: MemoryTile(
            title: 'VRAM',
            accent: theme.vram,
            usage: data.vramUsage,
            usageValid: data.vramUsageValid,
            displayUsage: data.vramDisplayUsage,
            capacityText: data.vramCapacity,
          ),
        ),
        SizedBox(width: metrics.gutter),
        Expanded(
          child: IoTile(
            title: 'NETWORK',
            accent: theme.cpu,
            primaryLabel: 'DL',
            primaryValue: data.netDown,
            primaryColor: theme.text,
            secondaryLabel: 'UL',
            secondaryValue: data.netUp,
            secondaryColor: theme.text,
          ),
        ),
        SizedBox(width: metrics.gutter),
        Expanded(
          child: IoTile(
            title: 'DISK',
            accent: theme.gpu,
            primaryLabel: 'R',
            primaryValue: data.diskRead,
            primaryColor: theme.cpu,
            secondaryLabel: 'W',
            secondaryValue: data.diskWrite,
            secondaryColor: theme.gpu,
            onTap: onOpenDisks,
          ),
        ),
      ],
    );
  }
}

/// The calendar + clock tile, ported from the firmware clock card.
///
/// One implementation, two shapes:
///
/// * the **cell** shape fills one cell of the wide dashboard's lower row;
/// * the **band** shape ([compact]) is the portrait dashboard's full-width row,
///   exactly one memory tile tall. It is much shorter than it is wide, so the
///   `LOCAL / 24H` caption moves up beside the weekday and the digits are sized
///   by the height that is left over rather than by the width alone.
///
/// Both shapes lead with a year / month / day line with the weekday pinned to
/// the trailing edge, and every digit of `HH:MM:SS` - seconds included - shares
/// one size so the readout stays continuous.
class _ClockCard extends StatelessWidget {
  const _ClockCard({required this.provider, this.compact = false});

  final MonitorProvider provider;

  /// Band variant for the portrait column.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final ClockFields clock = clockFields(DateTime.now());

    return HudPanel(
      radius: metrics.panelRadius,
      accent: theme.cpu.withValues(alpha: 0.5),
      padding: EdgeInsets.all(metrics.panelPadding),
      semanticLabel: 'Local time',
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool roomy = constraints.maxWidth > 220 * metrics.scale;
          final double calendarWidth = metrics.px(roomy ? 74 : 58);
          final double gap = metrics.px(compact ? 4 : 6);

          // "HH:MM:SS" is eight tabular glyphs wide (~4.4 em) now that the
          // seconds share the hour/minute size, so the available width gives an
          // upper bound on the size. The band shape needs a second bound:
          // whatever height is left once the date line above has taken its
          // share, otherwise a one-tile-tall row would push the digits straight
          // out of the panel.
          final double widthBound = (constraints.maxWidth -
                  calendarWidth -
                  metrics.px(12)) /
              4.4;
          final double heightBound = compact && constraints.maxHeight.isFinite
              ? math.max(
                  metrics.font(18),
                  constraints.maxHeight -
                      metrics.panelPadding * 2 -
                      gap -
                      metrics.font(11) * 1.25,
                )
              : double.infinity;
          final double digitFont = math
              .min(widthBound, heightBound)
              .clamp(metrics.font(26), metrics.font(58));

          final Widget calendar = Container(
            width: calendarWidth,
            padding: EdgeInsets.symmetric(vertical: metrics.px(6)),
            decoration: BoxDecoration(
              color: theme.panelAlt,
              borderRadius: BorderRadius.circular(metrics.panelRadius * 0.6),
              border: Border.all(color: theme.border),
            ),
            // Boxed so a short band shrinks the block instead of clipping it.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    clock.month,
                    style: TextStyle(
                      color: theme.cpu,
                      fontSize: metrics.font(11),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Text(
                    clock.day,
                    style: TextStyle(
                      color: theme.text,
                      fontSize: metrics.font(26),
                      fontWeight: FontWeight.w700,
                      height: 1.05,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );

          // Every digit shares one size, so the seconds no longer drop out of
          // the readout when they are the same size as the hours and minutes.
          TextStyle digit(Color color) => TextStyle(
                color: color,
                fontSize: digitFont,
                fontWeight: FontWeight.w700,
                height: 1.0,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              );

          final Widget digits = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(clock.hours, style: digit(theme.text)),
              Text(':', style: digit(theme.muted)),
              Text(clock.minutes, style: digit(theme.text)),
              Text(':', style: digit(theme.muted)),
              Text(clock.seconds, style: digit(theme.cpu)),
            ],
          );

          // The year / month / day line that sits above the digits, with the
          // weekday pinned to the trailing edge. The band shape is too short
          // for a caption row of its own, so there the caption rides along.
          // In landscape the grid hands this card only a slice of the row and
          // the full "YYYY / MM / DD" string ellipsises; the calendar block
          // beside it already carries month and day, so landscape keeps the
          // year alone.
          final String dateText =
              metrics.isLandscape ? clock.date.substring(0, 4) : clock.date;
          final Widget dateLine = Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  dateText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(11),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              SizedBox(width: metrics.px(10)),
              Text(
                clock.weekday,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.cpu,
                  fontSize: metrics.font(10),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              if (compact) ...<Widget>[
                SizedBox(width: metrics.px(10)),
                Text(
                  'LOCAL / 24H',
                  maxLines: 1,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(9),
                    letterSpacing: 0.9,
                  ),
                ),
              ],
            ],
          );

          if (compact) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                calendar,
                SizedBox(width: metrics.px(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      dateLine,
                      SizedBox(height: gap),
                      // The digits take the remaining height and scale down if
                      // the estimate above was still a hair optimistic.
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: digits,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              calendar,
              SizedBox(width: metrics.px(12)),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    dateLine,
                    SizedBox(height: gap),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: digits,
                    ),
                    SizedBox(height: gap),
                    Text(
                      'LOCAL / 24H',
                      maxLines: 1,
                      style: TextStyle(
                        color: theme.muted,
                        fontSize: metrics.font(9),
                        letterSpacing: 0.9,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({required this.data, required this.twoUp});

  final DashboardData data;

  /// `true` places RAM and VRAM side by side, `false` stacks them.
  final bool twoUp;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final Widget ram = MemoryTile(
      title: 'RAM',
      accent: theme.ram,
      usage: data.ramUsage,
      usageValid: data.ramUsageValid,
      displayUsage: data.ramDisplayUsage,
      capacityText: data.ramCapacity,
    );
    final Widget vram = MemoryTile(
      title: 'VRAM',
      accent: theme.vram,
      usage: data.vramUsage,
      usageValid: data.vramUsageValid,
      displayUsage: data.vramDisplayUsage,
      capacityText: data.vramCapacity,
    );

    if (twoUp) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: ram),
          SizedBox(width: metrics.gutter),
          Expanded(child: vram),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: ram),
        SizedBox(height: metrics.gutter),
        Expanded(child: vram),
      ],
    );
  }
}

class _IoRow extends StatelessWidget {
  const _IoRow({
    required this.data,
    required this.onOpenDisks,
    required this.twoUp,
  });

  final DashboardData data;
  final VoidCallback onOpenDisks;

  /// `true` places NETWORK and DISK side by side, `false` stacks them.
  final bool twoUp;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    final Widget net = IoTile(
      title: 'NETWORK',
      accent: theme.cpu,
      primaryLabel: 'DL',
      primaryValue: data.netDown,
      primaryColor: theme.text,
      secondaryLabel: 'UL',
      secondaryValue: data.netUp,
      secondaryColor: theme.text,
    );
    final Widget disk = IoTile(
      title: 'DISK',
      accent: theme.gpu,
      primaryLabel: 'R',
      primaryValue: data.diskRead,
      primaryColor: theme.cpu,
      secondaryLabel: 'W',
      secondaryValue: data.diskWrite,
      secondaryColor: theme.gpu,
      onTap: onOpenDisks,
    );

    if (twoUp) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: net),
          SizedBox(width: metrics.gutter),
          Expanded(child: disk),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: net),
        SizedBox(height: metrics.gutter),
        Expanded(child: disk),
      ],
    );
  }
}
