import Foundation

/// 信令客户端：基于 URLSessionWebSocketTask 的 WebSocket 长连接。
/// 单例 SignalingHub 负责生命周期；外部只读消息流。
final class SignalingClient: NSObject {

    enum State { case disconnected, connecting, connected, failed }

    /// 入站消息回调（主线程）
    var onMessage: ((SignalingMessage) -> Void)?
    /// 状态变化回调（主线程）
    var onStateChange: ((State) -> Void)?

    private var webSocket: URLSessionWebSocketTask?
    private var url: URL?
    private(set) var state: State = .disconnected {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }

    /// 连接服务器
    func connect(serverUrl: String) {
        guard let url = URL(string: serverUrl) else {
            state = .failed
            return
        }
        self.url = url
        disconnect()
        state = .connecting
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.webSocket = task
        task.resume()
        // 立刻进入 receive 循环；连接成功由首次 receive 间接确认
        receiveLoop()
        // 触发连接成功判定：发个空 ping
        task.sendPing { [weak self] err in
            if let err = err {
                print("[SignalingClient] ping 失败: \(err.localizedDescription)")
                self?.state = .failed
            } else {
                self?.state = .connected
            }
        }
    }

    /// 接收循环
    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("[SignalingClient] 接收失败: \(error.localizedDescription)")
                self.state = .failed
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text: text) }
                @unknown default: break
                }
                // 继续接收
                self.receiveLoop()
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[SignalingClient] 解析失败: \(text)")
            return
        }
        let msg = SignalingMessage.from(dict: dict)
        DispatchQueue.main.async { self.onMessage?(msg) }
    }

    /// 发送 JSON
    func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { err in
            if let err = err { print("[SignalingClient] 发送失败: \(err.localizedDescription)") }
        }
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        state = .disconnected
    }

    // ============ 业务封装 ============

    func register(userId: String) { send(["type": "register", "userId": userId]) }
    func call(to: String, media: String) { send(["type": "call", "to": to, "media": media]) }
    func ringing(to: String) { send(["type": "ringing", "to": to]) }
    func accept(to: String) { send(["type": "accept", "to": to]) }
    func reject(to: String, reason: String = "rejected") { send(["type": "reject", "to": to, "reason": reason]) }
    func offer(to: String, sdp: String) { send(["type": "offer", "to": to, "sdp": sdp]) }
    func answer(to: String, sdp: String) { send(["type": "answer", "to": to, "sdp": sdp]) }
    func ice(to: String, candidate: [String: Any]) { send(["type": "ice", "to": to, "candidate": candidate]) }
    func hangup(to: String) { send(["type": "hangup", "to": to]) }
}

extension SignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        state = .connected
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        state = .disconnected
    }
}
