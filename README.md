# AppleMonitor — iOS client

iOS build of the PCMonitor client. The Dart sources under `lib/` are shared 1:1
with [`../AndroidMonitor`](../AndroidMonitor); the platform work lives in `ios/`
and is limited to five service files.

**Start here → [README-iOS.md](README-iOS.md)** for the build steps on macOS,
the list of iOS adaptations, and the local-network / broadcast permission story.

Everything below describes the UI and the protocol, which are identical on both
platforms.

---

**PCMonitorHost** client — a 1:1 port of the ESP32 firmware's UI
(`PCMonitorFirmware`), plus the networking the firmware got for free from USB:
the phone discovers the PC on the LAN, pairs with it, and then streams the same
`telemetry.snapshot` feed over a WebSocket.

The whole protocol stack is in-tree: the only runtime dependency beyond Flutter
itself is `shared_preferences` (the pairing store). Sockets, the RFC 6455
client, SHA-256/HMAC and the JSON envelope are all hand-written, because the
app speaks exactly one protocol to exactly one kind of peer.

```
lib/
  main.dart                      app entry, theme + provider wiring
  models/
    pc_status.dart               PCStatus mirror (validity flags preserved)
    device_state.dart            13-state set, connection classification
  responsive/
    responsive.dart              screen classes, layout variants, metrics
  screens/
    monitor_shell.dart           navigation state machine + command bar
    dashboard_screen.dart        dashboard (CPU / GPU / RAM / I/O cards)
    cpu_detail_screen.dart       package block + per-core list
    gpu_detail_screen.dart       adapter picker + engine detail
    disk_detail_screen.dart      drive detail + throughput graphs
    host_connect_screen.dart     host discovery / pairing / link page
  services/
    protocol.dart                envelope V1 codec + payload validation
    monitor_provider.dart        sample pump, 60 s history, GPU selection
    display_smoother.dart        20 Hz bar easing (display_smoother.c port)
    smoothing_config.dart        tau / threshold table, 1:1 with the firmware
    gpu_selection_service.dart   adapter choice, keyed by protocol id
    mock_data_source.dart        pc_simulator.c + mock_data.c ports (offline)
    host_discovery_service.dart  discovery.probe → discovery.offer (UDP 8766)
    host_connection.dart         the connection state machine (8 states)
    host_link.dart               WebSocket session: handshake + telemetry
    pairing_crypto.dart          HMAC-SHA256 proof / verification
    pairing_store.dart           persisted secret + device identity
    ws_client.dart               hand-rolled RFC 6455 client
  theme/
    monitor_theme.dart           6 theme definitions
    theme_context.dart           `context.theme`, `context.layout` helpers
  util/
    format.dart                  every firmware formatter, incl. placeholders
  widgets/
    hud.dart                     HUD panel, chamfer, bars, badges, background
    sparkline.dart               60-point history graph (null = gap)
    monitor_scaffold.dart        command bar + side rail
    theme_picker_sheet.dart      theme switcher
test/
  logic_test.dart                firmware-parity behaviour tests
  widget_smoke_test.dart         boot + layout + theme smoke tests
```

## Running it

```bash
flutter pub get
flutter run
```

Targets Android (minSdk 21). `MainActivity` declares a full `configChanges` set
so rotation re-lays-out instead of recreating the activity. The manifest asks
for `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` and
`CHANGE_WIFI_MULTICAST_STATE` — the last two only so the app can hold a
multicast lock while it listens for a host's UDP reply. No location, no
storage, no contacts.

## Connecting to a PC

A phone has no USB provisioning path, so the app *is* its own provisioning
flow. The **HOST LINK** page walks through it:

1. **Scan** — the app broadcasts `discovery.probe` on UDP 8766. A PC running
   PCMonitorHost with *LAN pairing* enabled answers with a unicast
   `discovery.offer` (name, address, whether pairing is open). Hosts are drawn
   on a radar; bearing and range come from a hash of the host id, so a PC keeps
   its place between repaints, and the paired one sits on the inner ring.
2. **Pair** — tapping an unknown PC sends `pairing.request`; the PC pops a
   confirmation dialog and the card shows a spinner until its owner decides.
   On `pairing.grant` the 32-byte secret is written to the store and the
   socket opens.
3. **Link** — a remembered PC reconnects on its own: WebSocket to `/ws`, then
   `pairing.challenge` → `pairing.authenticate` (HMAC proof) →
   `pairing.auth.result` → `device.status` → a `telemetry.snapshot` stream.
   Losing the link drops to *offline* and retries in the background.

