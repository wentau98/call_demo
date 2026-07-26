import Foundation

/// 全局信令客户端单例。
/// 由 MainView 创建并注册，CallView 直接复用同一连接。
final class SignalingHub: ObservableObject {

    static let shared = SignalingHub()

    let client = SignalingClient()

    /// 当前已注册的 userId
    @Published var myId: String?
    /// 当前连接状态
    @Published var state: SignalingClient.State = .disconnected

    private init() {
        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.state = state }
        }
    }

    /// 连接并注册
    func connect(serverUrl: String, userId: String, onRegistered: @escaping () -> Void) {
        client.onMessage = { [weak self] msg in
            if case .registered(let id) = msg {
                DispatchQueue.main.async {
                    self?.myId = id
                    onRegistered()
                }
            }
            // 来电由 MainView 自己监听（通过 setMessageHandler）
        }
        client.connect(serverUrl: serverUrl)
        // 注册请求在连接成功后再发：用状态变化触发
        let original = client.onStateChange
        var fired = false
        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.state = state
                if state == .connected && !fired {
                    fired = true
                    self?.client.register(userId: userId)
                }
                original?(state)
            }
        }
    }

    /// 通话期间设置消息处理器
    func setMessageHandler(_ handler: @escaping (SignalingMessage) -> Void) {
        client.onMessage = handler
    }

    func disconnect() {
        client.disconnect()
        myId = nil
    }
}
