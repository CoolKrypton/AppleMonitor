/// The tap effect: a short, muffled "bloop", like a bubble breaking underwater.
///
/// ## Where the sound comes from
///
/// `assets/sfx/tap_bubble.wav` is synthesised, not sampled - 44.1 kHz mono,
/// 0.36 s, peak around -7 dBFS. The recipe, so it can be rebuilt or adjusted
/// without hunting for the source:
///
/// * a sine whose pitch glides 180 -> 430 Hz in about 45 ms with an
///   exponential decay (the bubble itself);
/// * a sub-octave sine at 62 -> 88 Hz and a 380 Hz-lowpassed noise thump on
///   the onset, which is the "water" rather than the "beep";
/// * a second, quieter bubble at 105 ms, so the tap reads as a *shape*
///   (bloop-blip) instead of a single blip;
/// * two cascaded one-pole low-passes at 700 Hz and a 45 ms tail fade - the
///   low-pass is what makes it sound submerged, the fade is what stops iOS
///   from playing a click at the end of the buffer.
///
/// ## How it plays
///
/// Taps are frequent and often overlap (a double tap, a fast scroll of
/// buttons), so a single player would cut itself off. A small ring of
/// pre-loaded players is seeded once at startup instead of decoding the asset
/// per tap - that is the difference between a tap that feels attached to the
/// finger and one that arrives a frame or two late.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'pairing_store.dart';

/// Preference key: whether the tap effect is audible. Absent means "on" - the
/// effect is part of the interface, not an opt-in extra.
const String kTapSoundPreferenceKey = 'pcmonitor.tapSound';

/// The bundled effect, spelled as it appears in `pubspec.yaml`.
const String kTapSoundAsset = 'assets/sfx/tap_bubble.wav';

/// How many taps can overlap before the oldest voice is reused.
///
/// Four covers a double tap plus a stray second finger; more would just stack
/// the same 0.3 s sound on itself and turn into noise.
const int kTapSoundVoices = 4;

/// Two taps closer together than this are one gesture (a finger landing twice
/// inside a double-tap window), not two effects.
const Duration kTapSoundDebounce = Duration(milliseconds: 45);

/// Owns the tap effect: the on/off preference, the pre-loaded voices, playback.
///
/// Lives at the app root next to the theme controller and is reached through
/// [TapSoundScope]. Persisting the preference is this class's own job - unlike
/// the theme, nothing else ever writes it.
class TapSoundController extends ChangeNotifier {
  TapSoundController({KeyValueStore? store, bool enabled = true})
      : _store = store,
        _enabled = enabled {
    _voices = List<_TapVoice>.generate(kTapSoundVoices, (_) => _TapVoice());
  }

  final KeyValueStore? _store;
  late final List<_TapVoice> _voices;

  bool _enabled;
  bool _primed = false;
  int _nextVoice = 0;
  int _playRequests = 0;
  DateTime? _lastPlayed;
  bool _disposed = false;

  /// Whether the user wants to hear the effect.
  bool get enabled => _enabled;

  /// How many taps have asked for the effect.
  ///
  /// Requests, not sounds: a muted controller or one whose asset has not
  /// loaded still counts them. It is what the tests can observe without an
  /// audio device, and what makes "the listener heard a tap the gesture system
  /// did not consider a tap" debuggable.
  @visibleForTesting
  int get playRequests => _playRequests;

  /// Whether at least one voice finished loading the asset. Exposed for tests
  /// and for the settings row's subtitle; a false here means the effect is
  /// silent, never that the app is broken.
  bool get isPrimed => _primed;

  /// Reads the stored preference and pre-loads the voices.
  ///
  /// Every failure is swallowed: a monitor that cannot play a click still
  /// monitors, so this must never surface an error or delay the first frame.
  Future<void> load() async {
    await _restorePreference();
    await _prime();
  }

  Future<void> _restorePreference() async {
    final KeyValueStore? store = _store;
    if (store == null) return;
    try {
      final String? raw = await store.read(kTapSoundPreferenceKey);
      if (raw == null) return;
      final bool stored = raw != '0';
      if (stored == _enabled) return;
      _enabled = stored;
      notifyListeners();
    } catch (_) {
      // An unreadable preference must not mute the effect or block startup.
    }
  }

