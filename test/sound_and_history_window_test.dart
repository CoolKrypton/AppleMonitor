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
  // The window is a minute of time, not a count of samples
  // -------------------------------------------------------------------------

  group('the window is always one minute, whatever the cadence', () {
    test('1 Hz keeps 61 samples spanning exactly 60 s', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(provider, (Duration d) => now = now.add(d), 90,
          const Duration(seconds: 1));

      // 61 points, not 60: both ends of the minute are inside it, and 61
      // samples a second apart describe exactly 60 s. The number is a
      // consequence of the span now, not the other way round.
      expect(provider.historyPoints, 61);
      expect(provider.cpuHistory.spanMs, 60000);
      expect(provider.cpuHistory.values.last, 50);
      expect(provider.cpuHistory.timesMs.length, 61);
    });

    test('4 Hz keeps the same minute at four times the density', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(provider, (Duration d) => now = now.add(d), 400,
          const Duration(milliseconds: 250));

      expect(provider.historyPoints, 241);
      expect(provider.cpuHistory.spanMs, 60000);
      // Every window ages by the same rule, not by a shared slot count.
      expect(provider.gpuHistory.spanMs, 60000);
      expect(provider.diskReadHistoryFor('disk0').spanMs, 60000);
      expect(provider.diskWriteHistoryFor('disk0').spanMs, 60000);
    });

    test('a slower host keeps 60 s too - it does not shrink the window', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(provider, (Duration d) => now = now.add(d), 200,
          const Duration(milliseconds: 500));

      expect(provider.historyPoints, 31);
      expect(provider.cpuHistory.spanMs, 60000);
    });

    test('jitter in arrival times cannot change the span', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      // +/- 120 ms either side of 1 Hz, which used to swing the derived point
      // count between 56 and 64 and breathe the whole curve with it.
      for (int i = 0; i < 400; i++) {
        provider.pushSnapshot(PcStatus.fromTelemetry(telemetry()));
        now = now.add(Duration(milliseconds: i.isEven ? 880 : 1120));
      }

      expect(provider.cpuHistory.spanMs, lessThanOrEqualTo(60000));
      expect(provider.cpuHistory.spanMs, greaterThanOrEqualTo(59000));
      expect(provider.historyPoints, inInclusiveRange(55, 65));
    });

    test('a coalesced burst no longer halves the window', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      // Two frames per socket read: 1 ms apart, then a 2 s gap. The old
      // estimator skipped the 1 ms interval and read the host as 0.5 Hz, so a
      // minute of history was drawn as thirty points - the curve stretched to
      // twice its width. Two samples per two seconds is still 1 Hz of data.
      for (int i = 0; i < 240; i++) {
        provider.pushSnapshot(PcStatus.fromTelemetry(telemetry()));
        now = now.add(Duration(milliseconds: i.isEven ? 1 : 1999));
      }

      expect(provider.cpuHistory.spanMs, lessThanOrEqualTo(60000));
      expect(provider.cpuHistory.spanMs, greaterThanOrEqualTo(59000));
      expect(provider.historyPoints, greaterThan(55));
    });

    test('host timestamps place samples where the PC took them', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      // The network delivers everything in a burst 2 ms apart; the host says
      // the samples were a second apart. The host wins, because it is the one
      // that knows when the counter was read.
      final int base = start.millisecondsSinceEpoch;
      for (int i = 0; i < 90; i++) {
        provider.pushSnapshot(
          PcStatus.fromTelemetry(telemetry()),
          hostTimeMs: base + i * 1000,
        );
        now = now.add(const Duration(milliseconds: 2));
      }

      expect(provider.cpuHistory.spanMs, 60000);
      expect(provider.historyPoints, 61);
    });

    test('a host clock that disagrees with ours is ignored', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      // Seconds rather than milliseconds: a "timestamp" that cannot be lined
      // up with any wall clock is not a clock we can trust, so the provider
      // falls back to arrival time instead of drawing a 10-minute window.
      final int wrong = start.millisecondsSinceEpoch ~/ 1000;
      for (int i = 0; i < 90; i++) {
        provider.pushSnapshot(
          PcStatus.fromTelemetry(telemetry()),
          hostTimeMs: wrong + i,
        );
        now = now.add(const Duration(seconds: 1));
      }

      expect(provider.historyPoints, 61);
      expect(provider.cpuHistory.spanMs, 60000);
    });

    test('a host clock that jumps backwards does not rewind the plot', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      final int base = start.millisecondsSinceEpoch;
      for (int i = 0; i < 30; i++) {
        provider.pushSnapshot(
          PcStatus.fromTelemetry(telemetry()),
          hostTimeMs: base + i * 1000,
        );
        now = now.add(const Duration(seconds: 1));
      }
      // An NTP correction mid-stream.
      for (int i = 0; i < 30; i++) {
        provider.pushSnapshot(
          PcStatus.fromTelemetry(telemetry()),
          hostTimeMs: base + 30000 - 5000 + i * 1000,
        );
        now = now.add(const Duration(seconds: 1));
      }

      final List<int> times = provider.cpuHistory.timesMs;
      for (int i = 1; i < times.length; i++) {
        expect(
          times[i],
          greaterThanOrEqualTo(times[i - 1]),
          reason: 'timestamps must stay ordered even when the host clock jumps',
        );
      }
      expect(provider.cpuHistory.spanMs, 60000);
    });

    test('reconnecting forgets the timeline', () {
      DateTime now = start;
      final MonitorProvider provider = liveProvider(() => now);
      addTearDown(provider.dispose);

      feed(provider, (Duration d) => now = now.add(d), 90,
          const Duration(seconds: 1));
      expect(provider.cpuHistory.spanMs, 60000);

      provider.useSimulation(true);
      // The simulator seeds one sample; a stale minute must not survive into it.
      expect(provider.cpuHistory.length, 1);

      provider.useSimulation(false);
      expect(provider.cpuHistory.isEmpty, isTrue);

      feed(provider, (Duration d) => now = now.add(d), 8,
          const Duration(seconds: 1));
      expect(provider.historyPoints, 8);
      expect(provider.cpuHistory.spanMs, 7000);
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
