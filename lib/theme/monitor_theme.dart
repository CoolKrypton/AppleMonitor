/// Theme system.
///
/// The semantic channel colours (CPU / GPU / RAM / VRAM / hot) are preserved
/// from `ui_style.h` so the Android client and the ESP32 firmware read the same
/// way. Everything else - surface, border, glow, background motifs - varies per
/// theme, which is what makes the theme switcher feel meaningful.
library;

import 'package:flutter/material.dart';

/// Semantic channel roles. These never change meaning across themes.
enum ChannelRole { cpu, gpu, ram, vram, hot, danger }

/// A complete visual identity.
///
/// [bg] / [panel] / [panelAlt] / [border] / [track] / [text] / [muted] come in
/// two flavours per theme: the light variant must stay light with dark text so
/// the app remains readable outdoors.
@immutable
class MonitorTheme {
  const MonitorTheme({
    required this.id,
    required this.name,
    required this.description,
    required this.brightness,
    required this.bg,
    required this.panel,
    required this.panelAlt,
    required this.border,
    required this.track,
    required this.text,
    required this.muted,
    required this.cpu,
    required this.gpu,
    required this.ram,
    required this.vram,
    required this.hot,
    required this.danger,
    required this.glow,
    this.gridOpacity = 0.35,
    this.scanlineOpacity = 0.06,
    this.cornerCut = 0,
    this.fontFamily,
    this.backgroundMotif = BackgroundMotif.grid,
  });

  final String id;
  final String name;
  final String description;
  final Brightness brightness;

  // Surfaces
  final Color bg;
  final Color panel;
  final Color panelAlt;
  final Color border;
  final Color track;

  // Content
  final Color text;
  final Color muted;

  // Semantic channels
  final Color cpu;
  final Color gpu;
  final Color ram;
  final Color vram;
  final Color hot;
  final Color danger;

  /// Accent glow used for shadows and halo effects.
  final Color glow;

  final double gridOpacity;
  final double scanlineOpacity;

  /// Corner chamfer in logical pixels. `0` keeps square corners; larger values
  /// give the panel an angular "HUD" silhouette.
  final double cornerCut;

  /// Optional display font family (e.g. `Orbitron` when bundled).
  final String? fontFamily;

  final BackgroundMotif backgroundMotif;

  bool get isDark => brightness == Brightness.dark;

  Color channel(ChannelRole role) {
    switch (role) {
      case ChannelRole.cpu:
        return cpu;
      case ChannelRole.gpu:
        return gpu;
      case ChannelRole.ram:
        return ram;
      case ChannelRole.vram:
        return vram;
      case ChannelRole.hot:
        return hot;
      case ChannelRole.danger:
        return danger;
    }
  }

  /// The matching `ThemeData` for Material widgets (dialogs, tooltips, ripples).
  ThemeData toThemeData() {
    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: cpu,
      onPrimary: isDark ? bg : Colors.white,
      secondary: gpu,
      onSecondary: isDark ? bg : Colors.white,
      error: danger,
      onError: isDark ? bg : Colors.white,
      surface: panel,
      onSurface: text,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: panel,
      fontFamily: fontFamily,
      splashFactory: InkSparkle.splashFactory,
      // Every text role is spelled out with an explicit `decoration: none`.
      // On Huawei/EMUI devices, text whose final style carries no explicit
      // decoration gets the platform underline paint flag injected and renders
      // with a pure-yellow double underline. Material regions (inside a
      // Material/InkWell) are unaffected, which is why only some panels showed
      // it. Anchoring every role kills it app-wide.
      textTheme: () {
        final TextStyle body = TextStyle(
          color: text,
          decoration: TextDecoration.none,
        );
        final TextStyle soft = TextStyle(
          color: muted,
          decoration: TextDecoration.none,
        );
        return TextTheme(
          displayLarge: body,
          displayMedium: body,
          displaySmall: body,
          headlineLarge: body,
          headlineMedium: body,
          headlineSmall: body,
          titleLarge: body,
          titleMedium: body,
          titleSmall: body,
          bodyLarge: body,
          bodyMedium: body,
          bodySmall: soft,
          labelLarge: body,
          labelMedium: soft,
          labelSmall: soft,
        );
      }(),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(color: muted, fontSize: 13),
      ),
    );
  }

  MonitorTheme copyWith({String? name, String? description}) => MonitorTheme(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        brightness: brightness,
        bg: bg,
        panel: panel,
        panelAlt: panelAlt,
        border: border,
        track: track,
        text: text,
        muted: muted,
        cpu: cpu,
        gpu: gpu,
        ram: ram,
        vram: vram,
        hot: hot,
        danger: danger,
        glow: glow,
        gridOpacity: gridOpacity,
        scanlineOpacity: scanlineOpacity,
        cornerCut: cornerCut,
        fontFamily: fontFamily,
        backgroundMotif: backgroundMotif,
      );
}

enum BackgroundMotif {
  /// Fine technical grid - the default HUD backdrop.
  grid,

