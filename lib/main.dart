import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'responsive/responsive.dart';
import 'screens/host_connect_screen.dart';
import 'screens/monitor_shell.dart';
import 'services/host_connection.dart';
import 'services/monitor_provider.dart';
import 'services/pairing_store.dart';
import 'services/tap_sound.dart';
import 'theme/monitor_theme.dart';
import 'theme/theme_context.dart';
import 'widgets/tap_sound_listener.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // The skin is read *before* the first frame, so the app opens straight into
  // the theme the user picked instead of flashing the default one first.
  final KeyValueStore store = SharedPreferencesStore();
  final String? storedThemeId = await _storedThemeId(store);

  runApp(PcMonitorApp(store: store, initialThemeId: storedThemeId));
}

/// Reads the saved theme id, treating any storage failure as "nothing saved" -
/// a broken preference file must never block startup.
Future<String?> _storedThemeId(KeyValueStore store) async {
  try {
    return await store.read(kThemePreferenceKey);
  } catch (_) {
    return null;
  }
}

/// Root widget.
///
/// Three long-lived controllers are created here and handed down through
/// `InheritedNotifier`s, so a theme change rebuilds the visuals without
/// restarting the sampling loop, and vice versa:
///
/// * [ThemeController] - the interface skin;
/// * [MonitorProvider] - the display pipeline (mock *or* live);
/// * [HostConnectionController] - discovery, pairing and the WebSocket session.
class PcMonitorApp extends StatefulWidget {
  const PcMonitorApp({super.key, this.store, this.initialThemeId});

  /// Storage for the skin choice. `main` injects it; tests and the preview
  /// harness leave it null and get the real `SharedPreferences` store.
  final KeyValueStore? store;

  /// The skin restored from storage before the first frame.
  final String? initialThemeId;

  @override
  State<PcMonitorApp> createState() => _PcMonitorAppState();
}

class _PcMonitorAppState extends State<PcMonitorApp> {
  late final KeyValueStore _store = widget.store ?? SharedPreferencesStore();
  late final ThemeController _themeController =
      ThemeController(initial: themeForId(widget.initialThemeId));
  late final MonitorProvider _provider;
  late final HostConnectionController _connection;

  /// The tap effect. Loading it is deliberately not awaited: a monitor that
  /// cannot play a click still monitors, so a slow or missing audio session
  /// must never hold up the splash screen.
  late final TapSoundController _tapSound = TapSoundController(store: _store);

  late final Future<void> _bootstrap;

  @override
  void initState() {
    super.initState();
    // Live by default: the app is a monitor, and the hosts page is what turns
    // "no data" into "connected". The simulator stays one tap away for demos.
    _provider = MonitorProvider(simulate: false);
    _provider.start();

    _connection = HostConnectionController(
      store: PairingStore(_store),
      onSnapshot: _provider.pushSnapshot,
    );
    _connection.addListener(_publishLinkState);
    // The stored skin was already applied when the controller was built, so
    // the bootstrap only has the pairing left to read.
    _themeController.addListener(_persistTheme);
    _bootstrap = _connection.start();
    _publishLinkState();
    unawaited(_tapSound.load());
  }

  /// Every path that changes the skin - the picker sheet and the long-press
  /// cycle alike - goes through `ThemeController.select`, so one listener
  /// covers them all. A failed write is swallowed: losing a preference is
  /// never worth surfacing an error over.
  void _persistTheme() {
    unawaited(
      _store
          .write(kThemePreferenceKey, _themeController.themeId)
          .catchError((Object _) {}),
    );
  }

  /// Keeps the status pill in step with the link without the shell having to
  /// know about the transport.
  void _publishLinkState() {
    _provider.updateLinkStatus(
      text: connectionStatusText(_connection.state, _connection.message),
      kind: connectionKindFor(_connection.state),
    );
  }

  @override
  void dispose() {
    _connection.removeListener(_publishLinkState);
    _connection.dispose();
    _provider.dispose();
    _themeController.removeListener(_persistTheme);
    _themeController.dispose();
    _tapSound.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TapSoundScope(
      controller: _tapSound,
      child: MonitorThemeScope(
        controller: _themeController,
        child: ListenableBuilder(
          listenable: _themeController,
          builder: (BuildContext context, Widget? child) {
            final MonitorTheme theme = _themeController.theme;
            return MaterialApp(
              title: 'PC Monitor',
              debugShowCheckedModeBanner: false,
              theme: theme.toThemeData(),
              // The UI is portrait-and-landscape aware by design, so no
              // orientation lock is applied.
              builder: (BuildContext context, Widget? child) {
                // Keeps the status bar legible against every theme, and applies
                // the brightness the PC asked for. `device.settings.set` maps to
                // an overlay here because Android gives no app-level backlight
                // control without a privileged permission.
                //
                // The DefaultTextStyle wrapper anchors the merge base for every
                // Text in the tree with an explicit `decoration: none`. On
                // Huawei/EMUI devices, labels that live outside a Material
                // subtree otherwise inherit the platform's underline paint flag
                // and render with a pure-yellow double underline.
                //
                // TapSoundListener wraps the Navigator's child rather than the
                // app: sitting inside MaterialApp is what lets it hear taps on
                // modal routes (the settings sheet) as well as on the pages.
                return TapSoundListener(
                  child: DefaultTextStyle(
                    style: const TextStyle(decoration: TextDecoration.none),
                    child: AnnotatedRegion<SystemUiOverlayStyle>(
                      value: theme.isDark
                          ? SystemUiOverlayStyle.light
                          : SystemUiOverlayStyle.dark,
                      child: AnimatedBuilder(
                        animation: _connection,
                        builder: (BuildContext context, Widget? _) {
                          final double dim = _connection.dimOverlay;
                          return Stack(
                            children: <Widget>[
                              if (child != null) child,
                              if (dim > 0.001)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: ColoredBox(
                                      color:
                                          Colors.black.withValues(alpha: dim),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
              home: FutureBuilder<void>(
                future: _bootstrap,
                builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SplashScreen();
                  }
                  return AnimatedBuilder(
                    animation: _provider,
                    builder: (BuildContext context, Widget? child) {
                      return ResponsiveBuilder(
                        builder: (BuildContext context, LayoutMetrics metrics) {
                          return MonitorShell(
                            provider: _provider,
                            connection: _connection,
                            // A phone that has never paired opens straight onto
                            // the discovery page: there is nothing to show yet.
                            startOnHosts: _connection.pairedHost == null,
                          );
                        },
                      );
                    },
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Shown for the few milliseconds the stored pairing is being read.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    return Scaffold(
      backgroundColor: theme.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.memory, color: theme.cpu, size: 42),
            const SizedBox(height: 14),
            Text(
              'PC MONITOR',
              style: TextStyle(
                color: theme.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
