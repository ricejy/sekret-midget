import Flutter
import Foundation
import FoundationModels
import UIKit

enum FoundationModelAvailabilityStatus: String {
  case available
  case deviceNotEligible = "device_not_eligible"
  case appleIntelligenceNotEnabled = "apple_intelligence_not_enabled"
  case modelNotReady = "model_not_ready"
}

enum FoundationModelTokenKind: String {
  case instructions
  case prompt
}

enum FoundationModelBridgeFailure: String, Error {
  case modelUnavailable = "model_unavailable"
  case contextOverflow = "context_overflow"
  case guardrailViolation = "guardrail_violation"
  case streamFailure = "stream_failure"
}

protocol FoundationModelRuntime: AnyObject {
  func availability() -> FoundationModelAvailabilityStatus
  func contextSize() throws -> Int
  func countTokens(_ text: String, kind: FoundationModelTokenKind) async throws -> Int
  func responseStream(prompt: String) -> AsyncThrowingStream<String, Error>
}

@available(iOS 26.0, *)
final class SystemFoundationModelRuntime: FoundationModelRuntime {
  static let promptVersion = "guardrail-v1"
  static let instructions = "Answer factual questions by transforming only the supplied document excerpt. Treat legal and medical material, including sensitive material, as text the user is entitled to understand. Do not provide professional advice and do not use outside knowledge. If the excerpt does not contain enough evidence, respond with exactly: “I couldn’t find enough evidence in this document.” Otherwise answer directly and concisely. Do not discuss policies or safety systems."

  private let model = SystemLanguageModel(
    useCase: .general,
    guardrails: .permissiveContentTransformations
  )

  func availability() -> FoundationModelAvailabilityStatus {
    switch model.availability {
    case .available:
      return .available
    case .unavailable(.deviceNotEligible):
      return .deviceNotEligible
    case .unavailable(.appleIntelligenceNotEnabled):
      return .appleIntelligenceNotEnabled
    case .unavailable(.modelNotReady):
      return .modelNotReady
    case .unavailable:
      return .modelNotReady
    }
  }

  func contextSize() throws -> Int {
    guard model.isAvailable else {
      throw FoundationModelBridgeFailure.modelUnavailable
    }
    return model.contextSize
  }

