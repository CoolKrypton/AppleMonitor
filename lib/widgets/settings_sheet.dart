import 'package:flutter/material.dart';

import '../responsive/responsive.dart';
import '../services/tap_sound.dart';
import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';
import 'hud.dart';

/// The settings sheet, reachable from the command bar on every page.
///
/// It holds the two things a user actually tunes on this app - the interface
/// skin and the tap effect - and it is deliberately *not* on the dashboard:
/// the dashboard is a full-viewport instrument where every panel is a reading,
/// and a settings row there would compete with the telemetry for space.
class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) => const SettingsSheet(),
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      AccentChip(color: theme.cpu, height: metrics.font(14)),
                      const SizedBox(width: 8),
                      Text(
                        'SETTINGS',
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
                  SizedBox(height: metrics.px(4)),
                  SectionHeader(
                    title: 'Interface sound',
                    accent: theme.cpu,
                    fontSize: metrics.font(11),
                  ),
                  SizedBox(height: metrics.px(8)),
                  const SoundToggleTile(),
                  SizedBox(height: metrics.gutter),
                  SectionHeader(
                    title: 'Interface theme',
                    accent: theme.cpu,
                    fontSize: metrics.font(11),
                  ),
                  SizedBox(height: metrics.px(8)),
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

/// The tap-effect switch.
///
/// The whole row is the tap target, not just the toggle - a 20 pt knob is a
/// poor hit area on a phone, and this row has nothing else in it. Switching it
/// on plays one bubble straight away ([TapSoundController.setEnabled] does
/// that), because the tap that flipped the switch was still muted when the
/// listener heard it; switching it off does not, because that tap was audible
/// and is the last sound the effect makes.
class SoundToggleTile extends StatelessWidget {
  const SoundToggleTile({super.key});

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final TapSoundController? controller = TapSoundScope.maybeOf(context);
    final bool enabled = controller?.enabled ?? false;

    return HudPanel(
      radius: metrics.panelRadius * 0.7,
      accent: enabled ? theme.cpu : theme.border,
      glow: enabled ? 0.45 : 0,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.px(12),
        vertical: metrics.px(10),
      ),
      onTap: controller == null ? null : () => controller.setEnabled(!enabled),
      semanticLabel: 'Tap sounds',
      child: Row(
        children: <Widget>[
          Icon(
            enabled ? Icons.graphic_eq : Icons.volume_off_outlined,
            color: enabled ? theme.cpu : theme.muted,
            size: metrics.px(17),
          ),
          SizedBox(width: metrics.px(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Tap sounds',
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(13),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                SizedBox(height: metrics.px(2)),
                Text(
                  enabled
                      ? 'A soft bubble under every tap'
                      : 'Silent interface',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(10),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: metrics.px(10)),
          Semantics(
            toggled: enabled,
            child: _HudToggle(value: enabled, accent: theme.cpu),
          ),
        ],
      ),
    );
  }
}

/// A HUD-shaped switch: a chamfered track and a travelling knob.
///
/// Hand-drawn rather than a Material `Switch` for two reasons: the platform
/// control brings its own colours and padding into a panel that uses none of
/// them, and its two "active" tint properties have been churning through
/// deprecations. This one is four lines of layout and reads correctly in every
/// skin, light or dark.
class _HudToggle extends StatelessWidget {
  const _HudToggle({required this.value, required this.accent});

  final bool value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final double width = metrics.px(40);
    final double height = metrics.px(23);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: width,
      height: height,
      padding: EdgeInsets.all(metrics.px(3)),
      decoration: BoxDecoration(
        color: value ? accent.withValues(alpha: 0.20) : theme.track,
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(
          color: value ? accent.withValues(alpha: 0.85) : theme.border,
        ),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: height - metrics.px(6),
          height: height - metrics.px(6),
          decoration: BoxDecoration(
            color: value ? accent : theme.muted,
            borderRadius: BorderRadius.circular(height),
            boxShadow: value
                ? <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: 0.55),
                      blurRadius: metrics.px(6),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
        ),
      ),
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
