/// Port of `PCMonitorFirmware/model/device_state.{h,c}`.
library;

enum DeviceState {
  booting,
  unprovisioned,
  usbProvisioning,
  wifiConnecting,
  wifiConnected,
  timeSyncing,
  discoveringHost,
  connectingHost,
  authenticating,
  connected,
  hostOffline,
  wifiOffline,
  error,
}

const List<String> _kLabels = <String>[
  'Booting',
  'No Wi-Fi config',
  'USB setup',
  'Connecting Wi-Fi',
  'Wi-Fi connected',
  'Syncing time',
  'Looking for PC',
  'Connecting PC',
  'Authenticating',
  'Connected',
  'PC Offline',
  'Wi-Fi Offline',
  'Error',
];

/// Mirrors `device_state_text()`.
String deviceStateText(DeviceState state) => _kLabels[state.index];

/// How the connection state is presented in the status indicator.
enum ConnectionKind {
  /// Mock / simulator data source.
  simulated,

  /// Live telemetry, current.
  live,

  /// Live telemetry, but no sample within the staleness window.
  stale,

  /// Waiting for the first sample, or an intermediate connection state.
  waiting,
}

/// Port of `ui_statusbar_set_connection()`.
ConnectionKind classifyConnection(String text) {
  final String upper = text.toUpperCase();
  if (upper.contains('SIMULATED')) return ConnectionKind.simulated;
  if (upper.contains('LIVE') || text.contains('Connected')) {
    return ConnectionKind.live;
  }
  if (upper.contains('STALE')) return ConnectionKind.stale;
  return ConnectionKind.waiting;
}

/// Short badge label for the status pill: `SIM` / `LIVE` / `STALE` / `WAIT`.
String connectionBadge(ConnectionKind kind) {
  switch (kind) {
    case ConnectionKind.simulated:
      return 'SIM';
    case ConnectionKind.live:
      return 'LIVE';
    case ConnectionKind.stale:
      return 'STALE';
    case ConnectionKind.waiting:
      return 'WAIT';
  }
}
