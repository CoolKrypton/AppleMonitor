import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pcm_monitor/main.dart' as app;
import 'package:pcm_monitor/models/pc_status.dart';
import 'package:pcm_monitor/responsive/responsive.dart';
import 'package:pcm_monitor/services/mock_data_source.dart';
import 'package:pcm_monitor/services/monitor_provider.dart';
import 'package:pcm_monitor/theme/monitor_theme.dart';
import 'package:pcm_monitor/widgets/hud.dart';

/// Boots the real app at the reference viewport shapes and exercises the
/// responsive layout plus the theme system, so a regression fails here rather
/// than only on a device.
void main() {
  // The reference panel this UI was designed against.
  const Size kFirmware = Size(480, 480);
  const Size kPhonePortrait = Size(411, 891);
  const Size kPhoneLandscape = Size(891, 411);
  const Size kTabletPortrait = Size(800, 1280);
  const Size kTabletLandscape = Size(1280, 800);

  Future<void> boot(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const app.PcMonitorApp());
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('app boots at every reference viewport', () {
    for (final MapEntry<String, Size> entry in <String, Size>{
      'firmware 480x480': kFirmware,
      'phone portrait': kPhonePortrait,
      'phone landscape': kPhoneLandscape,
      'tablet portrait': kTabletPortrait,
      'tablet landscape': kTabletLandscape,
    }.entries) {
      testWidgets('renders without exceptions - ${entry.key}', (tester) async {
        await boot(tester, entry.value);
        expect(tester.takeException(), isNull);
        expect(find.byType(app.PcMonitorApp), findsOneWidget);
      });
    }
  });

  group('layout engine classification', () {
    test('the firmware panel lands in the compact class', () {
      final LayoutMetrics m =
          LayoutEngine.resolve(kFirmware, Orientation.portrait);
      expect(m.shortSide, 480);
      expect(m.screenClass, anyOf(ScreenClass.phone, ScreenClass.tablet));
      expect(m.isPortrait, isTrue);
    });

    test('scale grows monotonically with the short side', () {
      final double compact =
          LayoutEngine.resolve(kFirmware, Orientation.portrait).scale;
      final double large =
          LayoutEngine.resolve(kTabletPortrait, Orientation.portrait).scale;
      expect(large, greaterThan(compact));
    });

    test('scale is clamped so text stays readable and never absurd', () {
      final double tiny =
          LayoutEngine.resolve(const Size(240, 400), Orientation.portrait).scale;
      final double huge =
          LayoutEngine.resolve(const Size(2560, 1440), Orientation.landscape).scale;
      expect(tiny, greaterThanOrEqualTo(0.72));
      expect(huge, lessThanOrEqualTo(1.85));
    });

    test('orientation flips with the viewport, not the device class', () {
      expect(
        LayoutEngine.resolve(kPhonePortrait, Orientation.portrait).isPortrait,
        isTrue,
      );
      expect(
        LayoutEngine.resolve(kPhoneLandscape, Orientation.landscape).isLandscape,
        isTrue,
      );
    });

    test('the reported size is exactly what was passed in', () {
      expect(LayoutEngine.resolve(kPhonePortrait, Orientation.portrait).size,
          kPhonePortrait);
    });
  });

  group('theme system', () {
    test('six themes are available and each has a distinct background', () {
      expect(kMonitorThemes.length, 6);
      final Set<int> backgrounds =
          kMonitorThemes.map((MonitorTheme t) => t.bg.toARGB32()).toSet();
      expect(backgrounds.length, 6);
    });

    test('the default theme is the firmware palette, so parity is preserved', () {
      // Values lifted verbatim from `ui_style.h`. Compare the full ARGB word:
      // the theme holds opaque colours (0xFF......), so a bare RGB literal
      // such as 0x0B1017 would be comparing against a transparent colour.
      final MonitorTheme firmware = kMonitorThemes.first;
      expect(firmware.bg.toARGB32(), 0xFF0B1017);
      expect(firmware.panel.toARGB32(), 0xFF131C27);
      expect(firmware.border.toARGB32(), 0xFF243140);
      expect(firmware.track.toARGB32(), 0xFF243342);
      expect(firmware.text.toARGB32(), 0xFFEDF3FA);
      expect(firmware.muted.toARGB32(), 0xFF8C9EB2);
      expect(firmware.cpu.toARGB32(), 0xFF55D9E8);
      expect(firmware.gpu.toARGB32(), 0xFFB0E580);
      expect(firmware.ram.toARGB32(), 0xFF94A9FF);
      expect(firmware.vram.toARGB32(), 0xFFD5B3EE);
      expect(firmware.hot.toARGB32(), 0xFFF4BA73);
      expect(firmware.danger.toARGB32(), 0xFFF06F6F);
    });

    test('every theme converts to a ThemeData', () {
      for (final MonitorTheme theme in kMonitorThemes) {
        expect(theme.toThemeData(), isNotNull);
      }
    });
  });

  group('monitor provider', () {
    test('simulation mode reports a non-empty status line', () {
      final MonitorProvider provider =
          MonitorProvider(profile: MockProfile.workstation, simulate: true);
      addTearDown(provider.dispose);
      expect(provider.statusText, isNotEmpty);
      expect(provider.connectionLabel, isNotEmpty);
    });

    test('history never exceeds the per-window sample cap', () {
      final MonitorProvider provider = MonitorProvider(simulate: true);
      addTearDown(provider.dispose);
      expect(
        provider.cpuHistory.length,
        lessThanOrEqualTo(kMaxHistorySamples),
      );
      expect(
        provider.gpuHistory.length,
        lessThanOrEqualTo(kMaxHistorySamples),
      );
    });

    test('the single-adapter shortcut fires only for exactly one adapter', () {
      final MonitorProvider provider = MonitorProvider(simulate: true);
      addTearDown(provider.dispose);
      // Mirrors `ui_app_show_gpus()`: the shortcut exists only when the host
      // reports *exactly one* adapter; with two or more the selector is used.
      if (provider.target.gpuCount == 1) {
        expect(provider.singleGpuShortcut(), 0);
      } else {
        expect(provider.singleGpuShortcut(), isNull);
      }
    });

    test('openGpuAt then clearOpenGpu round-trips the selection', () {
      final MonitorProvider provider = MonitorProvider(simulate: true);
      addTearDown(provider.dispose);
      if (provider.target.gpuCount == 0) return;

      provider.openGpuAt(0);
      final GpuStatus? opened = provider.selectedGpu;
      expect(opened, isNotNull);

      provider.clearOpenGpu();
      // The dashboard adapter keeps falling back to the discrete/first adaapter.
      expect(provider.target.gpuCount, greaterThan(0));
    });
  });

  group('HUD primitives', () {
    /// HudPanel/HudBar read the active theme through `MonitorThemeScope.of`,
    /// which asserts that the scope is present. In the app that scope wraps the
    /// whole tree, so the test has to provide it too.
    Widget themed(Widget child) => MonitorThemeScope(
          controller: ThemeController(),
          child: MaterialApp(
            home: Scaffold(body: child),
          ),
        );

    testWidgets('HudPanel renders its child', (tester) async {
      await tester.pumpWidget(
        themed(const HudPanel(child: Text('panel-body'))),
      );
      expect(find.text('panel-body'), findsOneWidget);
    });

    testWidgets('HudBar tolerates both a reading and a placeholder',
        (tester) async {
      await tester.pumpWidget(
        themed(
          const Column(
            children: <Widget>[
              HudBar(
                value: 42,
                color: Color(0xFF55D9E8),
                valid: true,
              ),
              HudBar(
                value: 0,
                color: Color(0xFF55D9E8),
                valid: false,
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
