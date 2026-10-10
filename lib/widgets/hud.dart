import 'package:flutter/material.dart';

import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';

/// A panel with an optional angular chamfer, hairline border and accent glow.
///
/// This replaces `ui_panel()` from the firmware, but gains the glow and chamfer
/// that make the HUD look read as "sci-fi" rather than merely dark.
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.child,
    this.accent,
    this.padding,
    this.radius,
    this.cornerCut = 0,
    this.glow = 0.0,
    this.filled = true,
    this.borderWidth = 1.0,
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;

  /// Tints the border and glow. `null` uses the theme border colour.
  final Color? accent;

  final EdgeInsets? padding;
  final double? radius;

  /// Chamfer size. `0` keeps rounded corners.
  final double cornerCut;

  /// 0..1 - intensity of the outer accent glow.
  final double glow;

  final bool filled;
  final double borderWidth;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = MonitorThemeScope.of(context);
    final double r = radius ?? 12;
    final Color borderColor = accent ?? theme.border;

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: filled ? theme.panel : Colors.transparent,
        borderRadius: cornerCut > 0 ? null : BorderRadius.circular(r),
        boxShadow: glow > 0
            ? <BoxShadow>[
                BoxShadow(
                  color: borderColor.withValues(alpha: 0.34 * glow),
                  blurRadius: 16 * glow + 4,
                ),
              ]
            : null,
      ),
      child: ClipPath(
        clipper: cornerCut > 0 ? ChamferClipper(cornerCut) : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: filled ? theme.panel : Colors.transparent,
            borderRadius: cornerCut > 0 ? null : BorderRadius.circular(r),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            child: child,
          ),
        ),
      ),
    );

    if (onTap != null) {
      surface = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: cornerCut > 0 ? null : BorderRadius.circular(r),
          splashColor: borderColor.withValues(alpha: 0.14),
          highlightColor: borderColor.withValues(alpha: 0.08),
          child: surface,
        ),
      );
    }

    if (semanticLabel != null) {
      surface = Semantics(label: semanticLabel, child: surface);
    }

    return surface;
  }
}

/// Clips a rectangle to an HUD-style chamfered octagon.
class ChamferClipper extends CustomClipper<Path> {
  const ChamferClipper(this.cut);

  final double cut;

  @override
  Path getClip(Size size) {
    final double c = cut.clamp(0.0, size.shortestSide / 2);
    return Path()
      ..moveTo(c, 0)
      ..lineTo(size.width - c, 0)
      ..lineTo(size.width, c)
      ..lineTo(size.width, size.height - c)
      ..lineTo(size.width - c, size.height)
      ..lineTo(c, size.height)
      ..lineTo(0, size.height - c)
      ..lineTo(0, c)
      ..close();
  }

  @override
  bool shouldReclip(ChamferClipper oldClipper) => oldClipper.cut != cut;
}

/// A thin accent bar drawn along one edge - the firmware's 3x13 "colour chip",
/// generalised.
class AccentChip extends StatelessWidget {
  const AccentChip({
    super.key,
    required this.color,
    this.width = 3,
    this.height = 13,
    this.radius = 1,
  });

  final Color color;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: <BoxShadow>[
          BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 7),
        ],
      ),
    );
  }
}

/// A pulsating status dot, used for the connection indicator.
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.color, this.size = 7});

  final Color color;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double t = _controller.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: widget.color.withValues(alpha: 0.30 + 0.45 * t),
                blurRadius: 4 + 8 * t,
                spreadRadius: 0.4 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A compact pill badge for text like `LIVE`, `SIM`, `HOME`.
class HudBadge extends StatelessWidget {
  const HudBadge({
    super.key,
    required this.label,
    required this.color,
    this.fontSize = 10,
    this.filled = false,
    this.horizontalPadding = 7,
    this.verticalPadding = 2,
  });

  final String label;
  final Color color;
  final double fontSize;
  final bool filled;
  final double horizontalPadding;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.75), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          height: 1.1,
        ),
      ),
    );
  }
}

