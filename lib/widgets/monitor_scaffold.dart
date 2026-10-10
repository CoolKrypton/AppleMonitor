import 'package:flutter/material.dart';

import '../responsive/responsive.dart';
import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';
import 'hud.dart';

/// The chrome every page shares: a command bar on top, an optional navigation
/// rail on the side, and the HUD background behind everything.
///
/// The firmware has no equivalent single widget - `ui_detail_screen()` plus
/// `ui_statusbar_create()` cover roughly the same ground - but consolidating it
/// here is what makes the responsive rules tractable.
class MonitorScaffold extends StatelessWidget {
  const MonitorScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.body,
    this.accent,
    this.leading,
    this.actions = const <Widget>[],
    this.showRail = true,
    this.footer,
  });

  final String title;

  /// Secondary line under the title; the firmware uses it for counts and hints.
  final String subtitle;

  final Widget body;
  final Color? accent;
  final Widget? leading;
  final List<Widget> actions;
  final bool showRail;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final LayoutMetrics metrics = context.layout;
    final MonitorTheme theme = context.theme;
    final Color accentColor = accent ?? theme.cpu;

    final bool railVisible = showRail && metrics.hasSideRail;

    return HudBackground(
      accent: accentColor,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            _CommandBar(
              title: title,
              subtitle: subtitle,
              accent: accentColor,
              leading: leading,
              actions: actions,
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (railVisible)
                    _NavigationRail(
                      accent: accentColor,
                      width: metrics.railWidth,
                    ),
                  Expanded(child: body),
                ],
              ),
            ),
            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }
}

class _CommandBar extends StatelessWidget {
  const _CommandBar({
    required this.title,
    required this.subtitle,
    required this.accent,
    this.leading,
    this.actions = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final Color accent;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final LayoutMetrics metrics = context.layout;
    final MonitorTheme theme = context.theme;

    return SizedBox(
      height: metrics.headerHeight,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: metrics.pagePadding),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              leading!,
              SizedBox(width: metrics.gutter),
            ],
            AccentChip(
              color: accent,
              width: 3 * metrics.scale.clamp(0.8, 1.6),
              height: metrics.font(20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.text,
                      fontSize: metrics.font(18),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.muted,
                        fontSize: metrics.font(10),
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// A vertical icon rail shown on tall/wide layouts as an alternative to the
/// back button. Purely navigational sugar - the same destinations.
class _NavigationRail extends StatelessWidget {
  const _NavigationRail({required this.accent, required this.width});

  final Color accent;
  final double width;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    return Container(
      width: width,
      margin: EdgeInsets.only(left: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.border, width: 1)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.memory, color: accent, size: width * 0.4),
          const SizedBox(height: 4),
          Text(
            'MON',
            style: TextStyle(
              color: theme.muted,
              fontSize: 9,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// The back affordance used on every detail page. Mirrors the firmware's
/// `< HOME` / `< DEVICES` panel, but as a real button.
class BackButtonHud extends StatelessWidget {
  const BackButtonHud({
    super.key,
    required this.label,
    required this.onPressed,
    this.accent,
  });

  final String label;
  final VoidCallback onPressed;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final LayoutMetrics metrics = context.layout;
    final MonitorTheme theme = context.theme;
    final Color color = accent ?? theme.text;

    return HudPanel(
      radius: metrics.panelRadius * 0.7,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.px(10),
        vertical: metrics.px(7),
      ),
      onTap: onPressed,
      semanticLabel: 'Back to $label',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.chevron_left, size: metrics.font(16), color: color),
          SizedBox(width: metrics.px(2)),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: metrics.font(11),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}