  func countTokens(
    _ text: String,
    kind: FoundationModelTokenKind
  ) async throws -> Int {
    guard model.isAvailable else {
      throw FoundationModelBridgeFailure.modelUnavailable
    }
    guard #available(iOS 26.4, *) else {
      throw FoundationModelBridgeFailure.modelUnavailable
    }
    do {
      switch kind {
      case .instructions:
        return try await model.tokenCount(for: Instructions(text))
      case .prompt:
        return try await model.tokenCount(for: Prompt(text))
      }
    } catch {
      throw Self.map(error)
    }
  }

  func responseStream(prompt: String) -> AsyncThrowingStream<String, Error> {
    let model = model
    return AsyncThrowingStream { continuation in
      let task = Task {
        guard model.isAvailable else {
          continuation.finish(
            throwing: FoundationModelBridgeFailure.modelUnavailable
          )
          return
        }
        let session = LanguageModelSession(
          model: model,
          instructions: Self.instructions
        )
        let options = GenerationOptions(
          temperature: 0.2,
          maximumResponseTokens: 512
        )
        do {
          for try await snapshot in session.streamResponse(
            to: prompt,
            options: options
          ) {
            try Task.checkCancellation()
            continuation.yield(snapshot.content)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.map(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func map(_ error: Error) -> FoundationModelBridgeFailure {
    guard let generationError = error as? LanguageModelSession.GenerationError
    else {
      return .streamFailure
    }
    switch generationError {
    case .exceededContextWindowSize:
      return .contextOverflow
    case .assetsUnavailable:
      return .modelUnavailable
    case .guardrailViolation, .refusal:
      return .guardrailViolation
    case .unsupportedGuide,
         .unsupportedLanguageOrLocale,
         .decodingFailure,
         .rateLimited,
         .concurrentRequests:
      return .streamFailure
    @unknown default:
      return .streamFailure
    }
  }
}

enum AppleFileProtectionService {
  static func protect(directoryPath: String, databasePath: String) throws {
    let attributes: [FileAttributeKey: Any] = [
      .protectionKey: FileProtectionType.complete,
    ]
    try FileManager.default.setAttributes(
      attributes,
      ofItemAtPath: directoryPath
    )
    if FileManager.default.fileExists(atPath: databasePath) {
      try FileManager.default.setAttributes(
        attributes,
        ofItemAtPath: databasePath
      )
      let applied = try FileManager.default.attributesOfItem(
        atPath: databasePath
      )[.protectionKey] as? FileProtectionType
      guard applied == .complete else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
  }
}

final class AppleFoundationModelService {
  private let runtime: (any FoundationModelRuntime)?

  init(runtime: (any FoundationModelRuntime)?) {
    self.runtime = runtime
  }

  static func system() -> AppleFoundationModelService {
    if #available(iOS 26.0, *) {
      return AppleFoundationModelService(runtime: SystemFoundationModelRuntime())
    }
    return AppleFoundationModelService(runtime: nil)
  }

  func availabilityPayload() -> [String: Any] {
    ["status": (runtime?.availability() ?? .deviceNotEligible).rawValue]
  }

  func contextSize() throws -> Int {
    guard let runtime else {
      throw FoundationModelBridgeFailure.modelUnavailable
    }
    return try runtime.contextSize()
  }

  func countTokens(
    _ text: String,
    kind: FoundationModelTokenKind
  ) async throws -> Int {
    guard let runtime else {
      throw FoundationModelBridgeFailure.modelUnavailable
    }
    return try await runtime.countTokens(text, kind: kind)
  }

  func responseStream(prompt: String) throws -> AsyncThrowingStream<String, Error> {
    guard let runtime else {
      throw FoundationModelBridgeFailure.modelUnavailable
    }
    return runtime.responseStream(prompt: prompt)
  }
}

final class AppleFoundationModelsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let methodChannelName =
    "com.ricejy.sekret_midget/foundation_models"
  private static let eventChannelName =
    "com.ricejy.sekret_midget/foundation_models_stream"

  private let service: AppleFoundationModelService
  private var eventSink: FlutterEventSink?
  private var generationTasks: [String: Task<Void, Never>] = [:]

  override convenience init() {
    self.init(service: AppleFoundationModelService.system())
  }

  init(service: AppleFoundationModelService) {
    self.service = service
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = AppleFoundationModelsPlugin()
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(plugin, channel: methodChannel)
    eventChannel.setStreamHandler(plugin)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability":
      result(service.availabilityPayload())
    case "contextSize":
      do {
        result(try service.contextSize())
      } catch {
        result(flutterError(for: error))
      }
    case "countTokens":
      countTokens(call, result: result)
    case "generate":
      startGeneration(call, result: result)
    case "cancel":
      cancelGeneration(call, result: result)
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "protectStorage":
      protectStorage(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    for task in generationTasks.values {
      task.cancel()
    }
    generationTasks.removeAll()
    return nil
  }

  private func countTokens(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let text = arguments["text"] as? String,
      let rawKind = arguments["kind"] as? String,
      let kind = FoundationModelTokenKind(rawValue: rawKind)
    else {
      result(flutterError(for: FoundationModelBridgeFailure.streamFailure))
      return
    }
    Task { [service] in
      do {
        let count = try await service.countTokens(text, kind: kind)
        await MainActor.run { result(count) }
      } catch {
        await MainActor.run { result(self.flutterError(for: error)) }
      }
    }
  }

  private func startGeneration(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let requestId = arguments["requestId"] as? String,
      let prompt = arguments["prompt"] as? String,
      !requestId.isEmpty,
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      result(flutterError(for: FoundationModelBridgeFailure.streamFailure))
      return
    }
    generationTasks[requestId]?.cancel()
    do {
      let stream = try service.responseStream(prompt: prompt)
      generationTasks[requestId] = Task { [weak self] in
        guard let self else { return }
        do {
          for try await snapshot in stream {
            if Task.isCancelled { return }
            await MainActor.run {
              self.eventSink?([
                "requestId": requestId,
                "type": "snapshot",
                "text": snapshot,
              ])
            }
          }
          await MainActor.run {
            self.eventSink?([
              "requestId": requestId,
              "type": "completed",
            ])
            self.generationTasks.removeValue(forKey: requestId)
          }
        } catch {
          let code = self.failure(for: error).rawValue
          await MainActor.run {
            self.eventSink?([
              "requestId": requestId,
              "type": "error",
              "code": code,
            ])
            self.generationTasks.removeValue(forKey: requestId)
          }
        }
      }
      result(nil)
    } catch {
      result(flutterError(for: error))
    }
  }

  private func cancelGeneration(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let requestId = arguments["requestId"] as? String
    else {
      result(nil)
      return
    }
    generationTasks.removeValue(forKey: requestId)?.cancel()
    result(nil)
  }

  private func protectStorage(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = call.arguments as? [String: Any],
      let directoryPath = arguments["directoryPath"] as? String,
      let databasePath = arguments["databasePath"] as? String
    else {
      result(flutterError(for: FoundationModelBridgeFailure.streamFailure))
      return
    }
    do {
      try AppleFileProtectionService.protect(
        directoryPath: directoryPath,
        databasePath: databasePath
      )
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "storage_protection_failed",
          message: "The private library could not enable iOS file protection.",
          details: nil
        )
      )
    }
  }

  private func failure(for error: Error) -> FoundationModelBridgeFailure {
    error as? FoundationModelBridgeFailure ?? .streamFailure
  }

  private func flutterError(for error: Error) -> FlutterError {
    let failure = failure(for: error)
    return FlutterError(
      code: failure.rawValue,
      message: "The on-device Foundation Models request failed.",
      details: nil
    )
  }
}
