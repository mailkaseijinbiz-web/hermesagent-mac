import Foundation

/// Builds APNs ActivityKit push payloads (unit-testable).
enum LiveActivityPushPayload {
  static let attributesType = "HermesActivityAttributes"
  static let lifeLogAttributesType = "LifeLogActivityAttributes"

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

  static func lifeLogStart(
    headline: String,
    detail: String,
    statusLabel: String = "今日",
    title: String = "ライフログ",
    timestamp: Int = Int(Date().timeIntervalSince1970)
  ) -> [String: Any] {
    let contentState: [String: Any] = [
      "headline": headline,
      "detail": detail,
      "statusLabel": statusLabel,
    ]
    let attributes: [String: Any] = [
      "title": title,
    ]
    let aps: [String: Any] = [
      "timestamp": timestamp,
      "event": "start",
      "content-state": contentState,
      "attributes-type": lifeLogAttributesType,
      "attributes": attributes,
    ]
    return ["aps": aps]
  }

  static func lifeLogUpdate(
    headline: String,
    detail: String,
    statusLabel: String = "今日",
    timestamp: Int = Int(Date().timeIntervalSince1970)
  ) -> [String: Any] {
    let contentState: [String: Any] = [
      "headline": headline,
      "detail": detail,
      "statusLabel": statusLabel,
    ]
    let aps: [String: Any] = [
      "timestamp": timestamp,
      "event": "update",
      "content-state": contentState,
    ]
    return ["aps": aps]
  }
}