The connection controller is a plain 8-state machine — `idle, scanning, found,
requesting, connecting, online, offline, failed` — and `Forget` is the only
thing that touches the stored secret. `Forget` and `Reconnect` are gated on the
*stored* secret rather than on the live link, so they stay available while a
scan is running; the `Scan` button, by contrast, is disabled while a scan or a
connection attempt is in flight (the controller's own `scan()` is re-entrant and
simply restarts the window).

Anything that would silently corrupt the session fails loudly instead: a
`discovery.offer` whose hostId matches nobody is ignored, a WebSocket peer that
answers with a different hostId is refused (*"A different host answered on this
address"*), a bad secret surfaces as *"The PC rejected this device"*.

## Browser preview (no Flutter SDK needed)

`preview/ui_preview.html` is a self-contained HTML/JS replica of this UI — same
theme values, same breakpoints, same navigation state machine, same mock-data
curves — for reviewing the design without building the app. Open it in any
browser, or from the WorkBuddy preview panel.

* the toolbar switches viewport presets (480×480, 800×480, phone/tablet
  portrait & landscape) or a custom size, and toggles orientation;
* the palette buttons (or the palette icon inside the status bar, keys `1`–`6`)
  switch themes;
* click the CPU / GPU / DISK cards to walk the navigation state machine;
* **主机连接 → 连接页** opens the HOST LINK page, and its dropdown right there
  drives the eight connection states (`scanning / 无主机` being the empty-list
  case) so every state can be reviewed without waiting for a real PC;
* "隐藏传感器" demos the placeholder path, the 链路 selector demos the
  SIM / LIVE / STALE / WAIT badges;
* deep link with a hash, e.g. `#p=gpuDetail&vp=800x480&t=amber_terminal` or
  `#p=hosts&hs=requesting&host=0`.

It is a review artefact, not a port target — the Dart sources under `lib/` stay
authoritative. `preview/_harness.js` re-runs a headless self-check of the
prototype's logic (`node _harness.js`), covering every viewport, all eight
connection states, the state machine's transitions, the radar's determinism
and all six themes.

Headless captures of the HOST LINK page live in
`../.workbuddy/tmp/shots5/` (`p_*` portrait phone, `l_*` landscape,
`tp_*` / `tl_*` tablet, `sq_*` / `wide_*` the firmware-reference sizes).

## Navigation

Identical to the firmware's `ui_app.c` state machine, plus one page the firmware
never needed:

```
Dashboard ──tap CPU ─────▶ CPU Detail ──HOME─▶ Dashboard
          ──tap GPU ─────▶ GPU Selector ──tap card─▶ GPU Detail ──HOME─▶ Dashboard
          ──tap DISK ────▶ Disk Detail ──HOME─▶ Dashboard
          ──tap status badge ─▶ HOST LINK ──Dashboard / Demo data─▶ Dashboard
```

The HOST LINK page hangs off the **connection-status badge** in the command bar
(the one that reads SIM / LIVE / STALE / WAIT — it carries the tooltip *Hosts
and pairing*). It is a leaf: `Dashboard` returns to live telemetry, `Demo data`
returns to the offline simulation.

One firmware subtlety is preserved: **when the host reports exactly one GPU, the
dashboard GPU card goes straight to that GPU's detail page**, skipping the
selector. Picking a card in the selector does two things at once — it promotes
the adapter to the dashboard card *and* opens the detail page.

## Firmware parity rules that are load-bearing

These were carried over deliberately; please keep them if you extend the UI.

- **Validity flags, never inferred values.** Every sensor has its own `*Valid`
  flag. `false` renders the placeholder (`--%`, `-- C`, `-- W`, `-- GHz`,
  `-- GiB`, `--`) — never `0`, and never a value derived from a different sensor.
- **GPU identity is `protocolId`.** Never index into `gpus[]` to identify an
  adapter. `findGpu('')` intentionally never matches.
- **60 s history is a fixed window.** `kDashboardHistoryPoints == 60`; a `null`
  slot renders as a gap, matching `LV_CHART_POINT_NONE`. Switching adapters
  clears the history.
- **Two update cadences.** Text and graphs follow the host sample rate; the bars
  ease at 20 Hz through `DisplaySmoother`, so they stay smooth between samples.
- **Temperature alarm at 85 °C** (`isHot`), and only when the reading is valid.
- **Rate formatting** walks B/s → KB/s → MB/s → GB/s with the firmware's exact
  thresholds, and returns `--` for non-finite input.

## Responsive behaviour

Short-side breakpoints classify the screen as compact / phone / tablet /
large-tablet, and each class (combined with orientation) maps to a layout
variant. A single `scale` factor derived from the short side multiplies every
padding, radius and font size, so the 480×480 firmware layout and a 1280×800
tablet are the same design at different densities.

Layout decisions are driven purely by the **window size** in logical pixels —
no device-model sniffing, no permissions. That is the correct signal for
layout: split-screen, foldables and free-form windows all resolve naturally.

Filling the rectangle is a first-class rule:

- **The dashboard never scrolls.** Landscape uses the firmware's grid; portrait
  stacks the two processor cards, the clock band, and pairs RAM/VRAM and
  NETWORK/DISK side by side so the column fits. The clock band is exactly as
  wide as the processor cards and exactly as tall as one memory tile. If the
  viewport is shorter than the column's design height, the whole thing (fonts
  included) compresses instead of scrolling, so the rectangle is always filled
  exactly.
