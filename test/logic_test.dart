import 'package:flutter_test/flutter_test.dart';

import 'package:pcm_monitor/models/device_state.dart';
import 'package:pcm_monitor/models/pc_status.dart';
import 'package:pcm_monitor/services/mock_data_source.dart';
import 'package:pcm_monitor/util/format.dart';

/// Behavioural tests for the logic ported from `PCMonitorFirmware`.
///
/// These stay at the pure-logic level on purpose: the firmware parity that
/// matters lives in validity flags, formatting, GPU identity and rate scaling.
/// The widget tree is covered separately by `widget_smoke_test.dart`.
void main() {
  group('placeholder discipline', () {
    test('an invalid sensor renders its placeholder, never a fabricated 0', () {
      expect(fmtPercent(0, false), Ph.percent);
      expect(fmtPercent(100, false), Ph.percent);
      expect(fmtTemp(42, false), Ph.celsius);
      expect(fmtPower(100, false), Ph.watt);
      expect(fmtClock(4700, false), Ph.gigahertz);
      expect(fmtGiB(1073741824, false), Ph.gib);
    });

    test('a valid zero is a real reading, not a placeholder', () {
      expect(fmtPercent(0, true), '0%');
      expect(fmtTemp(0, true), '0.0 C');
      expect(fmtPower(0, true), '0.0 W');
    });

    test('placeholder constants keep the firmware spellings', () {
      expect(Ph.percent, '--%');
      expect(Ph.celsius, '-- C');
      expect(Ph.watt, '-- W');
      expect(Ph.gigahertz, '-- GHz');
      expect(Ph.gib, '-- GiB');
      expect(Ph.rate, '--');
    });
  });

  group('percent clamping', () {
    test('values outside 0..100 are clamped', () {
      expect(pcPercent(-5), 0);
      expect(pcPercent(50), 50);
      expect(pcPercent(180), 100);
    });

    test('fmtPercent clamps too', () {
      expect(fmtPercent(180, true), '100%');
      expect(fmtPercent(-3, true), '0%');
    });

    test('pcCount clamps a device count into range', () {
      expect(pcCount(3, 64), 3);
      expect(pcCount(-2, 64), 0);
      expect(pcCount(9999, PcLimits.cpuCores), PcLimits.cpuCores);
    });
  });

  group('rate formatting (ui_format_rate)', () {
    test('scales through B/s -> KB/s -> MB/s -> GB/s', () {
      expect(uiFormatRate(0, true), '0 B/s');
      expect(uiFormatRate(0.0005, true), '500 B/s');
      expect(uiFormatRate(0.001, true), '1.0 KB/s');
      expect(uiFormatRate(12.5, true), '12.5 MB/s');
      expect(uiFormatRate(2500, true), '2.5 GB/s');
    });

    test('invalid and non-finite input degrade to the placeholder', () {
      expect(uiFormatRate(12.5, false), Ph.rate);
      expect(uiFormatRate(double.nan, true), Ph.rate);
      expect(uiFormatRate(double.infinity, true), Ph.rate);
    });
  });

  group('temperature alarm colour', () {
    test('85 C is the threshold and invalid temperatures never alarm', () {
      expect(isHot(120, false), isFalse);
      expect(isHot(84.9, true), isFalse);
      expect(isHot(85, true), isTrue);
      expect(isHot(96, true), isTrue);
    });
  });

  group('GPU identity is the protocol id, never the array index', () {
    final PcStatus status = PcStatus.fromTelemetry(<String, dynamic>{
      'gpus': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'gpu-intel',
          'name': 'Intel UHD',
          'isDiscrete': false,
        },
        <String, dynamic>{
          'id': 'gpu-nv',
          'name': 'RTX 4070',
          'isDiscrete': true,
        },
      ],
    });

    test('lookup by id', () {
      expect(status.findGpu('gpu-nv')?.name, 'RTX 4070');
      expect(status.findGpu('gpu-intel')?.name, 'Intel UHD');
    });

    test('an empty or unknown id never matches', () {
      expect(status.findGpu(''), isNull);
      expect(status.findGpu('does-not-exist'), isNull);
    });

    test('primaryGpu follows the supplied fallback index, clamped', () {
      // Mirrors `pc_status_primary_gpu()`: the index is clamped into range.
      // It is NOT a search for the discrete adapter.
      expect(status.primaryGpu(0)?.id, 'gpu-intel');
      expect(status.primaryGpu(1)?.id, 'gpu-nv');
      expect(status.primaryGpu(9)?.id, 'gpu-nv');
    });

    test('gpuAt is bounds checked', () {
      expect(status.gpuAt(0)?.id, 'gpu-intel');
      expect(status.gpuAt(1)?.id, 'gpu-nv');
      expect(status.gpuAt(9), isNull);
    });
  });

  group('busiest engine selection', () {
    test('picks the maximum usage among valid engines', () {
      final GpuStatus gpu = GpuStatus.fromJson(<String, dynamic>{
        'id': 'g',
        'engines': <Map<String, dynamic>>[
          <String, dynamic>{'name': '3D', 'usagePercent': 12},
          <String, dynamic>{'name': 'Copy', 'usagePercent': 91},
          <String, dynamic>{'name': 'Video', 'usagePercent': 40},
        ],
      });
      final GpuEngine? busiest = PcStatus.busiestEngine(gpu);
      expect(busiest?.name, 'Copy');
      expect(busiest?.usage, 91);
    });

    test('an engine with no valid usage is never chosen', () {
      final GpuStatus gpu = GpuStatus.fromJson(<String, dynamic>{
        'id': 'g',
        'engines': <Map<String, dynamic>>[
          <String, dynamic>{'name': '3D'},
          <String, dynamic>{'name': 'Copy', 'usagePercent': 5},
        ],
      });
      expect(PcStatus.busiestEngine(gpu)?.name, 'Copy');
    });

    test('no engines yields null so the dashboard falls back to TOTAL', () {
      expect(
        PcStatus.busiestEngine(GpuStatus.fromJson(<String, dynamic>{'id': 'g'})),
        isNull,
      );
    });

    test('findEngine matches on the engine protocol id', () {
      final GpuStatus gpu = GpuStatus.fromJson(<String, dynamic>{
        'id': 'g',
        'engines': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'eng-3d', 'name': '3D', 'usagePercent': 12},
        ],
      });
      expect(PcStatus.findEngine(gpu, 'eng-3d')?.name, '3D');
      expect(PcStatus.findEngine(gpu, ''), isNull);
      expect(PcStatus.findEngine(null, 'eng-3d'), isNull);
    });
  });

  group('unit conversions', () {
    test('bytes -> GiB uses 1024^3', () {
      expect(fmtGiB(1073741824, true), '1.0 GiB');
      expect(fmtGiB(17179869184, true), '16.0 GiB');
    });

    test('MHz -> GHz divides by 1000', () {
      expect(fmtClock(4700, true), '4.70 GHz');
    });

    test('disk bytes/s is decoded as decimal MB/s', () {
      final PcStatus s = PcStatus.fromTelemetry(<String, dynamic>{
        'storage': <String, dynamic>{
          'disks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'd0',
              'name': 'NVMe',
              'readBytesPerSecond': 12500000,
              'writeBytesPerSecond': 3000000,
              'temperatureC': 41,
            },
          ],
        },
      });
      expect(s.disks.single.readMbS, closeTo(12.5, 1e-9));
      expect(s.disks.single.writeMbS, closeTo(3.0, 1e-9));
      expect(s.disks.single.temp, 41);
    });

    test('a missing sensor clears its validity flag instead of defaulting', () {
      final PcStatus s = PcStatus.fromTelemetry(<String, dynamic>{
        'cpu': <String, dynamic>{'name': 'Test CPU', 'usagePercent': 17},
      });
      expect(s.cpuUsageValid, isTrue);
      expect(s.cpuUsage, 17);
      expect(s.cpuTempValid, isFalse);
      expect(s.cpuClockValid, isFalse);
      expect(s.cpuPowerValid, isFalse);
    });
  });

  group('device state text (the firmware 13-state set)', () {
    test('every state maps to its firmware wording', () {
      expect(deviceStateText(DeviceState.booting), 'Booting');
      expect(deviceStateText(DeviceState.unprovisioned), 'No Wi-Fi config');
      expect(deviceStateText(DeviceState.usbProvisioning), 'USB setup');
      expect(deviceStateText(DeviceState.wifiConnecting), 'Connecting Wi-Fi');
      expect(deviceStateText(DeviceState.wifiConnected), 'Wi-Fi connected');
      expect(deviceStateText(DeviceState.timeSyncing), 'Syncing time');
      expect(deviceStateText(DeviceState.discoveringHost), 'Looking for PC');
      expect(deviceStateText(DeviceState.connectingHost), 'Connecting PC');
      expect(deviceStateText(DeviceState.authenticating), 'Authenticating');
      expect(deviceStateText(DeviceState.connected), 'Connected');
      expect(deviceStateText(DeviceState.hostOffline), 'PC Offline');
      expect(deviceStateText(DeviceState.wifiOffline), 'Wi-Fi Offline');
      expect(deviceStateText(DeviceState.error), 'Error');
    });
  });

  group('connection badge mapping', () {
    test('SIMULATED -> SIM, LIVE -> LIVE, stale -> STALE, else WAIT', () {
      expect(connectionBadge(ConnectionKind.simulated), 'SIM');
      expect(connectionBadge(ConnectionKind.live), 'LIVE');
      expect(connectionBadge(ConnectionKind.stale), 'STALE');
      expect(connectionBadge(ConnectionKind.waiting), 'WAIT');
    });

    test('classification mirrors ui_statusbar_set_connection', () {
      expect(
        classifyConnection('SIMULATED / 1 Hz'),
        ConnectionKind.simulated,
      );
      expect(classifyConnection('Connected'), ConnectionKind.live);
      expect(classifyConnection('LIVE'), ConnectionKind.live);
      expect(classifyConnection('Data stale'), ConnectionKind.stale);
      expect(classifyConnection('Booting'), ConnectionKind.waiting);
    });
  });

  group('mock data source', () {
    test('the workstation profile produces a fully valid sample', () {
      final MockDataSource source = MockDataSource();
      final PcStatus status = source.step();
      expect(status.cpuName, isNotEmpty);
      expect(status.cpuUsageValid, isTrue);
      expect(status.cpuTempValid, isTrue);
      expect(status.ramTotal, greaterThan(0));
      expect(status.gpus, isNotEmpty);
      expect(status.disks, isNotEmpty);
    });

    test('samples keep advancing so the UI has something to animate', () {
      final MockDataSource source = MockDataSource();
      final Set<int> seen = <int>{};
      for (int i = 0; i < 40; i++) {
        seen.add(source.step().cpuUsage);
      }
      expect(seen.length, greaterThan(1));
    });

    test('the firmware profile stays inside the protocol caps', () {
      final MockDataSource source =
          MockDataSource(profile: MockProfile.firmware);
      final PcStatus status = source.step();
      expect(status.cpuCoreCount, lessThanOrEqualTo(PcLimits.cpuCores));
      expect(status.gpuCount, lessThanOrEqualTo(PcLimits.gpus));
      expect(status.diskCount, lessThanOrEqualTo(PcLimits.disks));
    });

    test('hideSensorsForReview exercises the placeholder path', () {
      final MockDataSource source = MockDataSource();
      source.step();
      source.hideSensorsForReview();
      final PcStatus status = source.status;
      expect(status.cpuTempValid, isFalse);
      expect(status.cpuPowerValid, isFalse);
      expect(status.cpuClockValid, isFalse);
      expect(status.disks.every((DiskStatus d) => !d.tempValid), isTrue);
    });
  });

  group('protocol caps', () {
    test('the wire limits match the firmware headers', () {
      expect(PcLimits.cpuCores, 64);
      expect(PcLimits.gpus, 4);
      expect(PcLimits.gpuEngines, 32);
      expect(PcLimits.disks, 8);
    });
  });
}
