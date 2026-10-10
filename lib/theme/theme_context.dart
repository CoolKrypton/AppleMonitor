import 'package:flutter/material.dart';

import 'monitor_theme.dart';

/// Inherited theme accessor plus a few context conveniences used across the UI.
extension ThemeShortcuts on BuildContext {
  MonitorTheme get theme => MonitorThemeScope.of(this);

  bool get isPortrait =>
      MediaQuery.orientationOf(this) == Orientation.portrait;

  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;
}
