import Foundation
import UIKit

enum GeminiConnectionState: Equatable {
  case disconnected
  case connecting
  case settingUp
  case ready
  case error(String)
}

@MainActor
class GeminiLiveService: ObservableObject {
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false

  var onAudioReceived: ((Data) -> Void)?
  var onTurnComplete: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?

  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var setupContinuation: CheckedContinuation<Bool, Never>?
  private let urlSession: URLSession
  private let sendQueue = DispatchQueue(label: "gemini.send", qos: .userInitiated)

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(configuration: config)
  }

  /// Connects to Gemini Live API and waits for setupComplete or error.
  /// Returns true if setup succeeded, false otherwise.
  func connect() async -> Bool {
    guard let url = GeminiConfig.websocketURL() else {
      connectionState = .error("No API key configured")
      return false
    }

    connectionState = .connecting
    webSocketTask = urlSession.webSocketTask(with: url)
    webSocketTask?.resume()

    connectionState = .settingUp
    sendSetupMessage()
    startReceiving()

    // Wait for setupComplete or error (with 15s timeout)
    let setupOk = await withCheckedContinuation { continuation in
      self.setupContinuation = continuation
      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        if let cont = self.setupContinuation {
          self.setupContinuation = nil
          cont.resume(returning: false)
          await MainActor.run {
            if self.connectionState == .settingUp {
              self.connectionState = .error("Setup timed out")
            }
          }
        }
      }
    }

    return setupOk
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    connectionState = .disconnected
    isModelSpeaking = false
    // Cancel any pending setup wait
    if let cont = setupContinuation {
      setupContinuation = nil
      cont.resume(returning: false)
    }
  }

  func sendAudio(data: Data) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      let base64 = data.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "audio": [
            "mimeType": "audio/pcm;rate=16000",
            "data": base64
          ]
        ]
      ]
      self?.sendJSON(json)
    }
  }

  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      guard let jpegData = image.jpegData(compressionQuality: GeminiConfig.videoJPEGQuality) else { return }
      let base64 = jpegData.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "video": [
            "mimeType": "image/jpeg",
            "data": base64
          ]
        ]
      ]
      self?.sendJSON(json)
    }
  }

  // MARK: - Private

  private func sendSetupMessage() {
    let setup: [String: Any] = [
      "setup": [
        "model": GeminiConfig.model,
        "generationConfig": [
          "responseModalities": ["AUDIO"]
        ],
        "systemInstruction": [
          "parts": [
            ["text": GeminiConfig.systemInstruction]
          ]
        ],
        "realtimeInputConfig": [
          "automaticActivityDetection": [
            "disabled": false
          ]
        ]
      ]
    ]
    sendJSON(setup)
  }

  private func sendJSON(_ json: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          let string = String(data: data, encoding: .utf8) else {
      return
    }
    webSocketTask?.send(.string(string)) { error in
      if let error {
        #if DEBUG
        NSLog("[GeminiLive] Send error: \(error.localizedDescription)")
        #endif
      }
    }
  }

  private func startReceiving() {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let task = self.webSocketTask else { break }
        do {
          let message = try await task.receive()
          switch message {
          case .string(let text):
            await self.handleMessage(text)
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              await self.handleMessage(text)
            }
          @unknown default:
            break
          }
        } catch {
          if !Task.isCancelled {
            let reason = error.localizedDescription
            #if DEBUG
            NSLog("[GeminiLive] Receive error: \(reason)")
            #endif
            await MainActor.run {
              self.connectionState = .disconnected
              self.isModelSpeaking = false
              self.onDisconnected?(reason)
            }
          }
          break
        }
      }
    }
  }

  private func handleMessage(_ text: String) async {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }

    #if DEBUG
    // Log message keys for debugging
    let keys = json.keys.joined(separator: ", ")
    NSLog("[GeminiLive] Received message keys: \(keys)")
    #endif

    // Setup complete
    if json["setupComplete"] != nil {
      connectionState = .ready
      if let cont = setupContinuation {
        setupContinuation = nil
        cont.resume(returning: true)
      }
      return
    }

    // GoAway - server will close soon
    if let goAway = json["goAway"] as? [String: Any] {
      let timeLeft = goAway["timeLeft"] as? [String: Any]
      let seconds = timeLeft?["seconds"] as? Int ?? 0
      #if DEBUG
      NSLog("[GeminiLive] GoAway received, time left: \(seconds)s")
      #endif
      connectionState = .disconnected
      isModelSpeaking = false
      onDisconnected?("Server closing connection (time left: \(seconds)s)")
      return
    }

    // Server content
    if let serverContent = json["serverContent"] as? [String: Any] {
      // Check for interruption
      if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
        isModelSpeaking = false
        onInterrupted?()
        return
      }

      // Model turn with audio parts
      if let modelTurn = serverContent["modelTurn"] as? [String: Any],
         let parts = modelTurn["parts"] as? [[String: Any]] {
        for part in parts {
          if let inlineData = part["inlineData"] as? [String: Any],
             let mimeType = inlineData["mimeType"] as? String,
             mimeType.hasPrefix("audio/pcm"),
             let base64Data = inlineData["data"] as? String,
             let audioData = Data(base64Encoded: base64Data) {
            if !isModelSpeaking {
              isModelSpeaking = true
            }
            onAudioReceived?(audioData)
          }
        }
      }

      // Turn complete
      if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
        isModelSpeaking = false
        onTurnComplete?()
      }
    }
  }
}
