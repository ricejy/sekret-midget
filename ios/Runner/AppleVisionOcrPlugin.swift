import Flutter
import ImageIO
import UIKit
import Vision

enum AppleVisionOcrError: String, Error {
  case visionUnavailable = "vision_unavailable"
  case invalidInput = "invalid_input"
  case decodeFailed = "decode_failed"
  case recognitionFailed = "recognition_failed"
  case cancelled = "cancelled"
}

enum VisionOcrImage: @unchecked Sendable {
  case encoded(Data)
  case bgra8888(data: Data, width: Int, height: Int)
}

struct VisionRecognizedLine: Sendable {
  let text: String
  let confidence: Float
  let boundingBox: CGRect
}

protocol VisionTextRecognitionRuntime {
  func recognize(_ image: VisionOcrImage) async throws -> [VisionRecognizedLine]
}

final class SystemVisionTextRecognitionRuntime: VisionTextRecognitionRuntime {
  func recognize(_ image: VisionOcrImage) async throws -> [VisionRecognizedLine] {
    try await Task.detached(priority: .userInitiated) {
      let (cgImage, orientation) = try Self.prepare(image)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["en-US"]
      let handler = VNImageRequestHandler(
        cgImage: cgImage,
        orientation: orientation,
        options: [:]
      )
      do {
        try handler.perform([request])
      } catch {
        throw AppleVisionOcrError.recognitionFailed
      }
      return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else {
          return nil
        }
        return VisionRecognizedLine(
          text: candidate.string,
          confidence: candidate.confidence,
          boundingBox: observation.boundingBox
        )
      }
    }.value
  }

  private static func prepare(
    _ image: VisionOcrImage
  ) throws -> (CGImage, CGImagePropertyOrientation) {
    switch image {
    case .encoded(let data):
      guard let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else {
        throw AppleVisionOcrError.decodeFailed
      }
      return (cgImage, CGImagePropertyOrientation(uiImage.imageOrientation))
    case .bgra8888(let data, let width, let height):
      guard
        width > 0,
        height > 0,
        data.count == width * height * 4,
        let provider = CGDataProvider(data: data as CFData),
        let cgImage = CGImage(
          width: width,
          height: height,
          bitsPerComponent: 8,
          bitsPerPixel: 32,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
              CGBitmapInfo.byteOrder32Little.rawValue
          ),
          provider: provider,
          decode: nil,
          shouldInterpolate: true,
          intent: .defaultIntent
        )
      else {
        throw AppleVisionOcrError.invalidInput
      }
      return (cgImage, .up)
    }
  }
}

final class AppleVisionOcrService {
  private let runtime: VisionTextRecognitionRuntime

  init(runtime: VisionTextRecognitionRuntime) {
    self.runtime = runtime
  }

  static func system() -> AppleVisionOcrService {
    AppleVisionOcrService(runtime: SystemVisionTextRecognitionRuntime())
  }

  func recognize(_ image: VisionOcrImage) async throws -> [String: Any] {
    let lines = try await runtime.recognize(image).sorted { left, right in
      let verticalDifference = left.boundingBox.midY - right.boundingBox.midY
      if abs(verticalDifference) > 0.015 {
        return verticalDifference > 0
      }
      return left.boundingBox.minX < right.boundingBox.minX
    }
    let text = lines
      .map(\.text)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let confidence = lines.isEmpty
      ? 0
      : lines.reduce(0.0) { $0 + Double($1.confidence) } / Double(lines.count)
    return [
      "text": text,
      "confidence": confidence,
    ]
  }
}

final class AppleVisionOcrPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.ricejy.sekret_midget/vision_ocr"

  private let service: AppleVisionOcrService

  override convenience init() {
    self.init(service: AppleVisionOcrService.system())
  }

  init(service: AppleVisionOcrService) {
    self.service = service
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(AppleVisionOcrPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "recognize" else {
      result(FlutterMethodNotImplemented)
      return
    }
    do {
      let image = try parseImage(call.arguments)
      Task {
        do {
          let payload = try await service.recognize(image)
          await MainActor.run { result(payload) }
        } catch let error as AppleVisionOcrError {
          let mappedError = flutterError(for: error)
          await MainActor.run { result(mappedError) }
        } catch {
          let mappedError = flutterError(for: .recognitionFailed)
          await MainActor.run { result(mappedError) }
        }
      }
    } catch let error as AppleVisionOcrError {
      result(flutterError(for: error))
    } catch {
      result(flutterError(for: .invalidInput))
    }
  }

  private func parseImage(_ arguments: Any?) throws -> VisionOcrImage {
    guard
      let arguments = arguments as? [String: Any],
      let typedData = arguments["bytes"] as? FlutterStandardTypedData,
      !typedData.data.isEmpty,
      let format = arguments["format"] as? String
    else {
      throw AppleVisionOcrError.invalidInput
    }
    switch format {
    case "encoded":
      return .encoded(typedData.data)
    case "bgra8888":
      guard
        let width = arguments["width"] as? Int,
        let height = arguments["height"] as? Int
      else {
        throw AppleVisionOcrError.invalidInput
      }
      return .bgra8888(data: typedData.data, width: width, height: height)
    default:
      throw AppleVisionOcrError.invalidInput
    }
  }

  private func flutterError(for error: AppleVisionOcrError) -> FlutterError {
    let message: String
    switch error {
    case .visionUnavailable:
      message = "Apple Vision text recognition is unavailable."
    case .invalidInput:
      message = "The supplied image was invalid."
    case .decodeFailed:
      message = "The supplied image could not be decoded."
    case .recognitionFailed:
      message = "Apple Vision could not recognize this document."
    case .cancelled:
      message = "OCR was cancelled."
    }
    return FlutterError(code: error.rawValue, message: message, details: nil)
  }
}

private extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    self = switch orientation {
    case .up: .up
    case .down: .down
    case .left: .left
    case .right: .right
    case .upMirrored: .upMirrored
    case .downMirrored: .downMirrored
    case .leftMirrored: .leftMirrored
    case .rightMirrored: .rightMirrored
    @unknown default: .up
    }
  }
}
