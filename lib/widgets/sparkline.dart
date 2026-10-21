import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/monitor_theme.dart';

/// A time-addressed sparkline with gap support, a filled area and a glow.
///
/// The firmware's chart uses `LV_CHART_POINT_NONE` for invalid points; `null`
/// entries here reproduce that exactly - the line breaks rather than
/// interpolating across a gap.
///
/// When [times] is supplied the horizontal position of a point is its timestamp,
/// not its index: the plot always shows [windowMs] of history ending at the
/// newest sample. That is what keeps the window still. An index-addressed plot
/// spreads `n` points evenly across the width, so any change in `n` - and `n` is
/// at the mercy of packet timing - rescales the whole curve against the same
/// frame. With times, a late packet widens a gap on the right and nothing else
/// moves. Without [times] the old index behaviour is kept, for previews and
/// callers that hold no timestamps.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.points,
    required this.color,
    this.times,
    this.windowMs = 60000,
    this.secondaryPoints,
    this.secondaryTimes,
    this.secondaryColor,
    this.thresholdColor,
    this.threshold = 85,
    this.strokeWidth = 1.4,
    this.showGrid = true,
    this.minY = 0,
    this.maxY = 100,
  });

  /// Oldest first. `null` marks an invalid / missing sample.
  final List<double?> points;

  /// When each point was sampled, same length as [points]. `null` falls back to
  /// spreading the points evenly across the width.
  final List<int>? times;

  /// Width of the visible history, in milliseconds.
  final int windowMs;

  final Color color;

  /// An optional second series on the same plot, for the one case where two
  /// quantities share a unit and belong together - a disk's read and write
  /// throughput. It is drawn as a plain stroke in [secondaryColor] over the
  /// first series' filled area, so the two stay tellable apart.
  final List<double?>? secondaryPoints;

  /// Timestamps for [secondaryPoints]; falls back to [times] when omitted, which
  /// is correct for the read/write pair - both are appended on the same push.
  final List<int>? secondaryTimes;
  final Color? secondaryColor;

  /// Colour used when a point crosses [threshold].
  final Color? thresholdColor;
  final double threshold;

  final double strokeWidth;
  final bool showGrid;
  final double minY;
  final double maxY;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = MonitorThemeScope.of(context);
    return CustomPaint(
      painter: _SparklinePainter(
        points: points,
        times: times,
        windowMs: windowMs,
        color: color,
        secondaryPoints: secondaryPoints,
        secondaryTimes: secondaryTimes,
        secondaryColor: secondaryColor,
        thresholdColor: thresholdColor ?? theme.hot,
        threshold: threshold,
        strokeWidth: strokeWidth,
        showGrid: showGrid,
        gridColor: theme.border.withValues(alpha: 0.55),
        minY: minY,
        maxY: maxY,
      ),
      size: Size.infinite,
    );
  }
}

