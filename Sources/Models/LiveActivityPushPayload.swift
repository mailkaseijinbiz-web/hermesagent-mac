import Foundation

/// Builds APNs ActivityKit push payloads (unit-testable).
enum LiveActivityPushPayload {
  static let attributesType = "HermesActivityAttributes"

  /// Push-to-start payload (`aps.event` = `start`) per Apple ActivityKit remote push docs.
  static func start(
    employeeEmoji: String,
    employeeName: String,
    preview: String,
    toolLabel: String = "チェックイン",
    timestamp: Int = Int(Date().timeIntervalSince1970)
  ) -> [String: Any] {
    let contentState: [String: Any] = [
      "isStreaming": false,
      "preview": preview,
      "toolLabel": toolLabel,
    ]
    let attributes: [String: Any] = [
      "employeeEmoji": employeeEmoji,
      "employeeName": employeeName,
    ]
    let aps: [String: Any] = [
      "timestamp": timestamp,
      "event": "start",
      "content-state": contentState,
      "attributes-type": attributesType,
      "attributes": attributes,
    ]
    return ["aps": aps]
  }
}
