import 'package:flutter/widgets.dart';

import '../services/tap_sound.dart';

/// Plays the tap effect for taps anywhere in the tree.
///
/// Deliberately a listener rather than a callback plumbed into every button:
/// the app has four pages, a bottom sheet and a dozen tappable panels, and a
/// per-widget hook would both miss the panels that only look non-interactive
/// and drift apart the moment a new one is added. One pass over the pointer
/// stream covers all of them, including anything added later.
///
/// What counts as a tap is decided here rather than by the gesture system:
/// pointer down and up on the same spot, within [kTapMaxDuration] and without
/// travelling further than [kTapSlop]. A scroll, a drag and a long press all
/// fail one of those three and stay silent - otherwise every flick of the disk
/// list would machine-gun the effect.
class TapSoundListener extends StatefulWidget {
  const TapSoundListener({super.key, required this.child});

  final Widget child;

  /// Longer than this and the gesture is a press, which already has its own
  /// visual feedback in the HUD widgets.
  static const Duration kTapMaxDuration = Duration(milliseconds: 380);

  /// Movement past this many logical pixels means the finger was scrolling,
  /// not tapping. The framework's own touch slop is 18.
  static const double kTapSlop = 16;

  @override
  State<TapSoundListener> createState() => _TapSoundListenerState();
}

class _TapSoundListenerState extends State<TapSoundListener> {
  int? _pointer;
  Duration _downAt = Duration.zero;
  Offset _downPosition = Offset.zero;
  bool _moved = false;

  TapSoundController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = TapSoundScope.maybeOf(context);
  }

  void _onDown(PointerDownEvent event) {
    // A second finger landing mid-gesture must not restart the timer of the
    // first: pin one pointer and ignore everything else until it lifts.
    if (_pointer != null) return;
    _pointer = event.pointer;
    _downAt = event.timeStamp;
    _downPosition = event.position;
    _moved = false;
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _downPosition).distance >
        TapSoundListener.kTapSlop) {
      _moved = true;
    }
  }

  void _onUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final bool tap = !_moved &&
        event.timeStamp - _downAt <= TapSoundListener.kTapMaxDuration;
    _reset();
    if (tap) _controller?.play();
  }

  void _onCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _reset();
  }

  void _reset() {
    _pointer = null;
    _moved = false;
  }

  @override
  Widget build(BuildContext context) {
    // `translucent` so the listener is on the hit-test path even where the
    // child is a bare ColoredBox: a tap on the empty part of a panel still
    // reaches it, and the child keeps receiving the event as usual.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }
}
