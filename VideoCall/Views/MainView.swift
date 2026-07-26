import SwiftUI

/// 启动页：填写服务器地址和自己的 ID → 连接 → 发起/接收呼叫。
struct MainView: View {

    @StateObject private var hub = SignalingHub.shared
    @State private var serverUrl = "ws://192.168.1.100:8080"
    @State private var myId = "user_" + String(Int.random(in: 1000...9999))
    @State private var peerId = ""
    @State private var connected = false

    /// 当前活动通话（非空时跳到 CallView）
    @State private var activeCall: CallConfig?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器")) {
                    TextField("ws://ip:port", text: $serverUrl)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("我的 ID", text: $myId)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button(action: connect) {
                        Text(connected ? "已连接: \(myId)" : "连接")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(connected)
                }

                Section(header: Text("发起呼叫")) {
                    TextField("对方 ID", text: $peerId)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    HStack {
                        Button("语音呼叫") { startCall(media: "audio") }
                            .frame(maxWidth: .infinity)
                        Divider()
                        Button("视频呼叫") { startCall(media: "video") }
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!connected)
                }
            }
            .navigationTitle("视频通话")
            // 来电通过监听 hub 的消息触发
            .onAppear { setupIncomingCallListener() }
            // 全屏覆盖通话界面
            .fullScreenCover(item: $activeCall) { config in
                CallView(config: config, onEnd: { activeCall = nil })
            }
        }
    }

    private func connect() {
        SignalingHub.shared.connect(serverUrl: serverUrl, userId: myId) {
            connected = true
        }
    }

    private func startCall(media: String) {
        guard !peerId.isEmpty else { return }
        activeCall = CallConfig(role: .caller, peerId: peerId, media: media)
    }

    /// 监听来电：注册后随时可能收到 call 消息
    private func setupIncomingCallListener() {
        SignalingHub.shared.setMessageHandler { msg in
            if case .incomingCall(let from, let media) = msg {
                // 收到呼叫 -> 跳到 CallView
                if activeCall == nil {
                    activeCall = CallConfig(role: .callee, peerId: from, media: media)
                }
            }
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
