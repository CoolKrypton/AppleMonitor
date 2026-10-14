import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pcm_monitor/models/pc_status.dart';
import 'package:pcm_monitor/responsive/responsive.dart';
import 'package:pcm_monitor/screens/dashboard_screen.dart';
import 'package:pcm_monitor/screens/disk_detail_screen.dart';
import 'package:pcm_monitor/services/monitor_provider.dart';
import 'package:pcm_monitor/theme/monitor_theme.dart';
import 'package:pcm_monitor/widgets/sparkline.dart';

/// Regression tests for the 2026-10-14 feature round:
///
/// * the CPU card carries the processor's live clock, in both layouts;
/// * every disk card in the disk detail page carries a 60 s read/write plot -
///   portrait only, because the landscape card has no height to give.
///
/// The screens are pumped directly, at the two phone shapes the report covers,
/// so a layout decision is pinned without going through navigation.
void main() {
  const Size kPhonePortrait = Size(411, 891);
  const Size kPhoneLandscape = Size(891, 411);

  /// A live-shaped snapshot. `frequencyMHz` is present by default because
  /// PCMonitorHost sends it; [withFrequency] drops it to pin the placeholder.
  Map<String, dynamic> telemetry({
    bool withFrequency = true,
    int disks = 2,
    double disk0Read = 80.0,
    bool disk0WriteValid = true,
  }) =>
      <String, dynamic>{
        'cpu': <String, dynamic>{
          'name': 'Intel Core i9-9900K',
          'usagePercent': 21.0,
          'temperatureC': 52.0,
          'powerW': 43.0,
          if (withFrequency) 'frequencyMHz': 4300.0,
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
            'temperatureC': 61.0,
            'powerW': 120.0,
          },
        ],
        'network': <String, dynamic>{
          'downloadBytesPerSecond': 1500.0,
          'uploadBytesPerSecond': 300.0,
        },
        'storage': <String, dynamic>{
          'disks': <Map<String, dynamic>>[
            for (int i = 0; i < disks; i++)
              <String, dynamic>{
                'id': 'disk$i',
                'name': 'Drive $i / Test SSD',
                'readBytesPerSecond': i == 0 ? disk0Read : 20.0,
                if (i != 0 || disk0WriteValid) 'writeBytesPerSecond': 40.0,
                'activityPercent': 3.0,
                'temperatureC': 41.0,
              },
          ],
        },
      };

  MonitorProvider liveProvider({
    int snapshots = 12,
    bool withFrequency = true,
    int disks = 2,
    double disk0Read = 80.0,
    bool disk0WriteValid = true,
  }) {
    final MonitorProvider provider = MonitorProvider(
      simulate: false,
      persistSelection: false,
    );
    for (int i = 0; i < snapshots; i++) {
      provider.pushSnapshot(PcStatus.fromTelemetry(telemetry(
        withFrequency: withFrequency,
        disks: disks,
        disk0Read: disk0Read,
        disk0WriteValid: disk0WriteValid,
      )));
    }
    return provider;
  }

  Widget harness(Widget child) {
    return MonitorThemeScope(
      controller: ThemeController(),
      child: MaterialApp(
        home: ResponsiveBuilder(
          builder: (BuildContext context, LayoutMetrics metrics) => child,
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

  Widget dashboard(MonitorProvider provider) => DashboardScreen(
        provider: provider,
        onOpenCpu: () {},
        onOpenGpus: () {},
        onOpenDisks: () {},
        onOpenHosts: () {},
      );

  /// Every plot the disk page built, in tree order.
  List<Sparkline> diskPlots(WidgetTester tester) =>
      tester.widgetList<Sparkline>(find.byType(Sparkline)).toList();

  // -------------------------------------------------------------------------
  // CPU clock
  // -------------------------------------------------------------------------

  group('the CPU card shows the live clock', () {
    testWidgets('portrait: the clock sits on the sensor strip', (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(dashboard(provider)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Exactly one: the GPU card has no clock line, and nothing else on the
      // dashboard speaks in GHz.
      expect(find.text('4.30 GHz'), findsOneWidget);
    });

    testWidgets('landscape: the grid card carries it too', (tester) async {
      useViewport(tester, kPhoneLandscape);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(dashboard(provider)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('4.30 GHz'), findsOneWidget);
    });

    testWidgets('a host that reports no clock gets the placeholder',
        (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = liveProvider(withFrequency: false);
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(dashboard(provider)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The firmware's own placeholder, not a zero and not a hidden row: an
      // unreported clock must be as visible as an unreported temperature.
      expect(find.text('-- GHz'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Plot scaling
  // -------------------------------------------------------------------------

  group('sparklineCeiling', () {
    test('an empty window falls back to the floor', () {
      expect(sparklineCeiling(<List<double?>>[]), 1.0);
      expect(sparklineCeiling(<List<double?>>[<double?>[]]), 1.0);
    });

    test('a window of gaps falls back to the floor', () {
      expect(sparklineCeiling(<List<double?>>[
        <double?>[null, null, null],
      ]), 1.0);
    });

    test('the taller of two series sets the scale, with headroom', () {
      expect(
        sparklineCeiling(<List<double?>>[
          <double?>[10, 20],
          <double?>[5, 8],
        ]),
        closeTo(23.0, 1e-9),
      );
      expect(
        sparklineCeiling(<List<double?>>[
          <double?>[10, 20],
          <double?>[5, 800],
        ]),
        closeTo(920.0, 1e-9),
      );
    });

    test('an idle disk is not blown up into a mountain range', () {
      // A few KB/s is what a parked drive reports; on a scale of its own peak
      // that noise would fill the plot and read as load.
      expect(
        sparklineCeiling(<List<double?>>[
          <double?>[0.00008, 0.00004],
        ]),
        1.0,
      );
    });

    test('a non-finite sample cannot poison the scale', () {
      expect(
        sparklineCeiling(<List<double?>>[
          <double?>[double.infinity, 4],
        ]),
        closeTo(4.6, 1e-9),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Disk plots
  // -------------------------------------------------------------------------

  group('the disk cards plot their own throughput', () {
    testWidgets('portrait: every card carries a read/write plot',
        (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(
        DiskDetailScreen(provider: provider, onHome: () {}),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      final List<Sparkline> plots = diskPlots(tester);
      expect(plots.length, 2, reason: 'one plot per disk card');
      for (final Sparkline plot in plots) {
        expect(plot.secondaryPoints, isNotNull,
            reason: 'read and write share the plot, so both series exist');
        expect(plot.color, isNot(plot.secondaryColor));
      }
    });

    testWidgets('portrait: the plot is driven by live samples', (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(
        DiskDetailScreen(provider: provider, onHome: () {}),
      ));
      await tester.pump();

      expect(diskPlots(tester).first.points.last, 80.0 / 1000000.0);

      // One more second of telemetry: the card must redraw from it rather than
      // show a still frame captured at build time.
      provider.pushSnapshot(PcStatus.fromTelemetry(telemetry(disk0Read: 900.0)));
      await tester.pump();

      expect(diskPlots(tester).first.points.last, 900.0 / 1000000.0);
      expect(diskPlots(tester).first.secondaryPoints!.last, 40.0 / 1000000.0);
    });

    testWidgets('portrait: a direction the host stops reporting breaks the line',
        (tester) async {
      useViewport(tester, kPhonePortrait);
      final MonitorProvider provider = liveProvider(disk0WriteValid: false);
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(
        DiskDetailScreen(provider: provider, onHome: () {}),
      ));
      await tester.pump();

      final Sparkline plot = diskPlots(tester).first;
      expect(plot.points.last, isNotNull, reason: 'read keeps reporting');
      expect(plot.secondaryPoints!.last, isNull,
          reason: 'an unreported write is a gap, not a zero');
    });

    testWidgets('landscape: the short cards keep their numbers, not a curve',
        (tester) async {
      useViewport(tester, kPhoneLandscape);
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(
        DiskDetailScreen(provider: provider, onHome: () {}),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(diskPlots(tester), isEmpty);
      // The readings the curve would have displaced are still there.
      expect(find.textContaining('Read'), findsWidgets);
      expect(find.textContaining('Activity'), findsWidgets);
    });

    testWidgets('portrait but too many disks: the cards drop the plot',
        (tester) async {
      // Four disks in a short portrait viewport leave each card under the
      // height the plot needs. The card gives up the curve rather than the
      // numbers - and, above all, must not overflow.
      useViewport(tester, const Size(411, 600));
      final MonitorProvider provider = liveProvider(disks: 4);
      addTearDown(provider.dispose);

      await tester.pumpWidget(harness(
        DiskDetailScreen(provider: provider, onHome: () {}),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(diskPlots(tester), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // History windows
  // -------------------------------------------------------------------------

  group('disk history windows', () {
    test('are keyed by id, falling back to the name, never to a shared bucket',
        () {
      expect(
        MonitorProvider.diskHistoryKey(
            const DiskStatus(protocolId: 'disk0', name: 'X')),
        'disk0',
      );
      expect(
        MonitorProvider.diskHistoryKey(
            const DiskStatus(protocolId: '', name: 'USB Enclosure')),
        'USB Enclosure',
      );
      expect(
        MonitorProvider.diskHistoryKey(
            const DiskStatus(protocolId: '', name: '')),
        '',
      );
    });

    test('age to 60 points, one window per disk and direction', () {
      final MonitorProvider provider = liveProvider(snapshots: 100);
      addTearDown(provider.dispose);

      final List<double?> read = provider.diskReadHistoryFor('disk0');
      expect(read.length, kDashboardHistoryPoints);
      expect(read.last, 80.0 / 1000000.0);
      expect(read.first, isNotNull, reason: 'the window is full, so no gaps');
      expect(provider.diskReadHistoryFor('disk1').last, 20.0 / 1000000.0);
      expect(provider.diskReadHistoryFor('never-seen'), isEmpty);
    });

    test('are dropped when the source switches, so no series is spliced', () {
      final MonitorProvider provider = liveProvider();
      addTearDown(provider.dispose);

      expect(provider.diskReadHistoryFor('disk0'), isNotEmpty);

      provider.useSimulation(true);

      expect(provider.diskReadHistoryFor('disk0'), isEmpty);
      expect(provider.diskWriteHistoryFor('disk0'), isEmpty);
      // The simulator brings its own devices, with their own windows.
      expect(provider.diskReadHistoryFor('mock-disk-1'), isNotEmpty);
    });
  });
}
