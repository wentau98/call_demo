import Foundation

/// 信令消息统一模型。与 signaling-server/server.js 协议保持一致。
enum SignalingMessage {
    case registered(userId: String)
    case kicked(reason: String)
    case incomingCall(from: String, media: String)
    case ringing(from: String)
    case accept(from: String)
    case reject(from: String, reason: String?)
    case offer(from: String, sdp: String)
    case answer(from: String, sdp: String)
    case ice(from: String, candidate: [String: Any])
    case hangup(from: String)
    case error(reason: String?, originalType: String?)
    case unknown(type: String)
}

// MARK: - Equatable
// 手动实现因为 .ice 的 candidate 字典包含 Any，无法自动合成
extension SignalingMessage: Equatable {
    static func == (lhs: SignalingMessage, rhs: SignalingMessage) -> Bool {
        switch (lhs, rhs) {
        case (.registered(let a), .registered(let b)): return a == b
        case (.kicked(let a), .kicked(let b)): return a == b
        case (.incomingCall(let a1, let a2), .incomingCall(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.ringing(let a), .ringing(let b)): return a == b
        case (.accept(let a), .accept(let b)): return a == b
        case (.reject(let a1, let a2), .reject(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.offer(let a1, let a2), .offer(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.answer(let a1, let a2), .answer(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.ice(let a1, _), .ice(let b1, _)):
            return a1 == b1
        case (.hangup(let a), .hangup(let b)): return a == b
        case (.error(let a1, let a2), .error(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.unknown(let a), .unknown(let b)): return a == b
        default: return false
        }
    }
}

extension SignalingMessage {
    /// 从原始 JSON 字典解析为强类型消息
    static func from(dict: [String: Any]) -> SignalingMessage {
        let type = dict["type"] as? String ?? ""
        let from = dict["from"] as? String ?? ""
        switch type {
        case "registered":
            return .registered(userId: dict["userId"] as? String ?? "")
        case "kicked":
            return .kicked(reason: dict["reason"] as? String ?? "")
        case "call":
            return .incomingCall(from: from, media: dict["media"] as? String ?? "video")
        case "ringing":
            return .ringing(from: from)
        case "accept":
            return .accept(from: from)
        case "reject":
            return .reject(from: from, reason: dict["reason"] as? String)
        case "offer":
            return .offer(from: from, sdp: dict["sdp"] as? String ?? "")
        case "answer":
            return .answer(from: from, sdp: dict["sdp"] as? String ?? "")
        case "ice":
            let candidate = dict["candidate"] as? [String: Any] ?? [:]
            return .ice(from: from, candidate: candidate)
        case "hangup":
            return .hangup(from: from)
        case "error":
            return .error(reason: dict["reason"] as? String, originalType: dict["originalType"] as? String)
        default:
            return .unknown(type: type)
        }
    }
}
