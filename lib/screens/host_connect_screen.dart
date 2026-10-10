/// "Find your PC" - the discovery, pairing and connection page.
///
/// The firmware has no equivalent screen: an ESP32 is paired once over USB and
/// then silently re-discovers its host. A phone has no USB path and no
/// pre-shared secret, so this page *is* the provisioning flow, and it has to
/// tell the user four things at a glance:
///
/// * whether the app is looking, and for how long;
/// * which PCs are on this network, and whether they will accept a pairing;
/// * that pairing needs a click **on the PC**, not here;
/// * whether the link is up, and what this phone calls itself in that dialog.
///
/// Layout follows the rest of the app: one column in portrait, a scanner plus a
/// list in landscape, and a viewport-filling frame so nothing scrolls.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/device_state.dart';
import '../responsive/responsive.dart';
import '../services/host_connection.dart';
import '../services/host_discovery_service.dart';
import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';
import '../widgets/hud.dart';

class HostConnectScreen extends StatefulWidget {
  const HostConnectScreen({
    super.key,
    required this.connection,
    required this.onOpenDashboard,
    required this.onUseSimulation,
  });

  final HostConnectionController connection;

  /// Jump to the dashboard - only meaningful once the link is up.
  final VoidCallback onOpenDashboard;

  /// Fall back to the built-in simulator, so the UI can be explored offline.
  final VoidCallback onUseSimulation;

  @override
  State<HostConnectScreen> createState() => _HostConnectScreenState();
}

