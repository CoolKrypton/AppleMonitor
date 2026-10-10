import Flutter
import Network
import UIKit

/// The UI is entirely Dart-side; mirroring `MainActivity.kt`, the only platform
/// work done here is:
///
///  * keeping the screen on for as long as the app is in the foreground - the
///    phone is a glanceable PC readout, a dozing screen defeats it;
///  * answering a `pcmonitor/device` channel with the device's own name, which
///    becomes the default "THIS DEVICE" identity shown to the host during
///    pairing.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  /// Must match `HostConnectionController._deviceChannel` in Dart.
  private static let deviceChannelName = "pcmonitor/device"

  /// Held for the life of the process.
  ///
  /// `FlutterMethodChannel` deliberately registers its handler through a block
  /// that captures the codec rather than the channel itself, so nothing else
  /// keeps the channel alive. Retaining it here is the same thing every Flutter
  /// plugin does, and it keeps the channel's identity stable if it is ever
  /// needed again.
  private var deviceChannel: FlutterMethodChannel?

  /// A retained, short-lived Bonjour browse used solely to make iOS perform
  /// its Local Network privacy decision before Dart opens the UDP socket.
  ///
  /// `NSLocalNetworkUsageDescription` describes the permission but does not
  /// itself request it. On some iOS releases a raw BSD UDP socket can be
  /// silently filtered without causing the prompt to appear. NWBrowser is the
  /// system-supported trigger for that decision. It does not replace our UDP
  /// discovery protocol, and the host does not need to publish this service.
  private var localNetworkPermissionBrowser: NWBrowser?
  private var didStartLocalNetworkPermissionProbe = false
  private static let localNetworkServiceType = "_pcmonitor._udp"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // The iOS counterpart of `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`.
    // Unlike Android this needs no permission, but the idle timer is reset by
    // the system whenever the app leaves the foreground, so it is re-asserted
    // on every activation below.
    application.isIdleTimerDisabled = true
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    application.isIdleTimerDisabled = true
    super.applicationDidBecomeActive(application)
    // iOS denies an undetermined local-network request made in the background
    // without displaying its alert. This lifecycle callback is the first
    // foreground-safe point at which to ask.
    requestLocalNetworkPermission()
  }

  /// Starts a system-managed local-network preflight exactly once. A ready
  /// browser means the permission gate is open; a failed browser means iOS has
  /// completed the decision (for example, the user denied it). In either case
  /// it is immediately released, so it has no ongoing network cost and cannot
  /// alter the application's discovery or pairing behaviour.
  private func requestLocalNetworkPermission() {
    guard !didStartLocalNetworkPermissionProbe else { return }
    didStartLocalNetworkPermissionProbe = true

    let browser = NWBrowser(
      for: .bonjour(type: AppDelegate.localNetworkServiceType, domain: nil),
      using: .udp
    )
    localNetworkPermissionBrowser = browser
    browser.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready, .failed(_):
        browser.cancel()
        self?.localNetworkPermissionBrowser = nil
      default:
        break
      }
    }
    browser.start(queue: .main)
    // A disconnected phone can remain in `.waiting`; browsing is only a
    // permission trigger, never a long-running discovery channel.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self, self.localNetworkPermissionBrowser === browser else {
        return
      }
      browser.cancel()
      self.localNetworkPermissionBrowser = nil
    }
  }

  /// With the `UISceneDelegate` lifecycle the engine is created implicitly, so
  /// plugins and application-level channels are registered here rather than in
  /// `didFinishLaunching`.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: AppDelegate.deviceChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "deviceName":
        result(AppDelegate.deviceName())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    deviceChannel = channel
  }

  /// The iOS counterpart of `MainActivity.deviceName()`.
  ///
  /// `UIDevice.name` used to be the whole story, but since iOS 16 it returns a
  /// generic product name ("iPhone", "iPad") unless the app holds Apple's
  /// `com.apple.developer.device-information.user-assigned-device-name`
  /// entitlement - which is granted per app on request and is out of reach for
  /// a free developer account.
  ///
  /// The Bonjour hostname is the way back in. iOS derives it from the same
  /// user-assigned name and, unlike `UIDevice.name`, does not gate it behind
  /// that entitlement: a device named "Alice's iPhone" advertises itself as
  /// `Alices-iPhone.local`. Undo the two transformations the OS applies and
  /// the original name falls out.
  private static func deviceName() -> String {
    let uiName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)

    var host = ProcessInfo.processInfo.hostName
    if host.hasSuffix(".local") { host.removeLast(6) }
    // A name collision on the network makes Bonjour append "-2", "-3", ...
    if let suffix = host.range(of: #"-\d+$"#, options: .regularExpression) {
      host.removeSubrange(suffix)
    }
    host = host.replacingOccurrences(of: "-", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let model = UIDevice.current.model.trimmingCharacters(in: .whitespacesAndNewlines)

    // Order matters: the hostname is the only one of the three that still
    // carries the user-assigned name on iOS 16+.
    for candidate in [host, uiName, model] where isSpecific(candidate) {
      return candidate
    }
    return model.isEmpty ? "iOS device" : model
  }

  /// Rejects the generic product names iOS hands out when it is withholding
  /// the user-assigned name - "iPhone" identifies nothing in a pairing dialog.
  private static func isSpecific(_ name: String) -> Bool {
    guard name.count >= 2 else { return false }
    return !genericNames.contains(name.lowercased())
  }

  private static let genericNames: Set<String> = [
    "iphone", "ipad", "ipod touch", "apple tv", "localhost", "ios device",
  ]
}
