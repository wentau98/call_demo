import Foundation
import WebRTC
import AVFoundation

/// WebRTC 客户端：封装 RTCPeerConnectionFactory、本地音视频采集、PeerConnection 协商。
/// 参考实现：https://github.com/stasel/WebRTC-iOS
final class WebRTCClient: NSObject {

    // MARK: - 回调
    var onLocalSdp: ((String, String) -> Void)?             // (type, sdp)
    var onIceCandidate: (([String: Any]) -> Void)?          // ice candidate dict
    var onIceConnected: (() -> Void)?
    var onIceDisconnected: (() -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?

    // MARK: - 内部
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoCapturer: RTCVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?

    private let rtcQueue = DispatchQueue(label: "webrtc.queue")
    private(set) var isVideoEnabled = true
    private(set) var isAudioEnabled = true
    private let enableVideo: Bool

    static var isInitialized = false

    init(enableVideo: Bool) {
        self.enableVideo = enableVideo
        // 全局初始化（仅一次）
        if !WebRTCClient.isInitialized {
            RTCInitializeSSL()
            WebRTCClient.isInitialized = true
        }
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
        super.init()
    }

    // MARK: - 初始化本地媒体

    func startLocalMedia() {
        configureAudioSession()
        // 音频
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: [
            kRTCMediaConstraintsLevelControl: "true"
        ], optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "ARDAMS")

        // 视频
        if enableVideo {
            startVideoCapture()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("[WebRTC] 配置音频会话失败: \(error)")
        }
    }

    private func startVideoCapture() {
        let videoSource = factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        self.videoCapturer = capturer

        // 选择前置摄像头
        let position: AVCaptureDevice.Position = .front
        guard let device = (AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position).devices.first) else {
            print("[WebRTC] 未找到摄像头")
            return
        }

        // 选最高支持格式中 FPS 合理的一档
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let targetWidth = 640
        let targetHeight = 480
        var selectedFormat: AVCaptureDevice.Format = formats.first ?? AVCaptureDevice.Format()
        var diff = Int.max
        for format in formats {
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let localDiff = abs(targetWidth - Int(dimension.width)) + abs(targetHeight - Int(dimension.height))
            if localDiff < diff {
                diff = localDiff
                selectedFormat = format
            }
        }
        let fps = (selectedFormat.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30).rounded()
        capturer.startCapture(with: device, format: selectedFormat, fps: Int(fps))

        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "ARDAMSv0")
    }

    // MARK: - PeerConnection

    func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = .all

        let constraints = RTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            print("[WebRTC] 创建 PeerConnection 失败")
            return
        }
        self.peerConnection = pc

        // 添加本地 track
        if let audio = localAudioTrack {
            pc.add(audio, streamIds: ["ARDAMS"])
        }
        if let video = localVideoTrack {
            pc.add(video, streamIds: ["ARDAMS"])
        }
    }

    // MARK: - 协商

    func createOffer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: "true",
                kRTCMediaConstraintsOfferToReceiveVideo: enableVideo ? "true" : "false"
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
                kRTCMediaConstraintsOfferToReceiveAudio: "true",
                kRTCMediaConstraintsOfferToReceiveVideo: enableVideo ? "true" : "false"
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
        localAudioTrack?.isEnabled = isAudioEnabled
        return !isAudioEnabled
    }

    func toggleCamera() -> Bool {
        isVideoEnabled.toggle()
        localVideoTrack?.isEnabled = isVideoEnabled
        return isVideoEnabled
    }

    func switchCamera() {
        (videoCapturer as? RTCCameraVideoCapturer)?.stopCapture {}
        // 简化处理：再次 start 用后置；这里仅占位，复杂切换留给后续优化
        // MVP 阶段建议保持前置
    }

    /// 把本地视频 track 绑到渲染视图
    func attachLocalVideo(to view: RTCMTLVideoView) {
        localVideoTrack?.add(view)
    }

    // MARK: - 释放

    deinit {
        peerConnection?.close()
    }
}

// MARK: - RTCPeerConnectionDelegate
// 方法签名针对 stasel/WebRTC pod 最新版协议更新。
extension WebRTCClient: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected: onIceConnected?()
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

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAddReceiver rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        if let video = track as? RTCVideoTrack {
            DispatchQueue.main.async { self.onRemoteVideoTrack?(video) }
        } else if let audio = track as? RTCAudioTrack {
            DispatchQueue.main.async { self.onRemoteAudioTrack?(audio) }
        }
    }
}
