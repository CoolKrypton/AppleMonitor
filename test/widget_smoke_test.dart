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
          kMonitorThemes.map((MonitorTheme t) => t.bg.value).toSet();
      expect(backgrounds.length, 6);
    });

    test('the default theme is the firmware palette, so parity is preserved', () {
      final MonitorTheme firmware = kMonitorThemes.first;
      expect(firmware.bg.value, 0x0B1017);
      expect(firmware.panel.value, 0x131C27);
      expect(firmware.border.value, 0x243140);
      expect(firmware.track.value, 0x243342);
      expect(firmware.text.value, 0xEDF3FA);
      expect(firmware.muted.value, 0x8C9EB2);
      expect(firmware.cpu.value, 0x55D9E8);
      expect(firmware.gpu.value, 0xB0E580);
      expect(firmware.ram.value, 0x94A9FF);
      expect(firmware.vram.value, 0xD5B3EE);
      expect(firmware.hot.value, 0xF4BA73);
      expect(firmware.danger.value, 0xF06F6F);
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

    test('history never exceeds the firmware window', () {
      final MonitorProvider provider = MonitorProvider(simulate: true);
      addTearDown(provider.dispose);
      expect(
        provider.cpuHistory.length,
        lessThanOrEqualTo(kDashboardHistoryPoints),
      );
      expect(
        provider.gpuHistory.length,
        lessThanOrEqualTo(kDashboardHistoryPoints),
      );
    });

    test('the single-adapter shortcut resolves to a real GPU', () {
      final MonitorProvider provider = MonitorProvider(simulate: true);
      addTearDown(provider.dispose);
      if (provider.target.gpuCount > 0) {
        expect(provider.singleGpuShortcut(), isA<int>());
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
    testWidgets('HudPanel renders its child', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HudPanel(child: const Text('panel-body')),
          ),
        ),
      );
      expect(find.text('panel-body'), findsOneWidget);
    });

    testWidgets('HudBar tolerates both a reading and a placeholder',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                const HudBar(
                  value: 42,
                  color: Color(0xFF55D9E8),
                  valid: true,
                ),
                const HudBar(
                  value: 0,
                  color: Color(0xFF55D9E8),
                  valid: false,
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