/// Section heading: a small accent chip plus a letter-spaced caption.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.accent,
    this.fontSize = 11,
  });

  final String title;
  final Widget? trailing;
  final Color? accent;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = MonitorThemeScope.of(context);
    final Color color = accent ?? theme.cpu;

    return Row(
      children: <Widget>[
        AccentChip(color: color, width: 3, height: fontSize + 2),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.muted,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Small key/value pair used in dense info blocks.
class MetricLine extends StatelessWidget {
  const MetricLine({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.labelFontSize = 11,
    this.valueFontSize = 14,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final double labelFontSize;
  final double valueFontSize;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = MonitorThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: theme.muted,
            fontSize: labelFontSize,
            letterSpacing: 0.9,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              color: valueColor ?? theme.text,
              fontSize: valueFontSize,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// A thin progress track with an optional glow and an optional gradient.
///
/// Replaces `ui_bar()`. Corner radius is half the height in both, which is what
/// gives the firmware bars their capsule look.
class HudBar extends StatelessWidget {
  const HudBar({
    super.key,
    required this.value,
    required this.color,
    this.valid = true,
    this.height = 6,
    this.gradientTo,
    this.glow = 0.55,
  });

  /// 0..100.
  final double value;

  final Color color;
  final bool valid;
  final double height;

  /// When set the fill becomes a left-to-right gradient `color -> gradientTo`.
  final Color? gradientTo;

  final double glow;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = MonitorThemeScope.of(context);
    final double fraction = valid ? (value.clamp(0.0, 100.0) / 100.0) : 0.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        color: theme.track,
        child: Align(
          alignment: Alignment.centerLeft,
          // The fill eases itself with Flutter's animation pipeline: only
          // `end` is provided, so the tween resumes from wherever the bar
          // currently is and glides to the new snapshot value. No app-level
          // interpolation runs between telemetry ticks - the framework's
          // ticker does the work at display refresh rate.
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: fraction),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
            builder:
                (BuildContext context, double animated, Widget? nothing) {
              return FractionallySizedBox(
                widthFactor: animated,
                // FractionallySizedBox hands its child *loose* constraints,
                // and a bare DecoratedBox has no child to inflate from, so it
                // would collapse to 0x0 (a Container expands instead - the
                // previous implementation relied on that). SizedBox.expand
                // makes the intent explicit: fill the factored box.
                child: SizedBox.expand(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: gradientTo == null
                          ? null
                          : LinearGradient(
                              colors: <Color>[color, gradientTo!]),
                      color: gradientTo == null ? color : null,
                      borderRadius: BorderRadius.circular(height / 2),
                      boxShadow: glow > 0
                          ? <BoxShadow>[
                              BoxShadow(
                                color: color.withValues(alpha: glow * 0.8),
                                blurRadius: height * 1.6,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A chamfered HUD button. `filled` is the primary action, the outline form is
/// secondary; `danger` recolours it for destructive actions.
class HudButton extends StatelessWidget {
  const HudButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.accent,
    this.filled = false,
    this.danger = false,
    this.expand = false,
    this.height = 40,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? accent;
  final bool filled;
  final bool danger;
  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final double inset = (height * 0.22).clamp(8.0, 12.0);

    final Color base = onPressed == null
        ? theme.border
        : (danger
            ? theme.hot
            : (accent ?? theme.cpu));
    final Color foreground =
        onPressed == null ? theme.muted : (filled ? theme.bg : base);

    final Widget body = Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: inset),
      decoration: BoxDecoration(
        color: filled ? base : Colors.transparent,
        border: Border.all(color: base, width: 1),
        borderRadius: BorderRadius.circular(height * 0.18),
        boxShadow: filled && onPressed != null
            ? <BoxShadow>[
                BoxShadow(color: base.withValues(alpha: 0.34), blurRadius: 12),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: height * 0.44, color: foreground),
            SizedBox(width: height * 0.2),
          ],
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: height * 0.32,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(height * 0.18),
          splashColor: base.withValues(alpha: 0.16),
          highlightColor: base.withValues(alpha: 0.08),
          child: body,
        ),
      ),
    );
  }
}

/// The animated backdrop: a technical grid plus optional scanlines and a corner
/// vignette. Cheap enough to keep behind every screen.
class HudBackground extends StatelessWidget {
  const HudBackground({super.key, required this.child, this.accent});

  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = MonitorThemeScope.of(context);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: CustomPaint(
            painter: HudBackgroundPainter(
              theme: theme,
              accent: accent ?? theme.cpu,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class HudBackgroundPainter extends CustomPainter {
  HudBackgroundPainter({required this.theme, required this.accent});

  final MonitorTheme theme;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = theme.bg);

    switch (theme.backgroundMotif) {
      case BackgroundMotif.none:
        break;
      case BackgroundMotif.grid:
        _paintGrid(canvas, size);
      case BackgroundMotif.diagonal:
        _paintDiagonal(canvas, size);
      case BackgroundMotif.rings:
        _paintRings(canvas, size);
    }

    if (theme.scanlineOpacity > 0) _paintScanlines(canvas, size);

    // A soft accent bloom in the top-right, so panels do not float on a flat
    // field. Kept subtle to avoid washing out the small text.
    final Paint bloom = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          accent.withValues(alpha: theme.isDark ? 0.16 : 0.10),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(size.width * 0.86, size.height * 0.06),
          radius: size.shortestSide * 0.95,
        ),
      );
    canvas.drawRect(rect, bloom);
  }

  void _paintGrid(Canvas canvas, Size size) {
    final double step = (size.shortestSide / 26).clamp(16.0, 40.0);
    final Color line = theme.border.withValues(alpha: theme.gridOpacity * 0.55);
    final Paint paint = Paint()
      ..color = line
      ..strokeWidth = 0.6;

    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _paintDiagonal(Canvas canvas, Size size) {
    final double step = (size.shortestSide / 20).clamp(18.0, 44.0);
    final Paint paint = Paint()
      ..color = theme.border.withValues(alpha: theme.gridOpacity * 0.5)
      ..strokeWidth = 0.7;

    final double span = size.width + size.height;
    for (double offset = -size.height; offset <= span; offset += step) {
      canvas.drawLine(
        Offset(offset, 0),
        Offset(offset + size.height, size.height),
        paint,
      );
    }
  }

  void _paintRings(Canvas canvas, Size size) {
    final Offset center = Offset(size.width * 0.12, size.height * 0.92);
    final Paint paint = Paint()
      ..color = theme.border.withValues(alpha: theme.gridOpacity * 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;

    final double maxRadius = size.longestSide;
    for (double r = size.shortestSide * 0.10; r < maxRadius; r += size.shortestSide * 0.09) {
      canvas.drawCircle(center, r, paint);
    }
  }

  void _paintScanlines(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = theme.isDark
          ? Colors.black.withValues(alpha: theme.scanlineOpacity)
          : Colors.white.withValues(alpha: theme.scanlineOpacity);
    const double spacing = 3.0;
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(HudBackgroundPainter oldDelegate) =>
      oldDelegate.theme.id != theme.id || oldDelegate.accent != accent;
}