- **Disk / GPU card grids** distribute the spare height across rows (bounded),
  centring themselves when they are still shorter than the viewport.
- **Clock digits** are sized from the card's available width — and, on the
  portrait band, from the height left over after the date line — so the clock
  always spans its cell. A year / month / day line with the weekday pinned to
  the trailing edge leads the readout, and every digit of `HH:MM:SS`, seconds
  included, shares one size.
- **Processor cards** print the CPU/GPU model beside the big percentage — the
  card's largest dead band — instead of hiding it in a small corner caption, so
  the model is the most prominent secondary string on the card.
- **GPU device list** draws one 60 s load curve per adapter, filling what used
  to be empty space in the tall cards. Every window is independent: switching
  the dashboard adapter never resets another card's curve.
- **Summary blocks** on the CPU/GPU detail pages pick their column count from
  the available *width*, so a landscape phone lays five metrics out in one row
  instead of two cramped ones.

## Themes

Six are built in, switchable from the command bar on any page:

| Theme | Description |
| --- | --- |
| Firmware Dark | The original ESP32 palette, unchanged — the default |
| Neon Pulse | Cyan and magenta on deep indigo |
| Amber CRT | Warm phosphor terminal with soft bloom |
| Cryo Blue | Cold clinical blues with crisp edges |
| Matrix | Monochrome green terminal aesthetic |
| Daylight | Light surfaces with dark text for bright rooms |

The semantic channel colours (CPU / GPU / RAM / VRAM / hot / danger) keep their
meaning in every theme; only surfaces, borders, glow and background motifs vary.

## Tests

```bash
flutter test
```

`logic_test.dart` covers the formatters, validity handling, GPU lookup, busiest-
engine selection and unit conversion. `widget_smoke_test.dart` boots the real
app at five viewport shapes and asserts the layout engine's classification,
scaling and clamping.

The networking layer is checked by two out-of-tree harnesses that need no
Flutter SDK, only `dart` (run them from this directory — the
`.workbuddy/` tooling sits one level up, in the repository root):

```bash
dart ../.workbuddy/tmp/crypto_check.dart                      # proofs, nonces, replay guards
dart ../.workbuddy/tmp/link_check.dart                        # discovery → pairing → telemetry
dart ../.workbuddy/analyzer/bin/check_app.dart . --all        # static analysis
```

`link_check.dart` drives a faithful fake host (`../.workbuddy/tmp/fake_ws_host.dart`)
that enforces the same upgrade rules as `WebSocketHostTransport`, and asserts
the upgrade headers, the whole handshake, `seq` ordering, requestId echoing,
fragment reassembly, ping→pong, and the four refusal paths (Origin, wrong
secret, recycled address, unreachable host).

## Not yet implemented

- **No build has been run.** There is no Flutter/Dart SDK or Android SDK on the
  machine this was written on, so `flutter pub get` / `flutter run` are
  unverified — the Dart is checked by the analyzer and the harnesses above, not
  by a compiler.
- **The `pubspec.yaml` font block is still commented out**, so the clock and
  the numeric readouts fall back to the platform default rather than the
  intended condensed face.
- **Bar smoothing is Dart-side.** The firmware eases bar geometry in C at 20 Hz;
  here `DisplaySmoother` does the same job in Dart. Same time constants, same
  behaviour — just not a native implementation.
- **No settings persistence beyond the pairing secret** — brightness, theme and
  the chosen adapter are session-scoped.
- **The host side is unmodified.** LAN pairing requires *Allow LAN pairing* to be
  switched on in PCMonitorHost; the app cannot enable it remotely, by design.