/// The vertical ceiling for a throughput plot: the tallest sample in the
/// window plus a little headroom, and never below [floor].
///
/// Throughput has no natural maximum the way a percentage does - a disk idles
/// at a few KB/s and peaks at GB/s - so a fixed 0..100 scale (the firmware's
/// choice, where the plot was a percentage) would draw every real disk as a
/// flat line at zero. The floor is what keeps an idle disk from rendering its
/// own rounding noise as a mountain range.
double sparklineCeiling(
  Iterable<List<double?>> series, {
  double floor = 1.0,
  double headroom = 1.15,
}) {
  double peak = 0;
  for (final List<double?> points in series) {
    for (final double? value in points) {
      if (value == null || !value.isFinite) continue;
      if (value > peak) peak = value;
    }
  }
  final double scaled = peak * headroom;
  return scaled > floor ? scaled : floor;
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.times,
    required this.windowMs,
    required this.color,
    required this.secondaryPoints,
    required this.secondaryTimes,
    required this.secondaryColor,
    required this.thresholdColor,
    required this.threshold,
    required this.strokeWidth,
    required this.showGrid,
    required this.gridColor,
    required this.minY,
    required this.maxY,
  });

  final List<double?> points;
  final List<int>? times;
  final int windowMs;
  final Color color;
  final List<double?>? secondaryPoints;
  final List<int>? secondaryTimes;
  final Color? secondaryColor;
  final Color thresholdColor;
  final double threshold;
  final double strokeWidth;
  final bool showGrid;
  final Color gridColor;
  final double minY;
  final double maxY;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // The grid paints before the data check on purpose: a card whose window
    // has not filled yet must still show the same ruled background as a card
    // with a full curve, otherwise the list reads as inconsistent panels.
    if (showGrid) {
      final Paint gridPaint = Paint()
        ..color = gridColor
        ..strokeWidth = 0.6;
      // Three horizontal division lines, as in the firmware chart.
      for (int i = 1; i <= 3; i++) {
        final double y = size.height * i / 4;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }
    }

    if (points.length < 2) return;

    // A second series with fewer than two points has no line to draw, so it is
    // discarded here rather than at paint time: the branch below then reads as
    // a plain null check on a local, which is what promotes `second` to a
    // non-nullable list for the call that follows.
    List<double?>? second = secondaryPoints;
    if (second != null && second.length < 2) second = null;

    // The right edge of the plot is the newest sample, so the visible span is
    // always the same [windowMs] however many points happen to be in it. One
    // domain for both series, or a disk's read and write lines would disagree
    // about where "now" is.
    final int? domainEnd = (times != null && times!.isNotEmpty)
        ? times!.last
        : null;

    // One series keeps the gradient stroke it always had. Two series on one
    // plot do not: each line would fade toward the very same hot colour across
    // the same span, and neither would read as itself. Paired series are
    // stroked flat in their own colour instead, the first one still carrying
    // the filled area so the two are distinguishable where they overlap.
    _paintSeries(
      canvas,
      size,
      points,
      times,
      color,
      fill: true,
      gradientStroke: second == null,
      domainEnd: domainEnd,
    );
    if (second != null) {
      _paintSeries(
        canvas,
        size,
        second,
        secondaryTimes ?? times,
        secondaryColor ?? color,
        fill: false,
        gradientStroke: false,
        domainEnd: domainEnd,
      );
    }
  }

  /// Draws one series: optional area fill, glow pass, stroke and head marker.
  void _paintSeries(
    Canvas canvas,
    Size size,
    List<double?> series,
    List<int>? seriesTimes,
    Color seriesColor, {
    required bool fill,
    required bool gradientStroke,
    required int? domainEnd,
  }) {
    final double range = (maxY - minY) == 0 ? 1 : (maxY - minY);
    final double stepX =
        series.length > 1 ? size.width / (series.length - 1) : size.width;

    // A caller that hands in a mismatched timestamp list falls back to index
    // spacing rather than throwing a RangeError mid-paint.
    final bool byTime = seriesTimes != null &&
        domainEnd != null &&
        seriesTimes.length == series.length;
    final int domainStart = (domainEnd ?? 0) - windowMs;

    double xFor(int index) {
      if (!byTime) return index * stepX;
      // `byTime` implies the list is there and is index-aligned with the
      // series, which is exactly the RangeError this guard exists to avoid.
      final double fraction = (seriesTimes[index] - domainStart) / windowMs;
      // Samples older than the window can only arrive with a clock jump; they
      // belong at the left edge, not off-canvas.
      final double clamped = fraction <= 0 ? 0 : (fraction >= 1 ? 1 : fraction);
      return clamped * size.width;
    }

    double yFor(double value) =>
        size.height - ((value.clamp(minY, maxY) - minY) / range) * size.height;

    final Path line = Path();
    final Path area = Path();
    bool hasSegment = false;
    int firstIndexInSegment = 0;

    void flushSegment(int endIndexExclusive) {
      if (!hasSegment) return;
      if (fill) {
        // Close the area back down to the baseline.
        final Path closing = Path()
          ..addPath(area, Offset.zero)
          ..lineTo(xFor(endIndexExclusive - 1), size.height)
          ..lineTo(xFor(firstIndexInSegment), size.height)
          ..close();

        canvas.drawPath(
          closing,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                seriesColor.withValues(alpha: 0.34),
                seriesColor.withValues(alpha: 0.02),
              ],
            ).createShader(Offset.zero & size),
        );
      }
      hasSegment = false;
    }

    for (int i = 0; i < series.length; i++) {
      final double? value = series[i];
      if (value == null || !value.isFinite) {
        flushSegment(i);
        continue;
      }
      final Offset point = Offset(xFor(i), yFor(value));
      if (!hasSegment) {
        line.moveTo(point.dx, point.dy);
        area.reset();
        area.moveTo(point.dx, size.height);
        area.lineTo(point.dx, point.dy);
        firstIndexInSegment = i;
        hasSegment = true;
      } else {
        line.lineTo(point.dx, point.dy);
        area.lineTo(point.dx, point.dy);
      }
    }
    flushSegment(series.length);

    // Glow pass first, then the crisp stroke on top.
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = seriesColor.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (gradientStroke) {
      stroke.shader = LinearGradient(
        colors: <Color>[seriesColor, thresholdColor],
      ).createShader(Offset.zero & size);
    } else {
      stroke.color = seriesColor;
    }
    canvas.drawPath(line, stroke);

    // Head marker on the newest valid sample.
    for (int i = series.length - 1; i >= 0; i--) {
      final double? value = series[i];
      if (value == null || !value.isFinite) continue;
      final Offset head = Offset(xFor(i), yFor(value));
      final Color headColor =
          value >= threshold ? thresholdColor : seriesColor;
      canvas.drawCircle(head, 3.4, Paint()..color = headColor.withValues(alpha: 0.30));
      canvas.drawCircle(head, 1.9, Paint()..color = headColor);
      break;
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) {
    if (oldDelegate.color != color) return true;
    if (oldDelegate.secondaryColor != secondaryColor) return true;
    if (oldDelegate.thresholdColor != thresholdColor) return true;
    if (oldDelegate.threshold != threshold) return true;
    if (oldDelegate.strokeWidth != strokeWidth) return true;
    if (oldDelegate.showGrid != showGrid) return true;
    if (oldDelegate.minY != minY || oldDelegate.maxY != maxY) return true;
    if (oldDelegate.windowMs != windowMs) return true;
    if (!_sameTimes(oldDelegate.times, times)) return true;
    if (!_sameTimes(oldDelegate.secondaryTimes, secondaryTimes)) return true;
    if (!_sameSeries(oldDelegate.points, points)) return true;
    return !_sameSeries(oldDelegate.secondaryPoints, secondaryPoints);
  }

  /// Timestamps move even when the values do not - a steady 100 % line still
  /// slides left as the window advances, and a mark at the wrong x is a bug.
  static bool _sameTimes(List<int>? a, List<int>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Content comparison, because the provider hands out a fresh unmodifiable
  /// copy on every read - comparing instances would repaint on every frame.
  static bool _sameSeries(List<double?>? a, List<double?>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A compact per-core / per-engine mini bar strip, used where the firmware draws
/// a full chart but the row is only a few pixels tall.
class MicroBars extends StatelessWidget {
  const MicroBars({
    super.key,
    required this.points,
    required this.color,
    this.gap = 1.5,
    this.radius = 1.2,
  });

  final List<double?> points;
  final Color color;
  final double gap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = MonitorThemeScope.of(context);
    if (points.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int count = points.length;
        final double barWidth =
            math.max(1.0, (constraints.maxWidth - gap * (count - 1)) / count);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List<Widget>.generate(count, (int i) {
            final double? value = points[i];
            final double fraction =
                value == null ? 0 : (value.clamp(0.0, 100.0) / 100.0);
            return Padding(
              padding: EdgeInsets.only(right: i == count - 1 ? 0 : gap),
              child: SizedBox(
                width: barWidth,
                height: constraints.maxHeight,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: value == null ? 0.03 : math.max(0.03, fraction),
                      // Fill the factored box explicitly: a bare DecoratedBox
                      // would collapse to 0x0 under the loose constraints.
                      child: SizedBox.expand(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: value == null ? theme.track : color,
                            borderRadius: BorderRadius.circular(radius),
                          ),
                        ),
                      ),
                    ),
                  ),
              ),
            );
          }),
        );
      },
    );
  }
}
