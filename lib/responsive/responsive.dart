/// Responsive layout engine.
///
/// The firmware ships two hand-tuned absolute-pixel layouts: 480x480 (square
/// panel) and 800x480 (wide panel). Rather than port one of them literally -
/// which would break on a phone - this engine keeps those two boxes as the
/// *reference geometries* and derives a grid from the live viewport:
///
/// 1. the viewport is classified into a [ScreenClass];
/// 2. a layout is chosen per class and per orientation;
/// 3. all spacing/metrics are computed from the live short side, so a 6" phone
///    and a 12" tablet both look intentional rather than merely scaled.
///
/// Nothing is hard-coded to a pixel count outside this file.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The reference viewports the firmware targets.
class ReferenceSize {
  const ReferenceSize._();

  /// `PCMonitorFirmware` - the square panel.
  static const Size square = Size(480, 480);

  /// `PCMonitorFirmware800_480` - the wide panel.
  static const Size wide = Size(800, 480);
}

/// Broad device buckets. The thresholds are in logical pixels of the *short*
/// side, which is orientation-independent by construction.
enum ScreenClass {
  /// Compact phones, short side < 380 (e.g. 360x640, 360x800).
  compact,

  /// Regular phones, short side 380..599 (e.g. 390x844, 412x915).
  phone,

  /// Small tablets and foldables unfolded, short side 600..839.
  tablet,

  /// Large tablets, short side >= 840.
  largeTablet,
}

/// Which structural layout to build.
enum LayoutVariant {
  /// Single stacked column that fills the viewport. Phones in portrait.
  compactStack,

  /// The same stacked column, sized for a wider portrait tablet.
  splitColumns,

  /// Dashboard grid driven by the wide reference - phones in landscape and
  /// tablets in portrait.
  gridWide,

  /// Wide dashboard grid with an extra column - tablets in landscape.
  gridExtraWide,
}

/// The resolved layout decision for the current viewport.
@immutable
class LayoutMetrics {
  const LayoutMetrics({
    required this.size,
    required this.shortSide,
    required this.longSide,
    required this.screenClass,
    required this.orientation,
    required this.variant,
    required this.scale,
    required this.gutter,
    required this.panelRadius,
    required this.panelPadding,
    required this.cornerCut,
    this.minFontSize = 9.0,
  });

  final Size size;

  /// `min(width, height)` - the primary driver of every metric.
  final double shortSide;

  /// `max(width, height)`.
  final double longSide;

  final ScreenClass screenClass;
  final Orientation orientation;
  final LayoutVariant variant;

  /// Uniform density scale, anchored so a 480 pt short side maps to 1.0.
  /// Clamped so text never collapses or balloons on extreme viewports.
  final double scale;

  /// Gap between panels.
  final double gutter;

  final double panelRadius;

  /// Inner padding of a panel.
  final double panelPadding;

  /// Chamfer applied to panel corners when the theme asks for it.
  final double cornerCut;

  /// Legibility floor applied by [font].
  ///
  /// 9 pt is the right floor for a layout that is free to scroll, but the
  /// viewport-filling dashboards need the labels to be able to give way, so
  /// [compressed] lowers this rather than forcing an overflow.
  final double minFontSize;

  bool get isPortrait => orientation == Orientation.portrait;
  bool get isLandscape => orientation == Orientation.landscape;

  bool get isWide =>
      variant == LayoutVariant.gridWide ||
      variant == LayoutVariant.gridExtraWide;

  bool get hasSideRail => variant == LayoutVariant.splitColumns;

  /// How many tiles fit side by side in a dashboard row.
  int get dashboardColumns {
    switch (variant) {
      case LayoutVariant.compactStack:
        return 1;
      case LayoutVariant.splitColumns:
        return 1;
      case LayoutVariant.gridWide:
        return 2;
      case LayoutVariant.gridExtraWide:
        return 3;
    }
  }

  /// Column count for a plain list of small rows (CPU cores, engines).
  ///
  /// Caps at 6 so a large tablet spends its extra width on density (more
  /// columns) instead of a handful of oversized rows.
  int listColumns(double availableWidth, {double minItemWidth = 150}) {
    final int fit = (availableWidth / (minItemWidth * scale)).floor();
    return math.max(1, math.min(6, fit));
  }

  /// Column count for the GPU / disk card lists.
  int cardColumns(double availableWidth, {double minCardWidth = 340}) {
    final int fit = (availableWidth / (minCardWidth * scale)).floor();
    return math.max(1, math.min(3, fit));
  }

  /// Font size scaled from a firmware point size.
  ///
  /// The firmware sizes are expressed against a 480 pt short side, so the
  /// mapping is intentionally close to identity on that reference and only
  /// departs from it on much smaller or larger screens.
  double font(double firmwareSize) {
    final double value = firmwareSize * scale;
    // Never let the floor push a label *above* the size its own design asked
    // for - `font(9)` must stay at most 9 pt whatever the floor says.
    final double floor = math.min(minFontSize, firmwareSize);
    return value.clamp(floor, firmwareSize * 2.4);
  }

  /// A linear size scaled from firmware pixels.
  double px(double firmwarePixels) => firmwarePixels * scale;

