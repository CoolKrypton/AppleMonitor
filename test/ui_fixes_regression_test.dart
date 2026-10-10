import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pcm_monitor/main.dart';
import 'package:pcm_monitor/models/pc_status.dart';
import 'package:pcm_monitor/responsive/responsive.dart';
import 'package:pcm_monitor/screens/cpu_detail_screen.dart';
import 'package:pcm_monitor/screens/dashboard_screen.dart';
import 'package:pcm_monitor/screens/disk_detail_screen.dart';
import 'package:pcm_monitor/screens/gpu_detail_screen.dart';
import 'package:pcm_monitor/services/monitor_provider.dart';
import 'package:pcm_monitor/services/pairing_store.dart';
import 'package:pcm_monitor/theme/monitor_theme.dart';
import 'package:pcm_monitor/widgets/hud.dart';
import 'package:pcm_monitor/widgets/sparkline.dart';
import 'package:pcm_monitor/widgets/theme_picker_sheet.dart';

/// Regression tests for the 2026-10-09 device-verification fix round.
///
/// Each group pins one of the five defects found on the Huawei P10:
///  1. yellow underlines on labels outside Material subtrees;
///  2. collapsed core / engine rows and the missing per-adapter curves;
///  3. the GPU selector grid overflowing short (landscape) viewports;
///  4. the disk grid overflowing the same way;
///  5. the theme sheet rendering as an empty panel.
///
/// The screens are pumped directly (rather than driven through navigation) so
/// each test pins exactly one layout decision against the two phone shapes the
/// defect report covers.
void main() {
  const Size kPhonePortrait = Size(360, 640);
  const Size kPhoneLandscape = Size(640, 360);

  /// A live-shaped snapshot matching what PCMonitorHost actually sends for the
  /// reference machine (i9-9900K, RTX 3060 Ti + iGPU, two disks).
  Map<String, dynamic> liveTelemetry() => <String, dynamic>{
        'cpu': <String, dynamic>{
          'name': 'Intel Core i9-9900K',
          'usagePercent': 21.0,
          'temperatureC': 52.0,
          'powerW': 43.0,
          'frequencyMHz': 4300.0,
          'logicalProcessors': <Map<String, dynamic>>[
            for (int i = 0; i < 8; i++)
              <String, dynamic>{'id': i, 'usagePercent': 10.0 + i},
          ],
        },
        'memory': <String, dynamic>{
          'totalBytes': 34359738368,
          'usedBytes': 17179869184,
          'usagePercent': 50.0,
        },
        'gpus': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'gpu-luid-10de',
            'name': 'NVIDIA GeForce RTX 3060 Ti',
            'vendor': 'NVIDIA',
            'isDiscrete': true,
            'usagePercent': 12.0,
            'temperatureC': 54.0,
            'powerW': 25.0,
            'vram': <String, dynamic>{
              'totalBytes': 8589934592,
              'usedBytes': 2576980378,
              'usagePercent': 30.0,
            },
            'engines': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'phys0-eng0',
                'name': '3D',
                'usagePercent': 12.0,
              },
              <String, dynamic>{
                'id': 'phys0-eng1',
                'name': 'Copy',
                'usagePercent': 3.0,
              },
            ],
          },
          <String, dynamic>{
            'id': 'gpu-luid-8086',
            'name': 'Intel UHD Graphics 630',
            'vendor': 'Intel',
            'isDiscrete': false,
            'usagePercent': 2.0,
            'temperatureC': 45.0,
            'powerW': 3.0,
            'vram': <String, dynamic>{
              'totalBytes': 0,
              'usedBytes': 0,
              'usagePercent': 0.0,
            },
            'engines': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'phys1-eng0',
                'name': '3D',
                'usagePercent': 2.0,
              },
            ],
          },
        ],
        'network': <String, dynamic>{
          'downloadBytesPerSecond': 1500.0,
          'uploadBytesPerSecond': 300.0,
        },
        'storage': <String, dynamic>{
          'totalReadBytesPerSecond': 100.0,
          'totalWriteBytesPerSecond': 50.0,
          'disks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'disk0',
              'name': 'Samsung SSD 970 EVO Plus',
              'readBytesPerSecond': 80.0,
              'writeBytesPerSecond': 40.0,
              'activityPercent': 3.0,
              'temperatureC': 41.0,
            },
            <String, dynamic>{
              'id': 'disk1',
              'name': 'WDC WD10EZEX',
              'readBytesPerSecond': 20.0,
              'writeBytesPerSecond': 10.0,
              'activityPercent': 1.0,
              'temperatureC': 38.0,
            },
          ],
        },
      };

  PcStatus liveStatus() => PcStatus.fromTelemetry(liveTelemetry());

  MonitorProvider liveProvider() {
    final MonitorProvider provider = MonitorProvider(
      simulate: false,
      persistSelection: false,
    );
    for (int i = 0; i < 12; i++) {
      provider.pushSnapshot(liveStatus());
    }
    return provider;
  }

  Widget harness(Widget child, {ThemeController? controller}) {
    return MonitorThemeScope(
      controller: controller ?? ThemeController(),
      child: MaterialApp(
        // The screens are pumped directly rather than through navigation, so
        // nothing here supplies the `Material` ancestor that a Scaffold would
        // in the real app. Widgets such as InkWell assert on its absence, so
        // one transparent Material restores that ancestor without changing
        // layout, colour or the number of rendered texts.
        home: Material(
          type: MaterialType.transparency,
          child: ResponsiveBuilder(
            builder: (BuildContext context, LayoutMetrics metrics) => child,
          ),
        ),
      ),
    );
  }

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('fix 1 - no platform text decoration anywhere', () {
    test('every text role in every theme carries decoration: none', () {
      for (final MonitorTheme theme in kMonitorThemes) {
        final TextTheme roles = theme.toThemeData().textTheme;
        final List<TextStyle?> styles = <TextStyle?>[
          roles.displayLarge,
          roles.displayMedium,
          roles.displaySmall,
          roles.headlineLarge,
          roles.headlineMedium,
          roles.headlineSmall,
          roles.titleLarge,
          roles.titleMedium,
          roles.titleSmall,
          roles.bodyLarge,
          roles.bodyMedium,
          roles.bodySmall,
          roles.labelLarge,
          roles.labelMedium,
          roles.labelSmall,
        ];
        for (final TextStyle? style in styles) {
          expect(
            style?.decoration,
            TextDecoration.none,
            reason: '${theme.id} leaves a text role without an explicit '
                'decoration, so EMUI can paint its yellow underline.',
          );
        }
      }
    });
  });

  group('fix 2a - per-adapter history feeds the device list', () {
    test('pushSnapshot fills a window for every protocol id', () {
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      final List<double?> discrete = provider.gpuHistoryFor('gpu-luid-10de');
      final List<double?> integrated = provider.gpuHistoryFor('gpu-luid-8086');

      // The window is pre-seeded with gaps and samples shift in from the end.
      expect(discrete.length, kDashboardHistoryPoints);
      expect(integrated.length, kDashboardHistoryPoints);
      expect(discrete.whereType<double>().length, 12);
      expect(integrated.whereType<double>().length, 12);

      // The newest sample is the adapter's busiest-engine reading.
      expect(discrete.last, 12.0);
    });

    test('an adapter without engine data falls back to the adapter reading',
        () {
      final MonitorProvider provider = MonitorProvider(
        simulate: false,
        persistSelection: false,
      );
      addTearDown(provider.dispose);

      final PcStatus bare = PcStatus.fromTelemetry(<String, dynamic>{
        'gpus': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'gpu-x', 'name': 'Bare', 'usagePercent': 7.0},
        ],
      });
      provider.pushSnapshot(bare);

      expect(provider.gpuHistoryFor('gpu-x').last, 7.0);
    });
  });

  group('fix 2b - gpu selector cards show their curve and fit the screen', () {
    for (final MapEntry<String, Size> shape in <String, Size>{
      'portrait': kPhonePortrait,
      'landscape': kPhoneLandscape,
    }.entries) {
      testWidgets('two adapters render at ${shape.key} - no overflow',
          (tester) async {
        useViewport(tester, shape.value);
        final MonitorProvider provider = liveProvider();
        addTearDown(provider.dispose);

        await tester.pumpWidget(harness(
          GpuSelectorScreen(
            provider: provider,
            onHome: () {},
            onChoose: (_) {},
          ),
        ));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(Sparkline), findsNWidgets(2));

        // The curve owns the dead band under the header row - it must be
        // tall enough to actually read as a waveform, not a collapsed sliver.
        final List<Element> sparks = find.byType(Sparkline).evaluate().toList();
        for (final Element element in sparks) {
          final RenderBox box = element.renderObject! as RenderBox;
          expect(
            box.size.height,
            greaterThan(24),
            reason: 'a ${shape.value} viewport left a sparkline at '
                '${box.size}, which reads as "no waveform at all".',
          );
        }
      });
    }
  });

  group('fix 2c - cpu detail core rows have a real extent', () {
    for (final MapEntry<String, Size> shape in <String, Size>{
      'portrait': kPhonePortrait,
      'landscape': kPhoneLandscape,
    }.entries) {
      testWidgets('eight cores render at ${shape.key} - no overflow',
          (tester) async {
        useViewport(tester, shape.value);
        final MonitorProvider provider = liveProvider();
        addTearDown(provider.dispose);

        await tester.pumpWidget(harness(
          CpuDetailScreen(provider: provider, onHome: () {}),
        ));
        await tester.pump();

        expect(tester.takeException(), isNull);
        // One bar per core row, plus the package block's own bar. Before the
        // fix the stretch rows collapsed to zero and none of them painted.
        // The plain finder (not hitTestable) is deliberate: ListView builds
        // rows lazily, so rows beyond the viewport must still be counted.
        expect(find.byType(HudBar).evaluate().length, greaterThanOrEqualTo(8));
        expect(find.text('8 TOTAL'), findsOneWidget);
      });
    }
  });

  group('fix 3 - disk detail cards fit the viewport', () {
    for (final MapEntry<String, Size> shape in <String, Size>{
      'portrait': kPhonePortrait,
      'landscape': kPhoneLandscape,
    }.entries) {
      testWidgets('two disks render at ${shape.key} - no overflow',
          (tester) async {
        useViewport(tester, shape.value);
        final MonitorProvider provider = liveProvider();
        addTearDown(provider.dispose);

        await tester.pumpWidget(harness(
          DiskDetailScreen(provider: provider, onHome: () {}),
        ));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(HudBar).evaluate().length, greaterThanOrEqualTo(2));
      });
    }
  });

  group('fix 10 - landscape disk grid keeps every card short', () {
    /// The reference machine really reports four physical disks (SATA SSD,
    /// WD HDD, NVMe, USB bridge). The grid used to force every card to a
    /// 140 pt floor, which pushed the second row past the bottom edge on a
    /// landscape phone and turned the page into a scroller.
    PcStatus fourDiskStatus() {
      final Map<String, dynamic> telemetry = liveTelemetry();
      final Map<String, dynamic> storage =
          Map<String, dynamic>.from(telemetry['storage'] as Map);
      storage['disks'] = <Map<String, dynamic>>[
        ...(storage['disks'] as List<dynamic>).cast<Map<String, dynamic>>(),
        <String, dynamic>{
          'id': 'disk2',
          'name': 'ZHITAI SC001 Active 512GB',
          'readBytesPerSecond': 12.0,
          'writeBytesPerSecond': 6.0,
          'activityPercent': 2.0,
          'temperatureC': 40.0,
        },
        // No temperature - the shape the RTL9210 bridge actually reports.
        <String, dynamic>{
          'id': 'disk3',
          'name': 'RTL9210 NVMe Bridge',
          'readBytesPerSecond': 4.0,
          'writeBytesPerSecond': 2.0,
          'activityPercent': 0.0,
        },
      ];
      telemetry['storage'] = storage;
      return PcStatus.fromTelemetry(telemetry);
    }

    for (final MapEntry<String, Size> shape in <String, Size>{
      'portrait': kPhonePortrait,
      'landscape': kPhoneLandscape,
    }.entries) {
      testWidgets('four disks render at ${shape.key} - no scrolling',
          (tester) async {
        useViewport(tester, shape.value);
        final MonitorProvider provider = MonitorProvider(
          simulate: false,
          persistSelection: false,
        );
        for (int i = 0; i < 12; i++) {
          provider.pushSnapshot(fourDiskStatus());
        }
        addTearDown(provider.dispose);

        await tester.pumpWidget(harness(
          DiskDetailScreen(provider: provider, onHome: () {}),
        ));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(HudBar).evaluate().length, greaterThanOrEqualTo(4));

        // Every panel - the header strip and the four cards - has to stay
        // under the old fixed floor, otherwise the grid grows taller than the
        // viewport again.
        for (final Element panel in find.byType(HudPanel).evaluate()) {
          final RenderBox box = panel.renderObject! as RenderBox;
          expect(
            box.size.height,
            lessThanOrEqualTo(140.0),
            reason: 'a ${shape.key} panel grew to ${box.size.height}',
          );
        }

        // And the grid must not need a scroll at all.
        final List<ScrollableState> scrollables =
            tester.stateList<ScrollableState>(find.byType(Scrollable)).toList();
        expect(scrollables, isNotEmpty);
        for (final ScrollableState scrollable in scrollables) {
          expect(
            scrollable.position.maxScrollExtent,
            lessThanOrEqualTo(0.5),
            reason: 'the ${shape.key} disk grid still overflows by '
                '${scrollable.position.maxScrollExtent} px',
          );
        }
      });
    }
  });

  group('fix 11 - the chosen skin survives a restart', () {
    test('a stored id maps back to the theme it names', () {
      for (final MonitorTheme theme in kMonitorThemes) {
        expect(themeForId(theme.id).id, theme.id);
      }
      // A missing or stale id must fall back to the default, not crash: a
      // theme removed between releases must not brick the startup path.
      expect(themeForId(null).id, cryoBlue.id);
      expect(themeForId('no_such_theme').id, cryoBlue.id);
    });

    testWidgets('the app opens on the stored skin, not the default',
        (tester) async {
      final MemoryStore store = MemoryStore(<String, String>{
        kThemePreferenceKey: 'daylight',
      });

      await tester.pumpWidget(PcMonitorApp(
        store: store,
        initialThemeId: await store.read(kThemePreferenceKey),
      ));

      final MonitorThemeScope scope =
          tester.widget<MonitorThemeScope>(find.byType(MonitorThemeScope));
      expect(scope.notifier?.themeId, 'daylight');
    });

    testWidgets('picking a skin writes it through to storage', (tester) async {
      final MemoryStore store = MemoryStore();

      await tester.pumpWidget(PcMonitorApp(store: store));
      final MonitorThemeScope scope =
          tester.widget<MonitorThemeScope>(find.byType(MonitorThemeScope));
      expect(scope.notifier?.themeId, cryoBlue.id);

      scope.notifier!.select(matrixGreen);
      await tester.pump();

      expect(await store.read(kThemePreferenceKey), matrixGreen.id);
    });
  });

  group('fix 4 - the theme sheet lists every theme', () {
    testWidgets('all six themes render as selectable tiles', (tester) async {
      useViewport(tester, kPhonePortrait);
      final ThemeController controller = ThemeController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(harness(
        const Scaffold(body: ThemePickerSheet()),
        controller: controller,
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      for (final MonitorTheme theme in kMonitorThemes) {
        expect(
          find.text(theme.name),
          findsOneWidget,
          reason: '${theme.name} is missing from the sheet - the modal '
              'context cannot reach the layout scope.',
        );
      }
    });

    testWidgets('selecting a tile updates the controller', (tester) async {
      useViewport(tester, kPhonePortrait);
      final ThemeController controller = ThemeController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(harness(
        const Scaffold(body: ThemePickerSheet()),
        controller: controller,
      ));
      await tester.pump();

      final MonitorTheme next =
          kMonitorThemes.firstWhere((MonitorTheme t) => t.id != controller.themeId);
      await tester.tap(find.text(next.name));
      await tester.pump();

      expect(controller.themeId, next.id);
    });
  });

  group('fix 6 - landscape clock card shows the year alone', () {
    final String year = DateTime.now().year.toString();

    // The dashboard status bar owns the full "YYYY / MM / DD  WEEKDAY" line
    // (it spans the viewport); the clock card is the narrow tile that
    // ellipsises in landscape.
    testWidgets('portrait keeps the full date line', (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(DashboardScreen(
        provider: provider,
        onOpenCpu: () {},
        onOpenGpus: () {},
        onOpenDisks: () {},
        onOpenHosts: () {},
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // No bare-year text anywhere, full dates present (status bar + card).
      expect(find.text(year), findsNothing);
      expect(
        find.textContaining(RegExp(r'\d{4} / \d{2} / \d{2}')),
        findsNWidgets(2),
      );
    });

    testWidgets('landscape collapses the date to the year', (tester) async {
      useViewport(tester, kPhoneLandscape);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(DashboardScreen(
        provider: provider,
        onOpenCpu: () {},
        onOpenGpus: () {},
        onOpenDisks: () {},
        onOpenHosts: () {},
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Exactly one bare-year text (the clock card); the full date survives
      // only in the status bar.
      expect(find.text(year), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'\d{4} / \d{2} / \d{2}')),
        findsOneWidget,
      );
    });
  });

  group('fix 7 - every gpu card shows the same ruled background', () {
    testWidgets('an empty sparkline still paints its three grid lines',
        (tester) async {
      useViewport(tester, kPhonePortrait);
      await tester.pumpWidget(harness(
        const Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 60,
              child: Sparkline(
                points: <double?>[],
                color: Color(0xFF55D9E8),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Rasterise the painter and count the full-width horizontal strokes.
      // Before the fix `paint` returned before drawing the grid whenever the
      // window held no samples, so cards without a curve lost the ruler and
      // the device list read as a patchwork of different backgrounds.
      final Element element = find.byType(Sparkline).evaluate().first;
      final RenderCustomPaint render =
          element.renderObject! as RenderCustomPaint;
      final Size size = render.size;

      late final List<int> gridRows;
      await tester.runAsync(() async {
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        render.painter!.paint(Canvas(recorder), size);
        final ui.Image image = await recorder
            .endRecording()
            .toImage(size.width.round(), size.height.round());
        final ByteData? bytes =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        final Uint8List pixels = bytes!.buffer.asUint8List();
        final int w = size.width.round();
        final int h = size.height.round();

        gridRows = <int>[];
        for (int y = 0; y < h; y++) {
          int covered = 0;
          for (int x = 0; x < w; x++) {
            if (pixels[(y * w + x) * 4 + 3] > 10) covered++;
          }
          if (covered > w * 0.9) gridRows.add(y);
        }
      });

      int lines = 0;
      for (int i = 0; i < gridRows.length; i++) {
        if (i == 0 || gridRows[i] != gridRows[i - 1] + 1) lines++;
      }
      expect(
        lines,
        3,
        reason: 'the ruler must draw at 1/4, 2/4 and 3/4 heights even when '
            'the series has no samples yet',
      );
    });

    testWidgets('both adapters own a window from the first snapshot',
        (tester) async {
      final MonitorProvider provider = MonitorProvider(
        simulate: false,
        persistSelection: false,
      );
      addTearDown(provider.dispose);
      provider.pushSnapshot(liveStatus());

      // Before the growable-list fix the first adapter's window stayed all
      // null and the second adapter never got a window at all (the add threw
      // and aborted the loop) - which is exactly the "inconsistent
      // backgrounds, no waveform" report from the device.
      expect(provider.gpuHistoryFor('gpu-luid-10de').length,
          kDashboardHistoryPoints);
      expect(provider.gpuHistoryFor('gpu-luid-8086').length,
          kDashboardHistoryPoints);
      expect(provider.gpuHistoryFor('gpu-luid-8086').last, 2.0);
    });
  });

  group('fix 8 - landscape detail summaries collapse to two rows', () {
    testWidgets('cpu summary lines every parameter up on one row',
        (tester) async {
      useViewport(tester, kPhoneLandscape);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(
        CpuDetailScreen(provider: provider, onHome: () {}),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      double? rowY;
      for (final String label in const <String>[
        'TOTAL LOAD',
        'TEMPERATURE',
        'POWER',
        'FREQUENCY',
        'THREADS',
      ]) {
        final double y = tester.getRect(find.text(label)).center.dy;
        if (rowY == null) {
          rowY = y;
        } else {
          expect(
            (y - rowY).abs(),
            lessThan(2.0),
            reason: '$label wrapped onto a second row - the landscape '
                'summary must keep all parameters on one line.',
          );
        }
      }
    });

    testWidgets('gpu summary lines every parameter up and drops the MAX row',
        (tester) async {
      useViewport(tester, kPhoneLandscape);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);
      provider.openGpuAt(0);

      await tester.pumpWidget(harness(
        GpuDetailScreen(
          provider: provider,
          onHome: () {},
          onBackToDevices: () {},
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      double? rowY;
      for (final String label in const <String>[
        'GPU LOAD',
        'TEMPERATURE',
        'POWER',
        'VRAM USAGE',
        'VRAM',
      ]) {
        final double y = tester.getRect(find.text(label)).center.dy;
        if (rowY == null) {
          rowY = y;
        } else {
          expect(
            (y - rowY).abs(),
            lessThan(2.0),
            reason: '$label wrapped onto a second row - the landscape '
                'summary must keep all parameters on one line.',
          );
        }
      }
      // Two rows total: parameters + bar. The busiest-engine caption is gone
      // everywhere now that the panel reads the adapter total.
      expect(find.textContaining('MAX /'), findsNothing);
      expect(find.textContaining('PEAK'), findsNothing);
    });
  });

  group('fix 9 - gpu pages read the adapter total, not the busiest engine', () {
    /// 90% adapter load against a 12% busiest engine: the two rules give
    /// different numbers, so an assertion on 90 pins the rule that is in use.
    PcStatus splitStatus() => PcStatus.fromTelemetry(<String, dynamic>{
          'gpus': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'gpu-split',
              'name': 'Split Adapter',
              'vendor': 'Acme',
              'isDiscrete': true,
              'usagePercent': 90.0,
              'temperatureC': 60.0,
              'powerW': 100.0,
              'engines': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'e0',
                  'name': '3D',
                  'usagePercent': 12.0,
                },
                <String, dynamic>{
                  'id': 'e1',
                  'name': 'Copy',
                  'usagePercent': 4.0,
                },
              ],
            },
          ],
        });

    MonitorProvider splitProvider() {
      final MonitorProvider provider = MonitorProvider(
        simulate: false,
        persistSelection: false,
      );
      for (int i = 0; i < 4; i++) {
        provider.pushSnapshot(splitStatus());
      }
      return provider;
    }

    test('the device-list window records the adapter total', () {
      final MonitorProvider provider = splitProvider();
      addTearDown(provider.dispose);

      expect(provider.gpuHistoryFor('gpu-split').last, 90.0);
    });

    testWidgets('the device card headline and caption use the total',
        (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = splitProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(
        GpuSelectorScreen(
          provider: provider,
          onHome: () {},
          onChoose: (_) {},
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(find.textContaining('90%'), findsOneWidget);
      expect(find.textContaining('12%'), findsNothing);
      // The old caption named the busiest engine; it must be gone.
      expect(find.textContaining('PEAK'), findsNothing);
      expect(find.text('TOTAL LOAD'), findsOneWidget);
    });

    testWidgets('the detail summary headline uses the total', (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = splitProvider();
      addTearDown(provider.dispose);
      provider.openGpuAt(0);

      await tester.pumpWidget(harness(
        GpuDetailScreen(
          provider: provider,
          onHome: () {},
          onBackToDevices: () {},
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // The summary tile reads 90%; the engine rows below still show their own
      // 12% and 4%, which is exactly the split the two rules produce.
      expect(find.text('90%'), findsOneWidget);
      expect(find.text('12%'), findsOneWidget);
      expect(find.text('4%'), findsOneWidget);
      expect(find.textContaining('MAX /'), findsNothing);
    });
  });

  group('fix 12 - bars ease in the framework, not in app code', () {
    test('there is no second smoothed snapshot behind display', () {
      final MonitorProvider provider = MonitorProvider(
        simulate: false,
        persistSelection: false,
      );
      addTearDown(provider.dispose);

      // Bars ease with TweenAnimationBuilder in the widget layer, so the
      // provider keeps exactly one snapshot: the newest one off the wire.
      final PcStatus status = PcStatus.fromTelemetry(liveTelemetry());
      provider.pushSnapshot(status);
      expect(identical(provider.display, provider.target), isTrue);
      expect(identical(provider.display, status), isTrue);
    });

    testWidgets('HudBar glides between values instead of jumping',
        (tester) async {
      useViewport(tester, kPhonePortrait);

      double value = 10;
      late StateSetter setTarget;
      await tester.pumpWidget(
        harness(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setTarget = setState;
              return HudBar(value: value, color: cryoBlue.cpu);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Measure the painted fill (DecoratedBox), not the FractionallySizedBox
      // itself: the former collapsed to 0x0 once a bare DecoratedBox replaced
      // an expanding Container - invisible bars with a perfectly sized parent.
      final Finder fill = find.descendant(
        of: find.byType(FractionallySizedBox),
        matching: find.byType(DecoratedBox),
      );
      double fillWidth() => tester.getSize(fill).width;

      // First build renders straight at the current value (10% of 360).
      final double startWidth = fillWidth();
      expect(startWidth, closeTo(36.0, 2.0));

      // A new snapshot lands: 100 ms later the fill must still be in flight
      // (strictly between start and target) - proof the tween is animating.
      setTarget(() => value = 100);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final double midFlight = fillWidth();
      expect(midFlight, greaterThan(startWidth));
      expect(midFlight, lessThan(360.0));

      // And it settles exactly at the target.
      await tester.pumpAndSettle();
      expect(fillWidth(), closeTo(360.0, 2.0));
    });
  });
}
