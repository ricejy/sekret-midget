import Flutter
import UIKit
import LocalAuthentication

class SceneDelegate: FlutterSceneDelegate {
  private var privacyWindow: UIWindow?

  override func sceneWillResignActive(_ scene: UIScene) {
    // Native and synchronous: do not wait for a Flutter frame before snapshotting.
    if let windowScene = scene as? UIWindowScene, privacyWindow == nil {
      let cover = UIWindow(windowScene: windowScene)
      cover.frame = windowScene.coordinateSpace.bounds
      cover.windowLevel = .alert + 1
      let controller = UIViewController()
      controller.view.backgroundColor = .systemBackground
      let label = UILabel()
      label.text = "Sekret"
      label.textColor = .label
      label.font = .preferredFont(forTextStyle: .title1)
      label.translatesAutoresizingMaskIntoConstraints = false
      controller.view.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
      ])
      cover.rootViewController = controller
      cover.isHidden = false
      privacyWindow = cover
    }
    super.sceneWillResignActive(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyWindow?.isHidden = true
    privacyWindow = nil
  }
}

/// Kept with the scene security boundary; no model dependency or content input.
final class DeviceProtectionPlugin: NSObject, FlutterPlugin {
  static let authenticationPolicy = LAPolicy.deviceOwnerAuthentication
  private var context: LAContext?
  private var backgroundObserver: NSObjectProtocol?

  override init() {
    super.init()
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.context?.invalidate() }
  }

  deinit {
    context?.invalidate()
    if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.addMethodCallDelegate(DeviceProtectionPlugin(), channel: FlutterMethodChannel(
      name: "com.ricejy.sekret_midget/protection", binaryMessenger: registrar.messenger()
    ))
  }

  static func diagnostics() -> [String: String] {
    let probe = LAContext()
    let available = probe.canEvaluatePolicy(authenticationPolicy, error: nil)
    let kind: String
    switch probe.biometryType {
    case .faceID: kind = "Face ID or device passcode"
    case .touchID: kind = "Touch ID or device passcode"
    default: kind = "Device passcode"
    }
    return [
      "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
      "os": "iOS \(UIDevice.current.systemVersion)",
      "authentication": available ? kind : "Unavailable — set a device passcode in iOS Settings"
    ]
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "diagnostics": result(Self.diagnostics())
    case "purgeImportCopies":
      do {
        try Self.purgeImportCopies(in: Self.importRoots)
        result(nil)
      } catch { result(FlutterError(code: "cleanup_failed", message: "Could not remove import copies.", details: nil)) }
    case "discardImportCopy":
      guard let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String else {
        result(FlutterError(code: "invalid_input", message: "Missing import path.", details: nil))
        return
      }
      do {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // Never remove a provider's original. Only picker-owned sandbox copies.
        if try Self.importDirectories(in: Self.importRoots).contains(where: { Self.isInside(file, directory: $0) }) {
          try FileManager.default.removeItem(at: file)
        }
        result(nil)
      } catch { result(FlutterError(code: "cleanup_failed", message: "Could not remove import copy.", details: nil)) }
    case "authenticate":
      guard context == nil, UIApplication.shared.applicationState == .active else {
        result(false)
        return
      }
      let request = LAContext()
      request.localizedCancelTitle = "Cancel"
      guard request.canEvaluatePolicy(Self.authenticationPolicy, error: nil) else {
        result(false)
        return
      }
      context = request
      request.evaluatePolicy(Self.authenticationPolicy,
        localizedReason: "Authenticate to access or change your private Sekret data.") { [weak self] success, _ in
        DispatchQueue.main.async {
          self?.context = nil
          request.invalidate()
          result(success)
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  static func isInside(_ file: URL, directory: URL) -> Bool {
    file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
  }

  private static var importRoots: [URL] {
    let manager = FileManager.default
    return [manager.temporaryDirectory,
      manager.urls(for: .documentDirectory, in: .userDomainMask)[0]]
  }

  static func purgeImportCopies(in roots: [URL]) throws {
    for directory in try importDirectories(in: roots) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  private static func importDirectories(in roots: [URL]) throws -> [URL] {
    let manager = FileManager.default
    return try roots.flatMap { root -> [URL] in
      try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
        ($0.lastPathComponent == "Inbox" || $0.lastPathComponent.hasSuffix("-Inbox")) &&
          Self.isInside($0, directory: root) &&
          (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false &&
          (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
    }
  }

}
