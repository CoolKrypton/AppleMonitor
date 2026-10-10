import 'package:flutter/material.dart';

import '../models/device_state.dart';
import '../responsive/responsive.dart';
import '../services/host_connection.dart';
import '../services/monitor_provider.dart';
import '../theme/monitor_theme.dart';
import '../theme/theme_context.dart';
import '../util/format.dart';
import '../widgets/hud.dart';
import '../widgets/theme_picker_sheet.dart';
import 'cpu_detail_screen.dart';
import 'dashboard_screen.dart';
import 'disk_detail_screen.dart';
import 'gpu_detail_screen.dart';
import 'host_connect_screen.dart';

/// The navigation shell. Owns the state machine ported from `ui_app.c`:
///
/// ```
/// Hosts --link up--> Dashboard --tap CPU-->  CPU Detail     --HOME--> Dashboard
///                              --tap GPU-->  GPU Selector    --HOME--> Dashboard
///                                             |--tap card--> GPU Detail  --DEVICES--> GPU Selector
///                              --tap DISK--> Disk Detail    --HOME--> Dashboard
/// ```
///
/// Two firmware subtleties are preserved:
/// * when the host reports exactly **one** adapter, tapping the GPU card skips
///   the selector and lands directly on that adapter's detail page;
/// * choosing an adapter in the selector simultaneously promotes it to the
///   dashboard adapter *and* opens its detail page.
///
/// The hosts page replaces firmware's USB provisioning: it is where a phone
/// finds and pairs with a PC.
class MonitorShell extends StatefulWidget {
  const MonitorShell({
    super.key,
    required this.provider,
    required this.connection,
    this.startOnHosts = false,
  });

  final MonitorProvider provider;
  final HostConnectionController connection;

  /// Open the discovery page instead of the dashboard on first build.
  final bool startOnHosts;

  @override
  State<MonitorShell> createState() => _MonitorShellState();
}

enum _Page { hosts, dashboard, cpu, gpuSelector, gpuDetail, disks }

class _MonitorShellState extends State<MonitorShell> {
  late _Page _page =
      widget.startOnHosts ? _Page.hosts : _Page.dashboard;

  @override
  void initState() {
    super.initState();
    widget.connection.addListener(_onConnectionChanged);
  }

  @override
  void dispose() {
    widget.connection.removeListener(_onConnectionChanged);
    super.dispose();
  }

  /// The moment the link comes up, the data is what the user came for - so the
  /// hosts page hands over on its own. Staying put would leave them staring at
  /// a scanner that has already found what it was looking for.
  void _onConnectionChanged() {
    if (!mounted) return;
    if (widget.connection.isOnline && _page == _Page.hosts) {
      widget.provider.useSimulation(false);
      setState(() => _page = _Page.dashboard);
    }
  }

  void _go(_Page page) => setState(() => _page = page);

  void _openHosts() => _go(_Page.hosts);

  void _openCpu() => _go(_Page.cpu);

  void _openDisks() => _go(_Page.disks);

  void _openGpus() {
    // Single-adapter shortcut, straight from `ui_app_show_gpus()`.
    final int? direct = widget.provider.singleGpuShortcut();
    if (direct != null) {
      widget.provider.openGpuAt(direct);
      _go(_Page.gpuDetail);
      return;
    }
    _go(_Page.gpuSelector);
  }

  void _chooseGpu(int index) {
    // One tap: promote to dashboard adapter AND open the detail page.
    widget.provider.chooseGpu(index);
    _go(_Page.gpuDetail);
  }

  void _home() {
    widget.provider.clearOpenGpu();
    _go(_Page.dashboard);
  }

