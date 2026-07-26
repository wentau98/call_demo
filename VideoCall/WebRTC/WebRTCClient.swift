import Foundation
import WebRTC
import AVFoundation

/// WebRTC 客户端：封装 RTCPeerConnectionFactory、本地音视频采集、PeerConnection 协商。
/// 基于 stasel/WebRTC M150 API，参考官方 demo：https://github.com/stasel/WebRTC-iOS
final class WebRTCClient: NSObject {

    // MARK: - 回调
    var onLocalSdp: ((String, String) -> Void)?             // (type, sdp)
    var onIceCandidate: (([String: Any]) -> Void)?          // ice candidate dict
    var onIceConnected: (() -> Void)?
    var onIceDisconnected: (() -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?

    // MARK: - 共享 Factory（M150 要求使用 encoder/decoder factory）
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory,
                                        decoderFactory: videoDecoderFactory)
    }()

    // MARK: - 内部
    private var peerConnection: RTCPeerConnection?
    private var videoCapturer: RTCVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?

    private let rtcQueue = DispatchQueue(label: "webrtc.queue")
    private(set) var isVideoEnabled = true
    private(set) var isAudioEnabled = true
    private let enableVideo: Bool

    init(enableVideo: Bool) {
        self.enableVideo = enableVideo
        super.init()
    }

    // MARK: - 初始化本地媒体

    func startLocalMedia() {
        configureAudioSession()

        // 音频
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = Self.factory.audioSource(with: audioConstraints)
        localAudioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")

        // 视频
        if enableVideo {
            startVideoCapture()
        }
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("[WebRTC] 配置音频会话失败: \(error)")
        }
        session.unlockForConfiguration()
    }

    private func startVideoCapture() {
        let videoSource = Self.factory.videoSource()

        #if targetEnvironment(simulator)
        // 模拟器不支持真实摄像头，使用文件 capturer 占位
        videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        #else
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        #endif

        localVideoTrack = Self.factory.videoTrack(with: videoSource, trackId: "video0")

        // 真机上启动摄像头采集
        #if !targetEnvironment(simulator)
        startCameraCapture()
        #endif
    }

    private func startCameraCapture() {
        guard let capturer = videoCapturer as? RTCCameraVideoCapturer else { return }

        guard let device = (RTCCameraVideoCapturer.captureDevices().first { $0.position == .front }) else {
            print("[WebRTC] 未找到摄像头")
            return
        }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // 选最高分辨率 + 最高帧率
        guard let format = (formats.sorted { f1, f2 in
            let w1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width
            let w2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
            return w1 < w2
        }).last else {
            print("[WebRTC] 摄像头不支持任何格式")
            return
        }

        guard let fps = (format.videoSupportedFrameRateRanges.sorted {
            $0.maxFrameRate < $1.maxFrameRate
        }.last) else { return }

        capturer.startCapture(with: device, format: format, fps: Int(fps.maxFrameRate))
    }

    // MARK: - PeerConnection

    func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )

        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            fatalError("无法创建 RTCPeerConnection")
        }
        pc.delegate = self
        self.peerConnection = pc

        // 添加本地 track（M150 使用 add(_:streamIds:) 而非 RTCMediaStream）
        let streamId = "ARDAMS"
        if let audio = localAudioTrack {
            pc.add(audio, streamIds: [streamId])
        }
        if let video = localVideoTrack {
            pc.add(video, streamIds: [streamId])
        }
    }

    // MARK: - 协商

    func createOffer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: enableVideo ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse
            ],
            optionalConstraints: nil
        )
        peerConnection?.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }
            if let error = error { print("[WebRTC] offer 失败: \(error)"); return }
            guard let sdp = sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { err in
                if let err = err { print("[WebRTC] setLocal 失败: \(err)"); return }
                self.onLocalSdp?("offer", sdp.sdp)
            }
        }
    }

    func createAnswer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: enableVideo ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse
            ],
            optionalConstraints: nil
        )
        peerConnection?.answer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }
            if let error = error { print("[WebRTC] answer 失败: \(error)"); return }
            guard let sdp = sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { err in
                if let err = err { print("[WebRTC] setLocal 失败: \(err)"); return }
                self.onLocalSdp?("answer", sdp.sdp)
            }
        }
    }

    func setRemoteSdp(type: String, sdp: String) {
        let sdpType: RTCSdpType = (type == "offer") ? .offer : .answer
        let remoteSdp = RTCSessionDescription(type: sdpType, sdp: sdp)
        peerConnection?.setRemoteDescription(remoteSdp) { err in
            if let err = err { print("[WebRTC] setRemote 失败: \(err)") }
        }
    }

    func addRemoteIceCandidate(_ candidate: [String: Any]) {
        let sdp = candidate["candidate"] as? String ?? ""
        let sdpMid = candidate["sdpMid"] as? String
        let sdpMLineIndex = candidate["sdpMLineIndex"] as? Int32 ?? -1
        let ice = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnection?.add(ice)
    }

    // MARK: - 媒体控制

    func toggleMute() -> Bool {
        isAudioEnabled.toggle()
        setTrackEnabled(RTCAudioTrack.self, isEnabled: isAudioEnabled)
        return !isAudioEnabled
    }

    func toggleCamera() -> Bool {
        isVideoEnabled.toggle()
        setTrackEnabled(RTCVideoTrack.self, isEnabled: isVideoEnabled)
        return isVideoEnabled
    }

    func switchCamera() {
        guard let capturer = videoCapturer as? RTCCameraVideoCapturer else { return }
        capturer.stopCapture()
        // 简化：切到后置摄像头
        guard let device = (RTCCameraVideoCapturer.captureDevices().first { $0.position == .back }) else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = (formats.sorted { f1, f2 in
            let w1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width
            let w2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
            return w1 < w2
        }).last else { return }
        guard let fps = (format.videoSupportedFrameRateRanges.sorted {
            $0.maxFrameRate < $1.maxFrameRate
        }.last) else { return }
        capturer.startCapture(with: device, format: format, fps: Int(fps.maxFrameRate))
    }

    /// 把本地视频 track 绑到渲染视图
    func attachLocalVideo(to view: RTCMTLVideoView) {
        localVideoTrack?.add(view)
    }

    // MARK: - 辅助

    private func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, isEnabled: Bool) {
        peerConnection?.transceivers
            .compactMap { $0.sender.track as? T }
            .forEach { $0.isEnabled = isEnabled }
    }

    // MARK: - 释放

    deinit {
        peerConnection?.close()
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCClient: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed: onIceConnected?()
        case .disconnected, .failed: onIceDisconnected?()
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        let dict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? NSNull(),
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        onIceCandidate?(dict)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        if let video = track as? RTCVideoTrack {
            DispatchQueue.main.async { self.onRemoteVideoTrack?(video) }
        } else if let audio = track as? RTCAudioTrack {
            DispatchQueue.main.async { self.onRemoteAudioTrack?(audio) }
        }
    }
}
