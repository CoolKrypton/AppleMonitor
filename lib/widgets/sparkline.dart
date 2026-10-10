import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/monitor_theme.dart';

/// A 60-point sparkline with gap support, a filled area and an optional glow.
///
/// The firmware's chart uses `LV_CHART_POINT_NONE` for invalid points; `null`
/// entries here reproduce that exactly - the line breaks rather than
/// interpolating across a gap.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.points,
    required this.color,
    this.thresholdColor,
    this.threshold = 85,
    this.strokeWidth = 1.4,
    this.showGrid = true,
    this.minY = 0,
    this.maxY = 100,
  });

  /// Oldest first. `null` marks an invalid / missing sample.
  final List<double?> points;

  final Color color;

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
        color: color,
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

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.color,
    required this.thresholdColor,
    required this.threshold,
    required this.strokeWidth,
    required this.showGrid,
    required this.gridColor,
    required this.minY,
    required this.maxY,
  });

  final List<double?> points;
  final Color color;
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

    final double range = (maxY - minY) == 0 ? 1 : (maxY - minY);
    final double stepX = size.width / (points.length - 1);

    double xFor(int index) => index * stepX;
    double yFor(double value) =>
        size.height - ((value.clamp(minY, maxY) - minY) / range) * size.height;

    final Path line = Path();
    final Path area = Path();
    bool hasSegment = false;
    int firstIndexInSegment = 0;

    void flushSegment(int endIndexExclusive) {
      if (!hasSegment) return;
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
              color.withValues(alpha: 0.34),
              color.withValues(alpha: 0.02),
            ],
          ).createShader(Offset.zero & size),
      );
      hasSegment = false;
    }

    for (int i = 0; i < points.length; i++) {
      final double? value = points[i];
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
    flushSegment(points.length);

    // Glow pass first, then the crisp stroke on top.
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(
          colors: <Color>[color, thresholdColor],
        ).createShader(Offset.zero & size),
    );

    // Head marker on the newest valid sample.
    for (int i = points.length - 1; i >= 0; i--) {
      final double? value = points[i];
      if (value == null || !value.isFinite) continue;
      final Offset head = Offset(xFor(i), yFor(value));
      final Color headColor = value >= threshold ? thresholdColor : color;
      canvas.drawCircle(head, 3.4, Paint()..color = headColor.withValues(alpha: 0.30));
      canvas.drawCircle(head, 1.9, Paint()..color = headColor);
      break;
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) {
    if (oldDelegate.color != color) return true;
    if (oldDelegate.points.length != points.length) return true;
    for (int i = 0; i < points.length; i++) {
      if (oldDelegate.points[i] != points[i]) return true;
    }
    return false;
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