class _HostConnectScreenState extends State<HostConnectScreen> {
  @override
  void initState() {
    super.initState();
    // Arriving on this page means the user wants a PC; a scan that is already
    // running is left alone, otherwise start one.
    if (widget.connection.state == HostConnectionState.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.connection.scan();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final LayoutMetrics metrics = context.layout;
    return AnimatedBuilder(
      animation: widget.connection,
      builder: (BuildContext context, Widget? child) {
        return HudBackground(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              metrics.pagePadding,
              metrics.pagePadding,
              metrics.pagePadding,
              metrics.pagePadding,
            ),
            child: metrics.isWide ? _wide(metrics) : _tall(metrics),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // layouts
  // -------------------------------------------------------------------------

  /// Phones in portrait: scanner on top, list filling the middle, actions last.
  Widget _tall(LayoutMetrics metrics) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(metrics),
        SizedBox(height: metrics.gutter),
        // The scanner keeps a 1:1 aspect ratio but yields when the viewport is
        // short, so the host list always gets a usable slice.
        Flexible(
          flex: 42,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _RadarPanel(connection: widget.connection),
                ),
              );
            },
          ),
        ),
        SizedBox(height: metrics.gutter),
        Expanded(flex: 58, child: _hostList(metrics)),
        SizedBox(height: metrics.gutter),
        _deviceRow(metrics),
        SizedBox(height: metrics.gutter),
        _actions(metrics),
      ],
    );
  }

  /// Landscape / tablet: scanner beside the list, actions across the bottom.
  Widget _wide(LayoutMetrics metrics) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(metrics),
        SizedBox(height: metrics.gutter),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: _RadarPanel(connection: widget.connection)),
                    SizedBox(height: metrics.gutter),
                    _deviceRow(metrics),
                  ],
                ),
              ),
              SizedBox(width: metrics.gutter),
              Expanded(flex: 6, child: _hostList(metrics)),
            ],
          ),
        ),
        SizedBox(height: metrics.gutter),
        _actions(metrics),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // pieces
  // -------------------------------------------------------------------------

  Widget _header(LayoutMetrics metrics) {
    final MonitorTheme theme = context.theme;
    final HostConnectionController c = widget.connection;
    final Color color = _stateColor(theme, c.state);

    return HudPanel(
      radius: metrics.panelRadius,
      accent: color.withValues(alpha: 0.55),
      // The chamfer is what makes the header read as a HUD console strip rather
      // than a card; the rest of the panels stay rounded.
      cornerCut: metrics.cornerCut,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.px(14),
        vertical: metrics.px(11),
      ),
      child: Row(
        children: <Widget>[
          StatusDot(color: color, size: metrics.px(8)),
          SizedBox(width: metrics.px(9)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'HOST LINK',
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(13),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.0,
                  ),
                ),
                SizedBox(height: metrics.px(3)),
                Text(
                  c.message.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(9.5),
                    letterSpacing: 0.7,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: metrics.px(8)),
          HudBadge(
            label: _stateBadge(c.state),
            color: color,
            filled: c.state == HostConnectionState.online,
            fontSize: metrics.font(10),
          ),
        ],
      ),
    );
  }

  Widget _hostList(LayoutMetrics metrics) {
    final MonitorTheme theme = context.theme;
    final HostConnectionController c = widget.connection;
    final List<DiscoveredHost> hosts = c.hosts;

    if (hosts.isEmpty) {
      return HudPanel(
        radius: metrics.panelRadius,
        accent: theme.border,
        padding: EdgeInsets.all(metrics.panelPadding),
        child: Center(
          child: Text(
            c.state == HostConnectionState.scanning
                ? 'LISTENING FOR BROADCASTS…'
                : 'NO PCS LISTED YET',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.muted,
              fontSize: metrics.font(10),
              letterSpacing: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    // Rows share the available height, bounded so a single host is not blown up
    // into a banner and a long list still scrolls inside its own panel.
    final double available = metrics.size.height * 0.6;
    final double rowHeight = (available / hosts.length).clamp(
      metrics.px(72),
      metrics.px(150),
    );

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: hosts.length,
      separatorBuilder: (BuildContext context, int index) =>
          SizedBox(height: metrics.gutter),
      itemBuilder: (BuildContext context, int index) {
        final DiscoveredHost host = hosts[index];
        return SizedBox(
          height: rowHeight,
          child: _HostCard(
            host: host,
            connection: c,
            onTap: () => c.select(host),
          ),
        );
      },
    );
  }

  Widget _deviceRow(LayoutMetrics metrics) {
    final MonitorTheme theme = context.theme;
    final HostConnectionController c = widget.connection;
    final bool paired = c.pairedHost != null;

    return HudPanel(
      radius: metrics.panelRadius,
      accent: (paired ? theme.gpu : theme.border).withValues(alpha: 0.45),
      padding: EdgeInsets.symmetric(
        horizontal: metrics.panelPadding,
        vertical: metrics.px(10),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.smartphone, color: theme.cpu, size: metrics.px(16)),
          SizedBox(width: metrics.px(9)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'THIS DEVICE',
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(8.5),
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: metrics.px(2)),
                Text(
                  c.deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(12),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: metrics.px(8)),
          // The name is what the user has to recognise in the PC's dialog, so
          // it is editable from here rather than buried in settings.
          IconButton(
            onPressed: () => _editDeviceName(context, c),
            icon: Icon(Icons.edit_outlined, color: theme.cpu, size: metrics.px(16)),
            tooltip: 'Rename this device',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _actions(LayoutMetrics metrics) {
    final MonitorTheme theme = context.theme;
    final HostConnectionController c = widget.connection;
    final bool busy = c.state == HostConnectionState.scanning ||
        c.state == HostConnectionState.requesting ||
        c.state == HostConnectionState.connecting;
    final double height = metrics.px(38);

    final List<Widget> buttons = <Widget>[
      HudButton(
        label: c.state == HostConnectionState.online ? 'Rescan' : 'Scan',
        icon: Icons.wifi_tethering,
        onPressed: busy ? null : () => c.scan(),
        height: height,
      ),
      if (c.pairedHost != null && c.state != HostConnectionState.online)
        HudButton(
          label: 'Reconnect',
          icon: Icons.link,
          onPressed: c.reconnect,
          height: height,
        ),
      if (c.pairedHost != null)
        HudButton(
          label: 'Forget',
          icon: Icons.link_off,
          danger: true,
          onPressed: () => _confirmForget(context, c),
          height: height,
        ),
      if (c.state == HostConnectionState.requesting)
        HudButton(
          label: 'Cancel',
          icon: Icons.close,
          onPressed: () => c.disconnect(),
          height: height,
        ),
      if (c.state == HostConnectionState.online) ...<Widget>[
        HudButton(
          label: 'Dashboard',
          icon: Icons.dashboard_outlined,
          filled: true,
          accent: theme.gpu,
          onPressed: widget.onOpenDashboard,
          height: height,
        ),
        HudButton(
          label: 'Disconnect',
          icon: Icons.power_settings_new,
          onPressed: c.disconnect,
          height: height,
        ),
      ],
      if (c.state != HostConnectionState.online)
        HudButton(
          label: 'Demo data',
          icon: Icons.science_outlined,
          accent: theme.vram,
          onPressed: widget.onUseSimulation,
          height: height,
        ),
    ];

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: buttons.length,
        separatorBuilder: (BuildContext context, int index) =>
            SizedBox(width: metrics.px(8)),
        itemBuilder: (BuildContext context, int index) => buttons[index],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // interactions
  // -------------------------------------------------------------------------

  Future<void> _editDeviceName(
    BuildContext context,
    HostConnectionController c,
  ) async {
    final TextEditingController controller =
        TextEditingController(text: c.deviceName);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: context.theme.panel,
          title: Text(
            'Device name',
            style: TextStyle(color: context.theme.text),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 40,
            style: TextStyle(color: context.theme.text),
            decoration: InputDecoration(
              helperText: 'Shown in the PC pairing dialog',
              helperStyle: TextStyle(color: context.theme.muted, fontSize: 11),
              counterStyle: TextStyle(color: context.theme.muted, fontSize: 11),
            ),
            onSubmitted: (String value) =>
                Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (result != null) await c.setDeviceName(result);
  }

  Future<void> _confirmForget(
    BuildContext context,
    HostConnectionController c,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: context.theme.panel,
          title: Text('Forget this PC?', style: TextStyle(color: context.theme.text)),
          content: Text(
            'The pairing secret on this phone is deleted. To reconnect you '
            'will have to approve the device on the PC again.',
            style: TextStyle(color: context.theme.muted),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Forget', style: TextStyle(color: context.theme.hot)),
            ),
          ],
        );
      },
    );
    if (confirmed ?? false) await c.forget();
  }
}

// ---------------------------------------------------------------------------
// radar
// ---------------------------------------------------------------------------

/// The scanner: rings, a rotating sweep and one blip per discovered host.
///
/// The blip position is derived from the host id, so a host keeps its bearing
/// between rebuilds instead of teleporting on every animation frame.
class _RadarPanel extends StatefulWidget {
  const _RadarPanel({required this.connection});

  final HostConnectionController connection;

  @override
  State<_RadarPanel> createState() => _RadarPanelState();
}

class _RadarPanelState extends State<_RadarPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final HostConnectionController c = widget.connection;
    final Color accent = _stateColor(theme, c.state);
    final bool sweeping = c.state == HostConnectionState.scanning;

    return HudPanel(
      radius: metrics.panelRadius,
      accent: accent.withValues(alpha: 0.5),
      cornerCut: metrics.cornerCut,
      padding: EdgeInsets.all(metrics.panelPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'LAN SCAN',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(9.5),
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              HudBadge(
                label: sweeping ? 'SWEEPING' : '${c.hosts.length} FOUND',
                color: accent,
                fontSize: metrics.font(9),
              ),
            ],
          ),
          SizedBox(height: metrics.px(8)),
          Expanded(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                return CustomPaint(
                  painter: _RadarPainter(
                    theme: theme,
                    accent: accent,
                    sweep: sweeping ? _controller.value : null,
                    lock: c.state == HostConnectionState.online,
                    blips: c.hosts
                        .map((DiscoveredHost h) => _blipFor(h, c))
                        .toList(growable: false),
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
          SizedBox(height: metrics.px(8)),
          Text(
            _radarCaption(c),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.muted,
              fontSize: metrics.font(9),
              height: 1.35,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  /// Bearing and range for one host. Both come from the id hash, so the picture
  /// is stable, and a host that is already paired sits on an inner ring to read
  /// as "closer".
  _Blip _blipFor(DiscoveredHost host, HostConnectionController c) {
    int hash = 0;
    for (final int unit in host.endpoint.hostId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    final double angle = (hash % 360) * math.pi / 180.0;
    final bool locked = c.state == HostConnectionState.online &&
        c.pairedHost?.endpoint.hostId == host.endpoint.hostId;
    final double range = locked ? 0.22 : 0.45 + (hash % 45) / 100.0;
    return _Blip(
      angle: angle,
      range: range,
      paired: host.paired,
      locked: locked,
    );
  }

  String _radarCaption(HostConnectionController c) {
    switch (c.state) {
      case HostConnectionState.scanning:
        return 'Broadcasting on the local network. A PC running PCMonitorHost '
            'answers when "LAN pairing" is enabled in its settings.';
      case HostConnectionState.requesting:
        return 'Confirm this device on the PC. Nothing is shared until you do.';
      case HostConnectionState.connecting:
        return 'Opening the telemetry socket and verifying the pairing secret.';
      case HostConnectionState.online:
        return 'Link established. The PC is streaming telemetry.';
      case HostConnectionState.offline:
        return 'The link dropped. Retrying in the background.';
      case HostConnectionState.failed:
        return c.error ?? 'Something went wrong.';
      case HostConnectionState.found:
        return 'Pick a PC below. One you have not paired with will ask its '
            'owner to confirm.';
      case HostConnectionState.idle:
        return 'Press SCAN to look for a PC on this network.';
    }
  }
}

class _Blip {
  const _Blip({
    required this.angle,
    required this.range,
    required this.paired,
    required this.locked,
  });

  final double angle;

  /// 0 = centre, 1 = outer ring.
  final double range;
  final bool paired;
  final bool locked;
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.theme,
    required this.accent,
    required this.sweep,
    required this.lock,
    required this.blips,
  });

  final MonitorTheme theme;
  final Color accent;

  /// 0..1 sweep position, or `null` when the scanner is idle.
  final double? sweep;
  final bool lock;
  final List<_Blip> blips;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2 - 2;
    if (radius <= 2) return;

    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = theme.border.withValues(alpha: 0.9);

    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(centre, radius * i / 4, ring);
    }

    // Cross hairs, drawn faintly so they read as a graticule.
    final Paint axis = Paint()
      ..strokeWidth = 0.6
      ..color = theme.border.withValues(alpha: 0.55);
    canvas.drawLine(Offset(centre.dx - radius, centre.dy),
        Offset(centre.dx + radius, centre.dy), axis);
    canvas.drawLine(Offset(centre.dx, centre.dy - radius),
        Offset(centre.dx, centre.dy + radius), axis);

    if (sweep != null) _paintSweep(canvas, centre, radius, sweep!);

    for (final _Blip blip in blips) {
      final Offset at = Offset(
        centre.dx + math.cos(blip.angle) * radius * blip.range,
        centre.dy + math.sin(blip.angle) * radius * blip.range,
      );
      final Color color = blip.paired ? theme.gpu : theme.hot;
      canvas.drawCircle(
        at,
        blip.locked ? 4.5 : 3.2,
        Paint()
          ..color = color
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawCircle(at, blip.locked ? 2.6 : 1.9, Paint()..color = color);
      if (blip.locked) {
        canvas.drawCircle(
          at,
          8.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color.withValues(alpha: 0.7),
        );
      }
    }

    if (lock) {
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = theme.gpu.withValues(alpha: 0.8),
      );
    }
  }

  /// A trailing wedge plus its leading edge - the classic sweep, cheap enough
  /// to redraw at 60 fps.
  void _paintSweep(Canvas canvas, Offset centre, double radius, double t) {
    final double head = t * 2 * math.pi;
    const double tail = math.pi / 2.6;
    final Rect box = Rect.fromCircle(center: centre, radius: radius);

    canvas.drawArc(
      box,
      head - tail,
      tail,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: head - tail,
          endAngle: head,
          colors: <Color>[
            accent.withValues(alpha: 0.0),
            accent.withValues(alpha: 0.26),
          ],
          transform: GradientRotation(head - tail),
        ).createShader(box),
    );

    canvas.drawLine(
      centre,
      Offset(
        centre.dx + math.cos(head) * radius,
        centre.dy + math.sin(head) * radius,
      ),
      Paint()
        ..strokeWidth = 1.4
        ..color = accent.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) =>
      oldDelegate.sweep != sweep ||
      oldDelegate.lock != lock ||
      oldDelegate.accent != accent ||
      oldDelegate.blips.length != blips.length ||
      oldDelegate.theme.id != theme.id;
}

// ---------------------------------------------------------------------------
// host card
// ---------------------------------------------------------------------------

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.connection,
    required this.onTap,
  });

  final DiscoveredHost host;
  final HostConnectionController connection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;

    final bool isActive = connection.state == HostConnectionState.online &&
        connection.pairedHost?.endpoint.hostId == host.endpoint.hostId;
    final bool awaiting = connection.awaitingConfirmation &&
        connection.pendingHost?.hostId == host.endpoint.hostId;
    final bool paired = host.paired ||
        connection.pairedHost?.endpoint.hostId == host.endpoint.hostId;

    final Color accent = isActive
        ? theme.gpu
        : (paired
            ? theme.vram
            : (host.pairingOpen ? theme.cpu : theme.muted));

    final String action = isActive
        ? 'LINKED'
        : (awaiting
            ? 'WAITING'
            : (paired
                ? 'CONNECT'
                : (host.pairingOpen ? 'PAIR' : 'LOCKED')));

    return HudPanel(
      radius: metrics.panelRadius,
      accent: accent.withValues(alpha: isActive ? 0.85 : 0.5),
      glow: isActive ? 0.8 : 0.0,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.panelPadding,
        vertical: metrics.px(10),
      ),
      onTap: isActive ? null : onTap,
      semanticLabel: '${host.endpoint.hostName}, ${host.endpoint.address}, $action',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          AccentChip(color: accent, width: 3, height: metrics.px(30)),
          SizedBox(width: metrics.px(11)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  host.endpoint.hostName.isEmpty
                      ? 'PC MONITOR HOST'
                      : host.endpoint.hostName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(14),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                SizedBox(height: metrics.px(3)),
                Text(
                  host.endpoint.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(10.5),
                    letterSpacing: 0.8,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                SizedBox(height: metrics.px(5)),
                Row(
                  children: <Widget>[
                    if (paired)
                      HudBadge(
                        label: 'PAIRED',
                        color: theme.vram,
                        fontSize: metrics.font(8.5),
                      )
                    else
                      HudBadge(
                        label: host.pairingOpen
                            ? 'PAIRING OPEN'
                            : 'PAIRING CLOSED',
                        color: host.pairingOpen ? theme.cpu : theme.muted,
                        fontSize: metrics.font(8.5),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: metrics.px(8)),
          if (awaiting)
            SizedBox(
              width: metrics.px(16),
              height: metrics.px(16),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            )
          else
            HudBadge(
              label: action,
              color: accent,
              filled: isActive,
              fontSize: metrics.font(9.5),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// state helpers
// ---------------------------------------------------------------------------

Color _stateColor(MonitorTheme theme, HostConnectionState state) {
  switch (state) {
    case HostConnectionState.online:
      return theme.gpu;
    case HostConnectionState.scanning:
    case HostConnectionState.connecting:
      return theme.cpu;
    case HostConnectionState.requesting:
      return theme.hot;
    case HostConnectionState.offline:
    case HostConnectionState.failed:
      return theme.hot;
    case HostConnectionState.idle:
    case HostConnectionState.found:
      return theme.cpu;
  }
}

String _stateBadge(HostConnectionState state) {
  switch (state) {
    case HostConnectionState.idle:
      return 'IDLE';
    case HostConnectionState.scanning:
      return 'SCANNING';
    case HostConnectionState.found:
      return 'FOUND';
    case HostConnectionState.requesting:
      return 'CONFIRM';
    case HostConnectionState.connecting:
      return 'LINKING';
    case HostConnectionState.online:
      return 'LIVE';
    case HostConnectionState.offline:
      return 'OFFLINE';
    case HostConnectionState.failed:
      return 'ERROR';
  }
}

/// Maps the connection state onto the firmware's vocabulary, so the dashboard
/// status bar keeps saying the same things it always did.
String connectionStatusText(HostConnectionState state, String message) {
  switch (state) {
    case HostConnectionState.idle:
      return 'No PC paired';
    case HostConnectionState.scanning:
      return 'Looking for PC';
    case HostConnectionState.found:
      return 'PC found';
    case HostConnectionState.requesting:
      return 'Awaiting confirmation';
    case HostConnectionState.connecting:
      return 'Connecting PC';
    case HostConnectionState.online:
      return message.isEmpty ? 'Connected' : message;
    case HostConnectionState.offline:
      return 'PC Offline';
    case HostConnectionState.failed:
      return message.isEmpty ? 'Error' : message;
  }
}

ConnectionKind connectionKindFor(HostConnectionState state) {
  switch (state) {
    case HostConnectionState.online:
      return ConnectionKind.live;
    case HostConnectionState.offline:
      return ConnectionKind.stale;
    case HostConnectionState.scanning:
    case HostConnectionState.found:
    case HostConnectionState.requesting:
    case HostConnectionState.connecting:
    case HostConnectionState.idle:
    case HostConnectionState.failed:
      return ConnectionKind.waiting;
  }
}