  /// Leaves the demo stream and returns to the dashboard on live data.
  void _useLiveData() {
    widget.provider.useSimulation(false);
    _go(_Page.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.02),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<_Page>(_page),
        child: _buildPage(),
      ),
    );
  }

  Widget _buildPage() {
    switch (_page) {
      case _Page.hosts:
        return HostConnectScreen(
          connection: widget.connection,
          onOpenDashboard: _useLiveData,
          onUseSimulation: () {
            widget.provider.useSimulation(true);
            _go(_Page.dashboard);
          },
        );
      case _Page.dashboard:
        return DashboardScreen(
          provider: widget.provider,
          onOpenCpu: _openCpu,
          onOpenGpus: _openGpus,
          onOpenDisks: _openDisks,
          onOpenHosts: _openHosts,
        );
      case _Page.cpu:
        return CpuDetailScreen(
          provider: widget.provider,
          onHome: _home,
        );
      case _Page.gpuSelector:
        return GpuSelectorScreen(
          provider: widget.provider,
          onHome: _home,
          onChoose: _chooseGpu,
        );
      case _Page.gpuDetail:
        return GpuDetailScreen(
          provider: widget.provider,
          onHome: _home,
          onBackToDevices: _openGpus,
        );
      case _Page.disks:
        return DiskDetailScreen(
          provider: widget.provider,
          onHome: _home,
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Shared dashboard pieces
// ---------------------------------------------------------------------------

/// The status / theme / clock strip that sits at the top of the dashboard.
///
/// The connection pill doubles as the entry point to the hosts page: it is the
/// one element that always exists and always reflects the link, so tapping it
/// is the natural way to fix a link that is not there yet.
class DashboardStatusBar extends StatelessWidget {
  const DashboardStatusBar({
    super.key,
    required this.provider,
    required this.onOpenHosts,
  });

  final MonitorProvider provider;
  final VoidCallback onOpenHosts;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    final ClockFields clock = clockFields(DateTime.now());

    final Color badgeColor = switch (provider.connectionKind) {
      ConnectionKind.simulated => theme.gpu,
      ConnectionKind.live => theme.gpu,
      ConnectionKind.stale => theme.hot,
      ConnectionKind.waiting => theme.hot,
    };

    return HudPanel(
      radius: metrics.panelRadius,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.px(12),
        vertical: metrics.px(9),
      ),
      accent: badgeColor.withValues(alpha: 0.55),
      child: Row(
        children: <Widget>[
          StatusDot(color: badgeColor, size: metrics.px(7)),
          SizedBox(width: metrics.px(8)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  provider.statusText.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.text,
                    fontSize: metrics.font(11),
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                SizedBox(height: metrics.px(2)),
                Text(
                  clock.valid
                      ? '${clock.date}  ${clock.weekday}'
                      : Ph.date,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.muted,
                    fontSize: metrics.font(9),
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: metrics.px(8)),
          _ClockReadout(clock: clock, fontSize: metrics.font(20)),
          SizedBox(width: metrics.px(8)),
          Tooltip(
            message: 'Hosts and pairing',
            child: InkWell(
              onTap: onOpenHosts,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: EdgeInsets.all(metrics.px(3)),
                child: HudBadge(label: provider.connectionLabel, color: badgeColor),
              ),
            ),
          ),
          SizedBox(width: metrics.px(6)),
          _ThemeButton(provider: provider),
        ],
      ),
    );
  }
}

class _ClockReadout extends StatelessWidget {
  const _ClockReadout({required this.clock, required this.fontSize});

  final ClockFields clock;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final TextStyle digitStyle = TextStyle(
      color: theme.text,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      height: 1.0,
    );
    final TextStyle colonStyle = TextStyle(
      color: theme.muted,
      fontSize: fontSize * 0.9,
      fontWeight: FontWeight.w700,
      height: 1.0,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(clock.hours, style: digitStyle),
        Text(':', style: colonStyle),
        Text(clock.minutes, style: digitStyle),
        Text(':', style: colonStyle),
        Text(
          clock.seconds,
          style: digitStyle.copyWith(
            color: theme.cpu,
            fontSize: fontSize * 0.72,
          ),
        ),
      ],
    );
  }
}

class _ThemeButton extends StatelessWidget {
  const _ThemeButton({required this.provider});

  final MonitorProvider provider;

  @override
  Widget build(BuildContext context) {
    final MonitorTheme theme = context.theme;
    final LayoutMetrics metrics = context.layout;
    return Tooltip(
      message: 'Interface theme',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => ThemePickerSheet.show(context),
        child: Padding(
          padding: EdgeInsets.all(metrics.px(4)),
          child: Icon(Icons.palette_outlined, color: theme.cpu, size: metrics.px(17)),
        ),
      ),
    );
  }
}
