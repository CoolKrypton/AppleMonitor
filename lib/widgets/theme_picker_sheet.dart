import 'package:flutter/material.dart';

import '../responsive/responsive.dart';
import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';
import 'hud.dart';

/// The theme picker sheet, reachable from the command bar on every page.
class ThemePickerSheet extends StatelessWidget {
  const ThemePickerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) => const ThemePickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final ThemeController controller = MonitorThemeScope.controllerOf(context);

    // A modal bottom sheet's context hangs off the Navigator overlay, which is
    // OUTSIDE the home subtree - so `context.layout` (LayoutScope) is not
    // reachable from here and the sheet used to render as an empty panel.
    // Resolve the metrics locally instead.
    return ResponsiveBuilder(
      builder: (BuildContext context, LayoutMetrics metrics) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.all(metrics.gutter),
          child: HudPanel(
            radius: metrics.panelRadius,
            padding: EdgeInsets.all(metrics.panelPadding),
            accent: theme.cpu,
            glow: 0.5,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    AccentChip(color: theme.cpu, height: metrics.font(14)),
                    const SizedBox(width: 8),
                    Text(
                      'INTERFACE THEME',
                      style: TextStyle(
                        color: theme.text,
                        fontSize: metrics.font(13),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(Icons.close, color: theme.muted, size: 18),
                      tooltip: 'Close',
                    ),
                  ],
                ),
                SizedBox(height: metrics.px(6)),
                // A Flexible inside a min-size Column collapses to zero inside
                // the sheet's constraints; a bounded scroll view renders the
                // list reliably and still lets short lists shrink.
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: metrics.px(430)),
                  child: SingleChildScrollView(
                    child: Column(
                      children: kMonitorThemes
                          .map((MonitorTheme option) => _ThemeTile(
                                option: option,
                                selected: option.id == theme.id,
                                onTap: () => controller.select(option),
                              ))
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      },
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final MonitorTheme option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme active = context.theme;
    final LayoutMetrics metrics = context.layout;

    return Padding(
      padding: EdgeInsets.only(bottom: metrics.gutter * 0.7),
      child: HudPanel(
        radius: metrics.panelRadius * 0.7,
        accent: selected ? option.cpu : active.border,
        borderWidth: selected ? 2 : 1,
        glow: selected ? 0.7 : 0,
        onTap: onTap,
        semanticLabel: '${option.name} theme',
        child: Row(
          children: <Widget>[
            // Live swatch strip so the choice is obvious before committing.
            SizedBox(
              width: metrics.px(6),
              height: metrics.px(46),
              child: Column(
                children: <Widget>[
                  Expanded(child: ColoredBox(color: option.cpu)),
                  Expanded(child: ColoredBox(color: option.gpu)),
                  Expanded(child: ColoredBox(color: option.ram)),
                  Expanded(child: ColoredBox(color: option.vram)),
                  Expanded(child: ColoredBox(color: option.bg)),
                ],
              ),
            ),
            SizedBox(width: metrics.px(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    option.name,
                    style: TextStyle(
                      color: option.text,
                      fontSize: metrics.font(14),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.description,
                    style: TextStyle(
                      color: option.muted,
                      fontSize: metrics.font(11),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, color: option.cpu, size: metrics.px(18)),
          ],
        ),
      ),
    );
  }
}
