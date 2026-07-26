import SwiftUI
import WebRTC

/// 通话配置：角色 + 对方 ID + 媒体类型
struct CallConfig: Identifiable {
    let id = UUID()
    let role: Role
    let peerId: String
    let media: String

    enum Role { case caller, callee }
    var isVideo: Bool { media == "video" }
}

/// 通话状态
enum CallState: String {
    case outgoingInit = "正在呼叫…"
    case ringing = "正在响铃…"
    case incoming = "来电"
    case connecting = "正在建立连接…"
    case inCall = "通话中"
    case ended = "通话结束"
}

struct CallView: View {

    let config: CallConfig
    let onEnd: () -> Void

    @State private var state: CallState = .outgoingInit
    @State private var webRTC = WebRTCClientHolder()
    @State private var muted = false
    @State private var cameraOn = true
    @State private var remoteVideoView: RTCMTLVideoView?
    @State private var localVideoView: RTCMTLVideoView?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 远端视频
            if config.isVideo, let remote = remoteVideoView {
                VideoViewContainer(view: remote)
                    .ignoresSafeArea()
            }

            // 本地小窗
            if config.isVideo, let local = localVideoView {
                VideoViewContainer(view: local)
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.4), lineWidth: 1))
                    .position(x: UIScreen.main.bounds.width - 80, y: 120)
            }

            VStack {
                Spacer()
                Text(state.rawValue)
                    .foregroundColor(.white)
                    .font(.headline)
                    .padding(.bottom, 8)

                // 来电面板
                if state == .incoming && config.role == .callee {
                    HStack(spacing: 48) {
                        Button(action: reject) {
                            callButton(color: .red, systemName: "phone.down.fill")
                        }
                        Button(action: accept) {
                            callButton(color: .green, systemName: "phone.fill")
                        }
                    }
                    .padding(.bottom, 60)
                } else {
                    // 通话控制
                    HStack(spacing: 32) {
                        controlButton(systemName: muted ? "mic.slash.fill" : "mic.fill",
                                      color: muted ? .red : .white, action: toggleMute)
                        if config.isVideo {
                            controlButton(systemName: cameraOn ? "video.fill" : "video.slash.fill",
                                          color: cameraOn ? .white : .red, action: toggleCamera)
                            controlButton(systemName: "camera.rotate.fill",
                                          color: .white, action: { webRTC.client.switchCamera() })
                        }
                        controlButton(systemName: "phone.down.fill",
                                      color: .red, action: hangup)
                    }
                    .padding(.bottom, 60)
                }
            }
        }
        .onAppear { start() }
        .onDisappear { teardown() }
    }

    // MARK: - 子视图构造

    private func callButton(color: Color, systemName: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 70, height: 70)
            .overlay(Image(systemName: systemName).foregroundColor(.white).font(.title2))
    }

    private func controlButton(systemName: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 60, height: 60)
                .overlay(Image(systemName: systemName).foregroundColor(color).font(.title3))
        }
    }

    // MARK: - 生命周期

    private func start() {
        // 接管信令
        SignalingHub.shared.setMessageHandler { msg in
            handle(msg: msg)
        }

        // 初始化 WebRTC + 本地媒体
        webRTC.client = WebRTCClient(enableVideo: config.isVideo)
        webRTC.client.startLocalMedia()
        bindWebRTCCallbacks()

        if config.isVideo {
            setupLocalVideoView()
        }

        // 角色分支
        if config.role == .caller {
            state = .outgoingInit
            SignalingHub.shared.client.call(to: config.peerId, media: config.media)
        } else {
            state = .incoming
        }
    }

    private func teardown() {
        SignalingHub.shared.client.disconnect()  // 注意：仅断信令不会，因为 hub 复用
        // 实际上不应在此断开 hub 的连接；改为发 hangup
    }

    // MARK: - 信令处理

    private func handle(msg: SignalingMessage) {
        switch msg {
        case .ringing(let from):
            if config.role == .caller && from == config.peerId {
                state = .ringing
            }
        case .accept(let from):
            if config.role == .caller && from == config.peerId {
                state = .connecting
                startCallerNegotiation()
            }
        case .reject:
            onEnd()
            dismiss()
        case .offer(let from, let sdp):
            if config.role == .callee && from == config.peerId {
                state = .connecting
                startCalleeNegotiation(remoteSdp: sdp)
            }
        case .answer(_, let sdp):
            webRTC.client.setRemoteSdp(type: "answer", sdp: sdp)
        case .ice(_, let candidate):
            webRTC.client.addRemoteIceCandidate(candidate)
        case .hangup:
            onEnd()
            dismiss()
        default:
            break
        }
    }

    // MARK: - WebRTC 协商

    private func bindWebRTCCallbacks() {
        webRTC.client.onLocalSdp = { type, sdp in
            if type == "offer" {
                SignalingHub.shared.client.offer(to: self.config.peerId, sdp: sdp)
            } else {
                SignalingHub.shared.client.answer(to: self.config.peerId, sdp: sdp)
            }
        }
        webRTC.client.onIceCandidate = { candidate in
            SignalingHub.shared.client.ice(to: self.config.peerId, candidate: candidate)
        }
        webRTC.client.onIceConnected = {
            self.state = .inCall
        }
        webRTC.client.onIceDisconnected = {
            // 简单提示
        }
        webRTC.client.onRemoteVideoTrack = { track in
            DispatchQueue.main.async {
                self.attachRemoteTrack(track)
            }
        }
    }

    private func startCallerNegotiation() {
        webRTC.client.createPeerConnection()
        webRTC.client.createOffer()
    }

    private func startCalleeNegotiation(remoteSdp: String) {
        webRTC.client.createPeerConnection()
        webRTC.client.setRemoteSdp(type: "offer", sdp: remoteSdp)
        webRTC.client.createAnswer()
    }

    // MARK: - 视频渲染

    private func setupLocalVideoView() {
        let view = RTCMTLVideoView()
        view.shouldMirroring = true
        webRTC.client.attachLocalVideo(to: view)
        localVideoView = view
    }

    private func attachRemoteTrack(_ track: RTCVideoTrack) {
        let view = RTCMTLVideoView()
        track.add(view)
        remoteVideoView = view
    }

    // MARK: - 按钮

    private func accept() {
        SignalingHub.shared.client.accept(to: config.peerId)
        state = .connecting
    }

    private func reject() {
        SignalingHub.shared.client.reject(to: config.peerId)
        onEnd()
        dismiss()
    }

    private func hangup() {
        SignalingHub.shared.client.hangup(to: config.peerId)
        onEnd()
        dismiss()
    }

    private func toggleMute() {
        muted = webRTC.client.toggleMute()
    }

    private func toggleCamera() {
        cameraOn = webRTC.client.toggleCamera()
    }
}

/// 包装 RTCMTLVideoView 为 SwiftUI 视图
struct VideoViewContainer: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 持有 WebRTCClient（ObservableObject 用于状态刷新）
final class WebRTCClientHolder: ObservableObject {
    @Published var client: WebRTCClient = WebRTCClient(enableVideo: true)
}