  /// Diagonal hairlines, evokes a wireframe cockpit.
  diagonal,

  /// Concentric rings from a corner.
  rings,

  /// Flat, no pattern.
  none,
}

// ---------------------------------------------------------------------------
// Built-in themes
// ---------------------------------------------------------------------------

const Color _kFirmwareBg = Color(0xFF0B1017);
const Color _kFirmwarePanel = Color(0xFF131C27);
const Color _kFirmwareBorder = Color(0xFF243140);
const Color _kFirmwareTrack = Color(0xFF243342);
const Color _kFirmwareText = Color(0xFFEDF3FA);
const Color _kFirmwareMuted = Color(0xFF8C9EB2);
const Color _kFirmwareCpu = Color(0xFF55D9E8);
const Color _kFirmwareGpu = Color(0xFFB0E580);
const Color _kFirmwareRam = Color(0xFF94A9FF);
const Color _kFirmwareVram = Color(0xFFD5B3EE);
const Color _kFirmwareHot = Color(0xFFF4BA73);
const Color _kFirmwareDanger = Color(0xFFF06F6F);

/// The reference theme. Values are lifted verbatim from `ui_style.h` so the
/// Android client is pixel-comparable with the 480x480 firmware UI.
const MonitorTheme firmwareDark = MonitorTheme(
  id: 'firmware_dark',
  name: 'Firmware Dark',
  description: 'The original ESP32 palette, unchanged.',
  brightness: Brightness.dark,
  bg: _kFirmwareBg,
  panel: _kFirmwarePanel,
  panelAlt: Color(0xFF17222F),
  border: _kFirmwareBorder,
  track: _kFirmwareTrack,
  text: _kFirmwareText,
  muted: _kFirmwareMuted,
  cpu: _kFirmwareCpu,
  gpu: _kFirmwareGpu,
  ram: _kFirmwareRam,
  vram: _kFirmwareVram,
  hot: _kFirmwareHot,
  danger: _kFirmwareDanger,
  glow: _kFirmwareCpu,
  gridOpacity: 0.28,
  scanlineOpacity: 0.04,
  backgroundMotif: BackgroundMotif.grid,
);

/// Neon cyan/magenta - the loudest of the set.
const MonitorTheme neonPulse = MonitorTheme(
  id: 'neon_pulse',
  name: 'Neon Pulse',
  description: 'Cyan and magenta on deep indigo.',
  brightness: Brightness.dark,
  bg: Color(0xFF07060F),
  panel: Color(0xFF121026),
  panelAlt: Color(0xFF1A1735),
  border: Color(0xFF3A2F6B),
  track: Color(0xFF261F4A),
  text: Color(0xFFF2EEFF),
  muted: Color(0xFF9C90C8),
  cpu: Color(0xFF3BF0FF),
  gpu: Color(0xFF7CFF9E),
  ram: Color(0xFFB18CFF),
  vram: Color(0xFFFF8CE0),
  hot: Color(0xFFFFC46B),
  danger: Color(0xFFFF5C8A),
  glow: Color(0xFF3BF0FF),
  gridOpacity: 0.42,
  scanlineOpacity: 0.08,
  cornerCut: 14,
  backgroundMotif: BackgroundMotif.grid,
);

/// Amber CRT - warm phosphor, restrained glow.
const MonitorTheme amberTerminal = MonitorTheme(
  id: 'amber_terminal',
  name: 'Amber CRT',
  description: 'Warm phosphor terminal with soft bloom.',
  brightness: Brightness.dark,
  bg: Color(0xFF0E0A05),
  panel: Color(0xFF1C1409),
  panelAlt: Color(0xFF241A0C),
  border: Color(0xFF4A3616),
  track: Color(0xFF33240E),
  text: Color(0xFFFFE9C4),
  muted: Color(0xFFB39262),
  cpu: Color(0xFFFFB347),
  gpu: Color(0xFFE8D96A),
  ram: Color(0xFFFF8A50),
  vram: Color(0xFFD9A66B),
  hot: Color(0xFFFF7A45),
  danger: Color(0xFFFF4D3D),
  glow: Color(0xFFFFB347),
  gridOpacity: 0.30,
  scanlineOpacity: 0.14,
  backgroundMotif: BackgroundMotif.diagonal,
);

/// Ice blue, high contrast, clinical.
const MonitorTheme cryoBlue = MonitorTheme(
  id: 'cryo_blue',
  name: 'Cryo Blue',
  description: 'Cold clinical blues with crisp edges.',
  brightness: Brightness.dark,
  bg: Color(0xFF061019),
  panel: Color(0xFF0D1D2C),
  panelAlt: Color(0xFF12283A),
  border: Color(0xFF1E4460),
  track: Color(0xFF16324A),
  text: Color(0xFFE7F5FF),
  muted: Color(0xFF7FA7C4),
  cpu: Color(0xFF4CC9FF),
  gpu: Color(0xFF5BE7C4),
  ram: Color(0xFF7FA0FF),
  vram: Color(0xFFB39DFF),
  hot: Color(0xFFFFC078),
  danger: Color(0xFFFF6B6B),
  glow: Color(0xFF4CC9FF),
  gridOpacity: 0.34,
  scanlineOpacity: 0.05,
  backgroundMotif: BackgroundMotif.grid,
);