  Future<void> _prime() async {
    try {
      final ByteData data = await rootBundle.load(kTapSoundAsset);
      final Uint8List bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      for (final _TapVoice voice in _voices) {
        await voice.prime(bytes);
        // One failing voice means the audio session itself is unavailable (no
        // plugin, no device, muted output). Priming the other three would only
        // repeat the same failure four times.
        if (!voice.ready) break;
      }
      _primed = _voices.any((_TapVoice voice) => voice.ready);
    } catch (_) {
      // No audio plugin (tests, an unsupported platform) or no asset: stay
      // silent rather than throwing on every tap.
      _primed = false;
    }
  }

  /// Turns the effect on or off and remembers the choice.
  void setEnabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
    // Switching it *on* is the one moment the user cannot tell it worked: the
    // tap that flipped the switch was still muted when the listener saw it.
    // Switching it off needs nothing - that same tap was audible already, and
    // it is the last sound the effect makes.
    if (value) play();
    final KeyValueStore? store = _store;
    if (store == null) return;
    unawaited(
      store
          .write(kTapSoundPreferenceKey, value ? '1' : '0')
          .catchError((Object _) {}),
    );
  }

  /// Plays one bubble. Safe to call on every pointer-up in the app: it is a
  /// no-op while muted, while the asset is still loading, and when the
  /// previous tap is less than [kTapSoundDebounce] old.
  void play() {
    _playRequests++;
    if (!_enabled || _disposed || !_primed) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastPlayed;
    if (last != null && now.difference(last) < kTapSoundDebounce) return;
    _lastPlayed = now;

    final _TapVoice voice = _voices[_nextVoice];
    _nextVoice = (_nextVoice + 1) % _voices.length;
    unawaited(voice.fire());
  }

  @override
  void dispose() {
    _disposed = true;
    for (final _TapVoice voice in _voices) {
      unawaited(voice.dispose());
    }
    super.dispose();
  }
}

/// One player, pre-loaded with the effect and rewound on every tap.
///
/// The player is built in [prime] rather than in a field initialiser on
/// purpose. `AudioPlayer` opens a native session in its constructor and
/// reports a failure through `creatingCompleter`; a completer whose error is
/// never awaited surfaces as an unhandled exception - which fails a widget
/// test outright and logs a crash on a device without an audio session. So the
/// very first thing [prime] does is await exactly that future, in the same
/// synchronous run that created the player.
class _TapVoice {
  AudioPlayer? _player;

  bool ready = false;

  /// Amplitude of the effect relative to the file. The file peaks near -7 dBFS
  /// already; halving it again keeps a tap audible without being the loudest
  /// thing in the room.
  static const double _volume = 0.55;

  Future<void> prime(Uint8List bytes) async {
    try {
      final AudioPlayer player = _player = AudioPlayer();
      await player.creatingCompleter.future;
      final AudioContext? context = _tapContext();
      if (context != null) await player.setAudioContext(context);
      // `stop`, not the default `release`: releasing drops the source, and the
      // next tap would have to decode the whole file again.
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setSourceBytes(bytes, mimeType: 'audio/wav');
      await player.setVolume(_volume);
      ready = true;
    } catch (_) {
      ready = false;
    }
  }

  Future<void> fire() async {
    final AudioPlayer? player = _player;
    if (!ready || player == null) return;
    try {
      await player.seek(Duration.zero);
      await player.resume();
    } catch (_) {
      // A voice that failed once is not retried for the rest of the session:
      // a broken audio session must not turn every tap into an async throw.
      ready = false;
    }
  }

  Future<void> dispose() async {
    final AudioPlayer? player = _player;
    if (player == null) return;
    try {
      await player.dispose();
    } catch (_) {
      // Nothing to do - the engine may already be gone during a hot restart.
    }
  }
}

/// The audio session the effect runs in: ambient, so it mixes with whatever is
/// already playing and stays silent when the ring switch is off.
///
/// Built defensively because the platform mapping is version-dependent; if it
/// cannot be built the voice keeps the plugin's default session, which still
/// plays the sound.
AudioContext? _tapContext() {
  try {
    return AudioContextConfig(
      respectSilence: true,
      focus: AudioContextConfigFocus.mixWithOthers,
    ).build();
  } catch (_) {
    return null;
  }
}

/// Inherited accessor for the [TapSoundController].
class TapSoundScope extends InheritedNotifier<TapSoundController> {
  const TapSoundScope({
    super.key,
    required TapSoundController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The controller, or `null` when no scope is mounted - the settings sheet
  /// and the widget tests render without the app root, and neither should
  /// have to fabricate one.
  static TapSoundController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TapSoundScope>()
      ?.notifier;

  static TapSoundController of(BuildContext context) {
    final TapSoundController? controller = maybeOf(context);
    assert(controller != null, 'TapSoundScope is missing from the widget tree.');
    return controller!;
  }
}
