import Flutter
import NaturalLanguage

protocol SentenceEmbeddingModel {
  var dimension: Int { get }
  var revision: Int { get }

  func vector(for string: String) -> [Double]?
}

extension NLEmbedding: SentenceEmbeddingModel {}

enum AppleSentenceEmbeddingError: String, Error {
  case embeddingUnavailable = "embedding_unavailable"
  case invalidInput = "invalid_input"
  case vectorUnavailable = "vector_unavailable"
  case dimensionMismatch = "dimension_mismatch"
}

final class AppleSentenceEmbeddingService {
  static let language = "en"

  private let model: SentenceEmbeddingModel?

  init(model: SentenceEmbeddingModel?) {
    self.model = model
  }

  static func systemEnglish() -> AppleSentenceEmbeddingService {
    if #available(iOS 14.0, *) {
      return AppleSentenceEmbeddingService(
        model: NLEmbedding.sentenceEmbedding(for: .english)
      )
    }
    return AppleSentenceEmbeddingService(model: nil)
  }

  func availability() -> [String: Any] {
    guard let model = model else {
      return [
        "available": false,
        "language": Self.language,
        "reason": "Apple sentence embeddings are unavailable for English.",
      ]
    }
    return [
      "available": true,
      "language": Self.language,
      "dimensions": model.dimension,
      "revision": model.revision,
    ]
  }

  func embed(_ text: String) throws -> [Double] {
    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanText.isEmpty else {
      throw AppleSentenceEmbeddingError.invalidInput
    }
    guard let model = model else {
      throw AppleSentenceEmbeddingError.embeddingUnavailable
    }
    guard let vector = model.vector(for: cleanText) else {
      throw AppleSentenceEmbeddingError.vectorUnavailable
    }
    guard vector.count == model.dimension else {
      throw AppleSentenceEmbeddingError.dimensionMismatch
    }
    return vector
  }
}

final class AppleEmbeddingPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.ricejy.sekret_midget/embedding"

  private let service: AppleSentenceEmbeddingService

  override convenience init() {
    self.init(service: AppleSentenceEmbeddingService.systemEnglish())
  }

  init(service: AppleSentenceEmbeddingService) {
    self.service = service
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(AppleEmbeddingPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability":
      result(service.availability())
    case "embed":
      guard
        let arguments = call.arguments as? [String: Any],
        let text = arguments["text"] as? String
      else {
        result(flutterError(for: .invalidInput))
        return
      }
      do {
        result(try service.embed(text))
      } catch let error as AppleSentenceEmbeddingError {
        result(flutterError(for: error))
      } catch {
        result(
          FlutterError(
            code: "bridge_failure",
            message: "The Apple embedding bridge failed.",
            details: nil
          )
        )
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func flutterError(for error: AppleSentenceEmbeddingError) -> FlutterError {
    let message: String
    switch error {
    case .embeddingUnavailable:
      message = "Apple sentence embeddings are unavailable for English."
    case .invalidInput:
      message = "Text must not be empty."
    case .vectorUnavailable:
      message = "Apple could not embed this text."
    case .dimensionMismatch:
      message = "Apple returned an unexpected vector shape."
    }
    return FlutterError(code: error.rawValue, message: message, details: nil)
  }
}