  /// A copy of these metrics compressed by [factor] (0.5 .. 1.0).
  ///
  /// The portrait dashboard has to fill a fixed height with no scrolling, so
  /// when the stacked column is taller than its viewport everything - fonts,
  /// gaps, panel padding - shrinks together until it fits. The legibility
  /// floor is relaxed at the same time; without that the 9-11 pt labels would
  /// refuse to shrink and the column would overflow instead of compress.
  LayoutMetrics compressed(double factor) {
    final double f = factor.clamp(0.5, 1.0);
    if (f >= 0.999) return this;
    final double s = (scale * f).clamp(0.45, 1.85);
    return LayoutMetrics(
      size: size,
      shortSide: shortSide,
      longSide: longSide,
      screenClass: screenClass,
      orientation: orientation,
      variant: variant,
      scale: s,
      gutter: (10.0 * s).clamp(6.0, 18.0),
      panelRadius: (12.0 * s).clamp(6.0, 20.0),
      panelPadding: (12.0 * s).clamp(6.0, 20.0),
      cornerCut: (12.0 * s).clamp(6.0, 20.0),
      minFontSize: 7.0,
    );
  }

  /// The height of the top command bar.
  double get headerHeight => isWide ? px(64) : px(72);

  /// The width of the persistent navigation rail, when one is shown.
  double get railWidth => px(72);

  /// The horizontal content inset.
  double get pagePadding => isWide ? px(16) : px(14);

  /// The aspect ratio for a dashboard processor card.
  double get processorAspectRatio => isWide ? 250 / 252 : 219 / 182;

  @override
  String toString() => 'LayoutMetrics(${screenClass.name}, '
      '${orientation.name}, ${variant.name}, '
      '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}, '
      'scale=${scale.toStringAsFixed(2)})';
}

/// Derives [LayoutMetrics] from a viewport.
class LayoutEngine {
  const LayoutEngine._();

  static const double _compactThreshold = 380;
  static const double _phoneThreshold = 600;
  static const double _tabletThreshold = 840;

  static ScreenClass classify(double shortSide) {
    if (shortSide < _compactThreshold) return ScreenClass.compact;
    if (shortSide < _phoneThreshold) return ScreenClass.phone;
    if (shortSide < _tabletThreshold) return ScreenClass.tablet;
    return ScreenClass.largeTablet;
  }

  static LayoutVariant variantFor(
    ScreenClass screenClass,
    Orientation orientation,
  ) {
    switch (screenClass) {
      case ScreenClass.compact:
        // A 360 pt wide portrait phone cannot host two columns without cramping
        // the large numerals, so everything stacks. In landscape there is
        // finally enough width for the grid.
        return orientation == Orientation.portrait
            ? LayoutVariant.compactStack
            : LayoutVariant.gridWide;

      case ScreenClass.phone:
        return orientation == Orientation.portrait
            ? LayoutVariant.compactStack
            : LayoutVariant.gridWide;

      case ScreenClass.tablet:
        // Portrait tablets are tall enough for a primary column plus a rail.
        return orientation == Orientation.portrait
            ? LayoutVariant.splitColumns
            : LayoutVariant.gridExtraWide;

      case ScreenClass.largeTablet:
        return orientation == Orientation.portrait
            ? LayoutVariant.gridWide
            : LayoutVariant.gridExtraWide;
    }
  }

  /// Anchors density so the 480 pt reference maps to 1.0, then damps the slope
  /// so a small phone does not shrink text into illegibility.
  static double scaleFor(double shortSide) {
    final double raw = shortSide / ReferenceSize.square.shortestSide;
    final double damped = 1.0 + (raw - 1.0) * 0.55;
    return damped.clamp(0.72, 1.85);
  }

  static LayoutMetrics resolve(Size size, Orientation orientation) {
    final double shortSide = size.shortestSide;
    final double longSide = size.longestSide;
    final ScreenClass screenClass = classify(shortSide);
    final LayoutVariant variant = variantFor(screenClass, orientation);
    final double scale = scaleFor(shortSide);

    final double gutter = (10.0 * scale).clamp(8.0, 18.0);
    final double radius = (12.0 * scale).clamp(8.0, 20.0);
    final double padding = (12.0 * scale).clamp(9.0, 20.0);

    return LayoutMetrics(
      size: size,
      shortSide: shortSide,
      longSide: longSide,
      screenClass: screenClass,
      orientation: orientation,
      variant: variant,
      scale: scale,
      gutter: gutter,
      panelRadius: radius,
      panelPadding: padding,
      cornerCut: radius,
    );
  }

  /// Reads the viewport from the widget tree.
  static LayoutMetrics of(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    return resolve(mq.size, mq.orientation);
  }
}

/// Exposes [LayoutMetrics] to the subtree without rebuilding the whole app.
class LayoutScope extends InheritedWidget {
  const LayoutScope({super.key, required this.metrics, required super.child});

  final LayoutMetrics metrics;

  static LayoutMetrics of(BuildContext context) {
    final LayoutScope? scope =
        context.dependOnInheritedWidgetOfExactType<LayoutScope>();
    assert(scope != null, 'LayoutScope is missing from the widget tree.');
    return scope!.metrics;
  }

  @override
  bool updateShouldNotify(LayoutScope oldWidget) =>
      oldWidget.metrics != metrics;
}

/// Convenience accessor: `context.layout`.
extension LayoutContext on BuildContext {
  LayoutMetrics get layout => LayoutScope.of(this);
}

/// Rebuilds its child whenever the viewport crosses a breakpoint.
///
/// Using `LayoutBuilder` (rather than raw `MediaQuery`) means the decision is
/// made against the space the widget actually receives - which matters once the
/// UI is embedded in a split-screen or foldable window.
class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, LayoutMetrics metrics) builder;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : mq.size.width,
          constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : mq.size.height,
        );
        final LayoutMetrics metrics = LayoutEngine.resolve(size, mq.orientation);
        return LayoutScope(metrics: metrics, child: builder(context, metrics));
      },
    );
  }
}
