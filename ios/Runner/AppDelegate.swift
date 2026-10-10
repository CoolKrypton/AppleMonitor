import Flutter
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
  /// `UIDevice.name` is the user-visible device name the host dialog should
  /// show. Since iOS 16 it returns a generic model name ("iPhone", "iPad")
  /// unless the app also holds Apple's
  /// `com.apple.developer.device-information.user-assigned-device-name`
  /// entitlement - which is fine: a generic model is still a far better label
  /// than the synthetic fallback, and the Dart side treats an empty answer as
  /// "no platform name available" rather than as a name.
  private static func deviceName() -> String {
    let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    let model = UIDevice.current.model.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.isEmpty ? "iOS device" : model
  }
}
