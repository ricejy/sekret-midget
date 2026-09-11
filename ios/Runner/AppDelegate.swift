import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if #available(iOS 14.0, *),
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhotosPickerPlugin") {
      PhotosPickerPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceProtectionPlugin") {
      DeviceProtectionPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AppleEmbeddingPlugin"
    ) {
      AppleEmbeddingPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AppleFoundationModelsPlugin"
    ) {
      AppleFoundationModelsPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AppleVisionOcrPlugin"
    ) {
      AppleVisionOcrPlugin.register(with: registrar)
    }
  }
}

/// Selection-scoped system Photos UI. It does not request full library access,
/// inspect other assets, or persist temporary copies in the app sandbox.
@available(iOS 14.0, *)
final class PhotosPickerPlugin: NSObject, FlutterPlugin, PHPickerViewControllerDelegate,
  UIAdaptivePresentationControllerDelegate {
  private let viewController: () -> UIViewController?
  private var pending: FlutterResult?

  init(viewController: @escaping () -> UIViewController?) {
    self.viewController = viewController
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = PhotosPickerPlugin(viewController: { registrar.viewController })
    registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(
      name: "com.ricejy.sekret_midget/photos", binaryMessenger: registrar.messenger()
    ))
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pickImage" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pending == nil, UIApplication.shared.applicationState == .active,
      var presenter = viewController(), presenter.view.window != nil else {
      result(FlutterError(code: "picker_unavailable", message: "Return to Sekret and try again.", details: nil))
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    guard !presenter.isBeingDismissed else {
      result(FlutterError(code: "picker_unavailable", message: "Try opening Photos again.", details: nil))
      return
    }
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    pending = result
    presenter.present(picker, animated: true)
    picker.presentationController?.delegate = self
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true) { [self] in
      guard let provider = results.first?.itemProvider else {
        finish(nil)
        return
      }
      guard let type = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      }) else {
        finish(FlutterError(code: "photo_unavailable", message: "The selected photograph could not be read.", details: nil))
        return
      }
      let basename = URL(fileURLWithPath: provider.suggestedName ?? "Photograph")
        .deletingPathExtension().lastPathComponent
      let name = "\(basename).\(UTType(type)?.preferredFilenameExtension ?? "jpg")"
      provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
        DispatchQueue.main.async {
          guard let data, !data.isEmpty else {
            self?.finish(FlutterError(code: "photo_unavailable", message: "The selected photograph could not be read.", details: nil))
            return
          }
          self?.finish(["name": name, "bytes": FlutterStandardTypedData(bytes: data)])
        }
      }
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(nil)
  }

  private func finish(_ value: Any?) {
    let completion = pending
    pending = nil
    completion?(value)
  }
}