/// Matrix green, terse, terminal-like.
const MonitorTheme matrixGreen = MonitorTheme(
  id: 'matrix_green',
  name: 'Matrix',
  description: 'Monochrome green terminal aesthetic.',
  brightness: Brightness.dark,
  bg: Color(0xFF040B06),
  panel: Color(0xFF0A160D),
  panelAlt: Color(0xFF0E1E12),
  border: Color(0xFF1B3A22),
  track: Color(0xFF13301B),
  text: Color(0xFFD6FFE0),
  muted: Color(0xFF6FA97F),
  cpu: Color(0xFF43FF7A),
  gpu: Color(0xFF8AFF6B),
  ram: Color(0xFF29D98B),
  vram: Color(0xFF5FE8AE),
  hot: Color(0xFFC8FF5C),
  danger: Color(0xFFFF6B6B),
  glow: Color(0xFF43FF7A),
  gridOpacity: 0.38,
  scanlineOpacity: 0.10,
  backgroundMotif: BackgroundMotif.diagonal,
);

/// Light theme - the daylight / docked-monitor option.
const MonitorTheme daylight = MonitorTheme(
  id: 'daylight',
  name: 'Daylight',
  description: 'Light surfaces with dark text for bright rooms.',
  brightness: Brightness.light,
  bg: Color(0xFFEEF2F7),
  panel: Color(0xFFFFFFFF),
  panelAlt: Color(0xFFF6F9FC),
  border: Color(0xFFD2DCE8),
  track: Color(0xFFDEE7F0),
  text: Color(0xFF121A24),
  muted: Color(0xFF5C6E82),
  cpu: Color(0xFF0E7C93),
  gpu: Color(0xFF3E7A2E),
  ram: Color(0xFF3B54B8),
  vram: Color(0xFF7A4FA3),
  hot: Color(0xFFB4690E),
  danger: Color(0xFFC0392B),
  glow: Color(0xFF0E7C93),
  gridOpacity: 0.30,
  scanlineOpacity: 0.0,
  backgroundMotif: BackgroundMotif.grid,
);

/// Every selectable theme, in menu order.
const List<MonitorTheme> kMonitorThemes = <MonitorTheme>[
  firmwareDark,
  cryoBlue,
  neonPulse,
  amberTerminal,
  matrixGreen,
  daylight,
];

/// Preference key under which the chosen skin is stored, next to the pairing
/// material in the same `SharedPreferences` file.
const String kThemePreferenceKey = 'pcmonitor.themeId';

/// The theme carrying [id], falling back to [cryoBlue] when the id is missing
/// or no longer exists (a theme removed between releases must not brick the
/// startup path).
MonitorTheme themeForId(String? id) {
  for (final MonitorTheme candidate in kMonitorThemes) {
    if (candidate.id == id) return candidate;
  }
  return cryoBlue;
}

/// Owns the active theme. Persisting the choice is the owner's job - the app
/// root writes [kThemePreferenceKey] whenever this controller notifies.
class ThemeController extends ChangeNotifier {
  ThemeController({MonitorTheme initial = cryoBlue}) : _theme = initial;

  MonitorTheme _theme;

  MonitorTheme get theme => _theme;

  String get themeId => _theme.id;

  void select(MonitorTheme next) {
    if (next.id == _theme.id) return;
    _theme = next;
    notifyListeners();
  }

  /// Cycles to the next theme - wired to a long-press on the status badge.
  void cycle() {
    final int index = kMonitorThemes.indexWhere(
      (MonitorTheme t) => t.id == _theme.id,
    );
    final int next = index < 0 ? 0 : (index + 1) % kMonitorThemes.length;
    select(kMonitorThemes[next]);
  }

  void selectById(String id) {
    for (final MonitorTheme candidate in kMonitorThemes) {
      if (candidate.id == id) {
        select(candidate);
        return;
      }
    }
  }
}

/// Convenience accessor: `context.monitorTheme`.
extension MonitorThemeContext on BuildContext {
  MonitorTheme get monitor => MonitorThemeScope.of(this);
}

/// Inherited widget carrying the active [MonitorTheme].
class MonitorThemeScope extends InheritedNotifier<ThemeController> {
  const MonitorThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static MonitorTheme of(BuildContext context) {
    final MonitorThemeScope? scope =
        context.dependOnInheritedWidgetOfExactType<MonitorThemeScope>();
    assert(scope != null, 'MonitorThemeScope is missing from the widget tree.');
    return scope!.notifier!.theme;
  }

  static ThemeController controllerOf(BuildContext context) {
    final MonitorThemeScope? scope =
        context.dependOnInheritedWidgetOfExactType<MonitorThemeScope>();
    assert(scope != null, 'MonitorThemeScope is missing from the widget tree.');
    return scope!.notifier!;
  }
}
