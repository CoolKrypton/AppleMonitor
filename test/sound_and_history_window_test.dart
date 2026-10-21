import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pcm_monitor/models/pc_status.dart';
import 'package:pcm_monitor/responsive/responsive.dart';
import 'package:pcm_monitor/screens/dashboard_screen.dart';
import 'package:pcm_monitor/services/monitor_provider.dart';
import 'package:pcm_monitor/services/pairing_store.dart';
import 'package:pcm_monitor/services/tap_sound.dart';
import 'package:pcm_monitor/theme/monitor_theme.dart';
import 'package:pcm_monitor/widgets/settings_sheet.dart';
import 'package:pcm_monitor/widgets/sparkline.dart';
import 'package:pcm_monitor/widgets/tap_sound_listener.dart';

/// Regression tests for the 2026-10-21 round:
///
/// * every plot covers 60 s of wall clock, whatever cadence the host sends at;
/// * the dashboard no longer spends a gutter on a "60s" caption;
/// * the tap effect is switchable from the settings sheet, and the listener
///   that plays it tells taps from scrolls.
void main() {
  const Size kPhonePortrait = Size(411, 891);

  Map<String, dynamic> telemetry({double cpu = 50.0}) => <String, dynamic>{
        'cpu': <String, dynamic>{
          'name': 'Intel Core i9-9900K',
          'usagePercent': cpu,
          'temperatureC': 52.0,
          'powerW': 43.0,
          'frequencyMHz': 4300.0,
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
            'usagePercent': 30.0,
          },
        ],
        'storage': <String, dynamic>{
          'disks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'disk0',
              'name': 'Drive 0',
              'readBytesPerSecond': 80000000.0,
              'writeBytesPerSecond': 40000000.0,
              'activityPercent': 3.0,
            },
          ],
        },
      };

  /// A clock the test advances by hand, so a 60 s window can be measured
  /// without spending 60 s.
  final DateTime start = DateTime(2026, 10, 21, 9);

  MonitorProvider liveProvider(DateTime Function() clock) => MonitorProvider(
        simulate: false,
        persistSelection: false,
        clock: clock,
      );

  /// Pushes [count] snapshots [interval] apart.
  void feed(
    MonitorProvider provider,
    void Function(Duration) advance,
    int count,
    Duration interval, {
    double cpu = 50.0,
  }) {
    for (int i = 0; i < count; i++) {
      provider.pushSnapshot(PcStatus.fromTelemetry(telemetry(cpu: cpu)));
      advance(interval);
    }
  }

  // -------------------------------------------------------------------------
  // The window is a duration, not a point count
  // -------------------------------------------------------------------------

  group('the 60 s window follows the host cadence', () {
    test('1 Hz keeps 60 points - the firmware window', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(provider, (Duration d) => now = now.add(d), 10, const Duration(seconds: 1));

      expect(provider.sampleIntervalMs, 1000);
      expect(provider.historyPoints, kDashboardHistoryPoints);
      expect(provider.cpuHistory.length, 60);
    });

    test('4 Hz keeps 240 points: the same 60 s, four times the resolution', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(
        provider,
        (Duration d) => now = now.add(d),
        120,
        const Duration(milliseconds: 250),
      );

      expect(provider.sampleIntervalMs, 250);
      expect(provider.historyPoints, 240);
      expect(provider.cpuHistory.length, 240);
      // 120 samples cannot fill 240 slots; the missing half is padding.
      expect(
        provider.cpuHistory.where((double? v) => v == null).length,
        greaterThan(0),
        reason: 'growth must pad with gaps, not with invented samples',
      );
      expect(provider.cpuHistory.last, 50);
      // Every other window follows the same number.
      expect(provider.gpuHistory.length, 240);
      expect(provider.diskReadHistoryFor('disk0').length, 240);
      expect(provider.diskWriteHistoryFor('disk0').length, 240);
    });

    test('a slower host shrinks the window instead of stretching it', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(
        provider,
        (Duration d) => now = now.add(d),
        40,
        const Duration(milliseconds: 500),
      );
      expect(provider.historyPoints, 120);

      feed(provider, (Duration d) => now = now.add(d), 20, const Duration(seconds: 2));
      expect(provider.sampleIntervalMs, 2000);
      expect(provider.historyPoints, 30);
      expect(provider.cpuHistory.length, 30);
    });

    test('a host slower than the floor still gets a full minute', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(provider, (Duration d) => now = now.add(d), 12, const Duration(seconds: 10));

      // 60000 / 10000 = 6 points, below the floor: twelve slots of five
      // seconds each is the shortest honest plot.
      expect(provider.historyPoints, kMinHistoryPoints);
    });

    test('two pushes inside one frame are not a cadence', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(provider, (Duration d) => now = now.add(d), 10, const Duration(seconds: 1));
      provider.pushSnapshot(PcStatus.fromTelemetry(telemetry()));
      now = now.add(const Duration(milliseconds: 3));
      provider.pushSnapshot(PcStatus.fromTelemetry(telemetry()));

      expect(provider.historyPoints, kDashboardHistoryPoints);
      expect(provider.sampleIntervalMs, 1000);
    });

    test('jitter around 1 Hz does not re-fit the window', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      for (int i = 0; i < 30; i++) {
        provider.pushSnapshot(PcStatus.fromTelemetry(telemetry()));
        now = now.add(Duration(milliseconds: i.isEven ? 950 : 1050));
      }

      // A trimmed mean averages the jitter away; a median would snap to one
      // side and move the point count with it.
      expect(provider.historyPoints, 60);
      expect(provider.cpuHistory.length, 60);
      expect(provider.sampleIntervalMs, closeTo(1000, 20));
    });

    test('reconnecting resets the measured cadence', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(
        provider,
        (Duration d) => now = now.add(d),
        40,
        const Duration(milliseconds: 250),
      );
      expect(provider.historyPoints, 240);

      provider.useSimulation(true);
      expect(provider.historyPoints, kDashboardHistoryPoints);

      provider.useSimulation(false);
      feed(provider, (Duration d) => now = now.add(d), 8, const Duration(seconds: 1));
      expect(provider.historyPoints, 60);
    });
  });

  // -------------------------------------------------------------------------
  // No caption gutter on the dashboard plot
  // -------------------------------------------------------------------------

  group('the dashboard plot is not labelled', () {
    Widget harness(Widget Function() build) => MonitorThemeScope(
          controller: ThemeController(),
          child: MaterialApp(
            home: ResponsiveBuilder(
              builder: (BuildContext context, LayoutMetrics metrics) => build(),
            ),
          ),
        );

    void useViewport(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Widget dashboard(MonitorProvider provider) => DashboardScreen(
          provider: provider,
          onOpenCpu: () {},
          onOpenGpus: () {},
          onOpenDisks: () {},
          onOpenHosts: () {},
        );

    testWidgets('portrait: no "60s" gutter, the curve keeps the width',
        (tester) async {
      useViewport(tester, kPhonePortrait);
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);
      feed(provider, (Duration d) => now = now.add(d), 20, const Duration(seconds: 1));

      await tester.pumpWidget(harness(() => dashboard(provider)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('60s'), findsNothing);
      expect(find.byType(Sparkline), findsNWidgets(2));

      // The plot now starts at the card's content edge: nothing is reserved to
      // its left beyond the panel's own padding.
      final Rect plot = tester.getRect(find.byType(Sparkline).first);
      final Rect card = tester.getRect(find.byType(ProcessorCard).first);
      expect(plot.left - card.left, lessThan(20));
      expect(plot.width, greaterThan(card.width - 40));
    });

    testWidgets('landscape: same, on the grid cards', (tester) async {
      useViewport(tester, const Size(891, 411));
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);
      feed(provider, (Duration d) => now = now.add(d), 20, const Duration(seconds: 1));

      await tester.pumpWidget(harness(() => dashboard(provider)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('60s'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Settings sheet + tap effect
  // -------------------------------------------------------------------------

  group('tap sounds', () {
    test('default on, and the choice survives a reload', () async {
      final MemoryStore store = MemoryStore();
      final TapSoundController first = TapSoundController(store: store);
      await first.load();
      expect(first.enabled, isTrue);

      first.setEnabled(false);
      expect(first.enabled, isFalse);
      // The write is not awaited by setEnabled; let it land.
      await Future<void>.delayed(Duration.zero);
      expect(await store.read(kTapSoundPreferenceKey), '0');

      final TapSoundController second = TapSoundController(store: store);
      await second.load();
      expect(second.enabled, isFalse);

      first.dispose();
      second.dispose();
    });

    test('a controller with no store still reports the default', () async {
      final TapSoundController controller = TapSoundController();
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.enabled, isTrue);
      // No audio plugin under `flutter test`: priming fails quietly.
      expect(controller.isPrimed, isFalse);
      // ... and playing is a no-op rather than a throw.
      controller.play();
      expect(controller.playRequests, 1);
    });

    testWidgets('the settings sheet toggles it and writes the preference',
        (tester) async {
      tester.view.physicalSize = kPhonePortrait;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final MemoryStore store = MemoryStore();
      final TapSoundController sounds = TapSoundController(store: store);
      final ThemeController themes = ThemeController();
      addTearDown(sounds.dispose);
      addTearDown(themes.dispose);

      await tester.pumpWidget(
        TapSoundScope(
          controller: sounds,
          child: MonitorThemeScope(
            controller: themes,
            child: MaterialApp(
              home: ResponsiveBuilder(
                builder: (BuildContext context, LayoutMetrics metrics) =>
                    const Scaffold(body: SettingsSheet()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Tap sounds'), findsOneWidget);
      expect(find.text('A soft bubble under every tap'), findsOneWidget);

      await tester.tap(find.text('Tap sounds'));
      await tester.pump();

      expect(sounds.enabled, isFalse);
      expect(find.text('Silent interface'), findsOneWidget);
      expect(await store.read(kTapSoundPreferenceKey), '0');

      // The themes are still in the same sheet - it is one settings surface.
      for (final MonitorTheme theme in kMonitorThemes) {
        expect(find.text(theme.name), findsOneWidget);
      }
    });

    testWidgets('a tap asks for the effect; a scroll does not', (tester) async {
      const Key target = Key('tap-target');
      final TapSoundController sounds = TapSoundController();
      addTearDown(sounds.dispose);

      await tester.pumpWidget(
        TapSoundScope(
          controller: sounds,
          child: MaterialApp(
            home: TapSoundListener(
              child: Center(
                child: GestureDetector(
                  onTap: () {},
                  child: const SizedBox(
                    key: target,
                    width: 200,
                    height: 200,
                    child: ColoredBox(color: Color(0xFF223344)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(target));
      expect(sounds.playRequests, 1);

      await tester.drag(find.byKey(target), const Offset(0, -60));
      await tester.pump();
      expect(
        sounds.playRequests,
        1,
        reason: 'a drag past the slop is a scroll, not a tap',
      );

      await tester.tap(find.byKey(target));
      expect(sounds.playRequests, 2);
    });

    testWidgets('a long press is not a tap', (tester) async {
      const Key target = Key('tap-target');
      final TapSoundController sounds = TapSoundController();
      addTearDown(sounds.dispose);

      await tester.pumpWidget(
        TapSoundScope(
          controller: sounds,
          child: MaterialApp(
            home: TapSoundListener(
              child: Center(
                child: GestureDetector(
                  onLongPress: () {},
                  child: const SizedBox(
                    key: target,
                    width: 200,
                    height: 200,
                    child: ColoredBox(color: Color(0xFF223344)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(target)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      // The timestamp is what the listener measures, and the test clock only
      // advances it if it is passed explicitly.
      await gesture.up(timeStamp: const Duration(milliseconds: 600));
      await tester.pump();

      expect(sounds.playRequests, 0);
    });
  });
}
