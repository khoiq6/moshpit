import AVFoundation
import RDPKit
import SwiftUI
import UIKit

enum NativeRDPQuality: Int, CaseIterable, Identifiable {
    case speed, balanced, quality
    var id: Int { rawValue }
    var width: UInt16 { [1280, 1600, 1920][rawValue] }
    var height: UInt16 { [720, 900, 1080][rawValue] }
    var title: String {
        switch self {
        case .speed: WindowsWords.text("Prefer speed")
        case .balanced: WindowsWords.text("Balanced")
        case .quality: WindowsWords.text("Prefer quality")
        }
    }
}

enum NativeRDPMouseMode: Int, CaseIterable, Identifiable {
    case direct, trackpad
    var id: Int { rawValue }
    var title: String { self == .direct ? WindowsWords.text("Direct touch") : WindowsWords.text("Trackpad") }
}

/// Reject other destinations and untrusted certificates before credentials go out.
/// A self-signed server can be accepted for this session only after comparison
/// with its fingerprint from a trusted administrative channel.
enum NativeRDPTrust {
    static func accepts(expectedHost: String, actualHost: String, trusted: Bool,
                        fingerprint: String?, approved: String?) -> Bool {
        guard expectedHost.caseInsensitiveCompare(actualHost) == .orderedSame else { return false }
        if let approved {
            guard let fingerprint else { return false }
            return matchesFingerprint(fingerprint, expected: approved)
        }
        return trusted
    }

    static func matchesFingerprint(_ input: String, expected: String) -> Bool {
        guard let digest = canonicalFingerprint(input) else { return false }
        return digest == canonicalFingerprint(expected)
    }

    private static func canonicalFingerprint(_ value: String) -> String? {
        let digest = value.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return digest.lowercased()
    }
}

enum NativeRDPFailure {
    static func message(for failure: RDPConnectionFailure?, showedDesktop: Bool) -> String.LocalizationValue {
        switch failure {
        case .addressResolution?:
            "RDP address could not be resolved"
        case .connect(error: let socket)?:
            switch socket.category {
            case .refused: "RDP port refused the connection"
            case .timedOut: "RDP server did not respond in time"
            default: "RDP server could not be reached"
            }
        case .noConnectionConfirm(reason: .unexpectedReply)?:
            "RDP port answered with another protocol"
        case .noConnectionConfirm(reason: .timedOut)?, .timedOut?:
            "RDP server did not respond in time"
        case .negotiation?, .unsupportedSecurityProtocol?, .legacyCredSSPVersion?, .tls?, .tlsKeyUsageIncorrect?:
            "RDP secure connection failed"
        case .credSSP(status: .logonTypeNotGranted)?, .earlyUserAuthorizationDenied?:
            "RDP account is not allowed"
        case .credSSP?, .credSSPClosedAfterCredentials?, .credentialsRequired?, .rdSTLS?:
            "RDP sign-in failed"
        case .noFramePresented?, .graphicsFrameHandler?:
            "RDP desktop did not appear"
        case .licensing?:
            "RDP licensing failed"
        case .invalidConfiguration?:
            "Invalid RDP address or credentials"
        case .noConnectionConfirm?, .connectionLost?, .connectionClosed?:
            showedDesktop ? "RDP connection was interrupted" : "RDP connection closed before the desktop appeared"
        case .serverTermination(termination: let termination)?:
            switch termination.category {
            case .accessDenied: "RDP account is not allowed"
            case .licensing: "RDP licensing failed"
            default: "RDP could not continue"
            }
        case .protocolViolation?, .clientFailure?:
            "RDP could not continue"
        case .cancelled?, nil:
            showedDesktop ? "RDP session ended" : "RDP connection closed before the desktop appeared"
        }
    }
}

@MainActor
final class NativeRDPController: ObservableObject {
    enum Phase {
        case idle, connecting, waitingForDesktop, verifyingCertificate, reconnecting, connected, ended
    }

    @Published private(set) var phase: Phase = .idle
    var connected: Bool { phase == .connected }
    var progressMessage: String? {
        switch phase {
        case .connecting: WindowsWords.text("Connecting RDP")
        case .waitingForDesktop: WindowsWords.text("Waiting for the RDP desktop")
        case .reconnecting: WindowsWords.text("Reconnecting RDP")
        default: nil
        }
    }
    @Published private(set) var error = ""
    @Published private(set) var pendingFingerprint: String?
    @Published private(set) var fps = 0.0
    @Published private(set) var mbps = 0.0
    @Published private(set) var decodeMS = 0.0
    @Published private(set) var frameAgeMS = 0.0
    @Published private(set) var profile: NativeRDPQuality = .balanced
    @Published private(set) var resolution = ""
    @Published private(set) var remoteClipboardAvailable = false
    @Published var mouseMode: NativeRDPMouseMode = .direct
    @Published var automaticQuality = true
    @Published var autoReconnect = true
    private var session: RDPLiveSession?
    private var configuration: RDPConnectionConfiguration?
    private var approvedFingerprint: String?
    private var retryTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var textTask: Task<Void, Never>?
    private var generation = UUID()
    private var retries = 0
    private var input: RDPInputSession?
    private var display: RDPDisplayControlSession?
    private var clipboard: RDPClipboardSession?
    private var remoteText: String?
    private var remoteCopyNumber: Int?
    private let metrics = RDPRenderMetricsStore()
    private var preferredQuality: NativeRDPQuality = .balanced
    private var slowWindows = 0
    private var goodWindows = 0
    private var frameCount = 0
    private var presentedCount = 0
    private var lastTick = Date()
    private var latestAge = 0.0
    private var remotePoint = RDPRemotePoint(x: 0, y: 0)
    private var pendingMove = false
    private var buttons = Set<RDPPointerButton>()
    private var heldKeys = Set<RDPKeyboardScancode>()
    fileprivate weak var canvas: NativeRDPCanvas?
    fileprivate var desktopSize = CGSize.zero

    func connect(host: String, port: String, user: String, password: String, quality: NativeRDPQuality) {
        disconnect()
        guard let target = try? RDPConnectionTarget(host: host, portText: port),
              let credentials = try? RDPCredentials.validated(username: user, password: password) else {
            error = WindowsWords.text("Invalid RDP address or credentials")
            return
        }
        preferredQuality = quality
        profile = quality
        var config = RDPConnectionConfiguration(
            host: target.host, port: target.port, credentials: credentials,
            timeoutSeconds: 20, graphicsFrameCaptureLimit: nil,
            desktopWidth: quality.width, desktopHeight: quality.height,
            clipboardEnabled: true, clipboardFetchesRemoteCopies: false,
            audioPlaybackEnabled: false, clientName: "Moshpit"
        )
        // A retry can get past the iOS Local Network prompt. This only retries TCP, before sign-in.
        config.connectAttempts = 2
        start(config)
    }

    private func start(_ config: RDPConnectionConfiguration) {
        let id = UUID()
        generation = id
        configuration = config
        phase = .connecting
        error = ""
        pendingFingerprint = nil
        input = nil
        display = nil
        clipboard = nil
        remoteText = nil
        remoteCopyNumber = nil
        remoteClipboardAvailable = false
        desktopSize = .zero
        resolution = ""
        canvas?.clear()
        metrics.reset(connectionStartedAt: Date())
        slowWindows = 0; goodWindows = 0; frameCount = 0; presentedCount = 0
        fps = 0; mbps = 0; decodeMS = 0; frameAgeMS = 0; latestAge = 0; lastTick = Date()
        let live = RDPLiveSession()
        session = live
        let recipient = live.recipient(self)
        let approved = approvedFingerprint
        live.start(events: .init(
            onFrameDecoded: { [weak self] presentation, received, decoded, timing in
                guard let self, self.generation == id else { return }
                self.metrics.recordDecodedFrame(presentation.frame, receivedAt: received, decodedAt: decoded, timing: timing)
                self.receive(presentation, at: received)
            },
            onFrameDecodeFailed: { [weak self] date, reason in
                guard let self, self.generation == id else { return }
                self.metrics.recordDecodeFailure(receivedAt: date, errorDescription: reason)
            },
            onWireReceive: { [weak self] sample in
                guard let self, self.generation == id else { return }
                self.metrics.recordWireReceive(sample)
            },
            onEnd: { report in
                recipient.deliver { controller in controller.ended(report, id: id) }
            }
        )) { run in
            RDPSessionClient().run(configuration: config,
                onGraphicsFrame: run.onGraphicsFrame,
                onInputReady: { input in
                    recipient.deliver { controller in
                        guard controller.generation == id else { return }
                        controller.releaseInput()
                        controller.input = input
                        if controller.phase == .connecting { controller.phase = .waitingForDesktop }
                    }
                },
                onDisplayControlReady: { display in
                    recipient.deliver { controller in
                        guard controller.generation == id else { return }
                        controller.display = display
                    }
                },
                onClipboardReady: { clipboard in
                    recipient.deliver { controller in
                        guard controller.generation == id else { return }
                        controller.clipboard = clipboard
                    }
                },
                onClipboardText: { text, number in
                    recipient.deliver { controller in
                        guard controller.generation == id, let clipboard = controller.clipboard,
                              clipboard.fetchesRemoteCopies else { return }
                        controller.remoteText = String(text.prefix(256_000))
                        controller.remoteCopyNumber = number
                        controller.remoteClipboardAvailable = true
                        clipboard.fetchesRemoteCopies = false
                    }
                },
                onCertificate: { cert in
                    guard NativeRDPTrust.accepts(expectedHost: config.host, actualHost: cert.host,
                        trusted: cert.trusted, fingerprint: cert.sha256, approved: approved) else {
                        // Cancel synchronously on the session thread, before any credentials.
                        run.cancellation.cancel()
                        recipient.deliver { controller in
                            guard controller.generation == id else { return }
                            controller.session = nil
                            controller.error = WindowsWords.text("Untrusted RDP certificate")
                            // Do not offer trust on an unexpected redirection or a changed pin.
                            if approved == nil, cert.host.caseInsensitiveCompare(config.host) == .orderedSame,
                               let fingerprint = cert.sha256 {
                                controller.phase = .verifyingCertificate
                                controller.pendingFingerprint = fingerprint
                            } else {
                                controller.phase = .ended
                                controller.configuration = nil
                                controller.approvedFingerprint = nil
                            }
                        }
                        return
                    }
                },
                onWireReceive: run.onWireReceive,
                liveReport: run.liveReport,
                cancellation: run.cancellation)
        }
    }

    func acceptFingerprint(_ verifiedFingerprint: String) {
        guard let fingerprint = pendingFingerprint, let config = configuration else { return }
        guard NativeRDPTrust.matchesFingerprint(verifiedFingerprint, expected: fingerprint) else {
            error = WindowsWords.text("RDP fingerprint mismatch")
            return
        }
        approvedFingerprint = fingerprint
        start(config)
    }

    private func ended(_ report: RDPConnectionReport, id: UUID) {
        guard generation == id else { return }
        let wasRendered = connected
        session = nil
        presentationTask?.cancel(); presentationTask = nil
        releaseInput()
        input = nil; display = nil; clipboard = nil
        remoteText = nil; remoteCopyNumber = nil; remoteClipboardAvailable = false
        canvas?.clear()
        let networkFailure: Bool
        switch report.failure {
        case .connectionLost?, .connectionClosed?, .timedOut?, .connect?: networkFailure = true
        default: networkFailure = false
        }
        if autoReconnect, report.remoteTermination == nil, retries < 2, var config = configuration,
           report.targetHost.caseInsensitiveCompare(config.host) == .orderedSame,
           report.targetPort == config.port {
            if case .noFramePresented? = report.failure, config.graphicsCapabilityProfile == .automatic {
                // Retry the first frame once with the library's non-AVC graphics profile.
                config.graphicsCapabilityProfile = .legacy
            } else if networkFailure, wasRendered || retries > 0 {
                config.autoReconnectCookie = report.rdpAutoReconnectCookie ?? config.autoReconnectCookie
            } else {
                finish(report, wasRendered: wasRendered)
                return
            }
            retries += 1
            phase = .reconnecting
            retryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.generation == id else { return }
                self.retryTask = nil
                self.start(config)
            }
        } else {
            finish(report, wasRendered: wasRendered)
        }
    }

    private func finish(_ report: RDPConnectionReport, wasRendered: Bool) {
        phase = .ended
        error = WindowsWords.text(NativeRDPFailure.message(for: report.failure, showedDesktop: wasRendered))
        configuration = nil
        approvedFingerprint = nil
    }

    func disconnect() {
        generation = UUID()
        retryTask?.cancel(); retryTask = nil
        presentationTask?.cancel(); presentationTask = nil
        releaseInput()
        session?.cancel(); session = nil
        configuration = nil; approvedFingerprint = nil; pendingFingerprint = nil
        input = nil; display = nil; clipboard = nil
        remoteText = nil; remoteCopyNumber = nil; remoteClipboardAvailable = false
        phase = .idle; error = ""
        desktopSize = .zero; retries = 0
        fps = 0; mbps = 0; decodeMS = 0; frameAgeMS = 0; resolution = ""
        canvas?.clear()
    }

    private func receive(_ presentation: RDPDecodedFramePresentation, at date: Date) {
        let width = Int(presentation.frame.width), height = Int(presentation.frame.height)
        guard width > 0, height > 0 else { return }
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        if desktopSize != size {
            desktopSize = size
            resolution = "\(width) × \(height)"
            remotePoint = bounded(CGPoint(x: CGFloat(remotePoint.x), y: CGFloat(remotePoint.y)))
            canvas?.setNeedsLayout()
        }
        frameCount += 1
        canvas?.offer(presentation, receivedAt: date)
        // RDPKit stops waiting once it decodes a frame. Also bound the wait for our own display layer.
        if !connected, presentationTask == nil {
            let id = generation
            presentationTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, self.generation == id, !self.connected else { return }
                self.disconnect()
                self.error = WindowsWords.text("RDP desktop did not appear")
                self.phase = .ended
            }
        }
    }

    fileprivate func frameEnqueued(at received: Date) {
        if !connected {
            presentationTask?.cancel(); presentationTask = nil
            phase = .connected
        }
        presentedCount += 1
        latestAge = max(0, Date().timeIntervalSince(received) * 1000)
    }

    /// Resolution is adaptive only if the server supports Display Control.
    /// Do not lower quality because a static screen naturally has few frames.
    func updateMetrics() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        guard elapsed >= 0.8 else { return }
        let current = metrics.metrics
        fps = Double(presentedCount) / elapsed
        mbps = current.rollingWireMegabitsPerSecond(at: now) ?? 0
        decodeMS = current.lastDecodeMilliseconds ?? 0
        frameAgeMS = latestAge
        let activeFrames = frameCount
        let skipped = max(0, frameCount - presentedCount)
        frameCount = 0; presentedCount = 0; lastTick = now
        guard automaticQuality, connected, activeFrames > 4,
              let display, !display.isLastSentLayoutPending else { return }
        if decodeMS > 25 || frameAgeMS > 100 || skipped > activeFrames / 3 {
            slowWindows += 1; goodWindows = 0
        } else if decodeMS < 12 && frameAgeMS < 45 && skipped == 0 {
            goodWindows += 1; slowWindows = 0
        } else { slowWindows = 0; goodWindows = 0 }
        if slowWindows >= 3, let next = NativeRDPQuality(rawValue: profile.rawValue - 1) {
            requestQuality(next)
        } else if goodWindows >= 15, profile.rawValue < preferredQuality.rawValue,
                  let next = NativeRDPQuality(rawValue: profile.rawValue + 1) {
            requestQuality(next)
        }
    }

    private func requestQuality(_ quality: NativeRDPQuality) {
        guard let display else { return }
        let request = RDPDisplayRequest(width: UInt32(quality.width), height: UInt32(quality.height),
            scaleFactors: .init(desktopScaleFactor: 100, deviceScaleFactor: 100))
        if display.send(request) {
            profile = quality
            if var config = configuration {
                config.desktopWidth = quality.width; config.desktopHeight = quality.height
                configuration = config
            }
        }
        slowWindows = 0; goodWindows = 0
    }

    fileprivate func bounded(_ p: CGPoint) -> RDPRemotePoint {
        let maxX = max(0, min(65535, desktopSize.width - 1))
        let maxY = max(0, min(65535, desktopSize.height - 1))
        return RDPRemotePoint(x: UInt16(min(maxX, max(0, p.x))), y: UInt16(min(maxY, max(0, p.y))))
    }

    fileprivate func move(to point: CGPoint) {
        guard connected, desktopSize.width > 0 else { return }
        remotePoint = bounded(point)
        pendingMove = true
        canvas?.showPointer(remotePoint)
    }

    fileprivate func move(delta: CGPoint) {
        move(to: CGPoint(x: CGFloat(remotePoint.x) + delta.x, y: CGFloat(remotePoint.y) + delta.y))
    }

    fileprivate func flushMove() {
        guard pendingMove else { return }
        pendingMove = false
        input?.send(.pointerMove(x: remotePoint.x, y: remotePoint.y))
    }

    func button(_ button: RDPPointerButton, down: Bool) {
        guard let input, connected else { return }
        if down {
            guard buttons.insert(button).inserted else { return }
        } else {
            guard buttons.remove(button) != nil else { return }
        }
        flushMove()
        input.send(.pointerButton(button: button, isDown: down, x: remotePoint.x, y: remotePoint.y))
    }

    func click(_ button: RDPPointerButton) {
        self.button(button, down: true); self.button(button, down: false)
    }

    fileprivate func wheel(_ rotation: Int) {
        flushMove()
        input?.send(.verticalWheel(rotation: rotation, x: remotePoint.x, y: remotePoint.y))
    }

    func key(_ scancode: RDPKeyboardScancode, down: Bool) {
        guard let input, connected else { return }
        if down {
            let inserted = heldKeys.insert(scancode).inserted
            input.send(.keyboard(scancode: scancode, isReleased: false, wasDown: !inserted))
        } else if heldKeys.remove(scancode) != nil {
            input.send(.keyboard(scancode: scancode, isReleased: true))
        }
    }

    func tapKey(_ code: UInt16, extended: Bool = false) {
        let scan = RDPKeyboardScancode(code: code, isExtended: extended)
        key(scan, down: true); key(scan, down: false)
    }

    func typeText(_ text: String) {
        guard let input, input.supportsUnicodeInput, connected else {
            error = WindowsWords.text("Unicode input unavailable")
            return
        }
        textTask?.cancel()
        let units = Array(text.utf16.prefix(8192))
        textTask = Task { @MainActor [weak self] in
            for unit in units {
                guard !Task.isCancelled, let self, self.input === input, self.connected else { return }
                input.send([.unicode(codeUnit: unit, isReleased: false), .unicode(codeUnit: unit, isReleased: true)])
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
    }

    func sendClipboard() {
        guard let clipboard, let text = UIPasteboard.general.string else { return }
        clipboard.publishLocalContent(RDPClipboardContent(text: String(text.prefix(256_000))))
        remoteClipboardAvailable = false; remoteText = nil; remoteCopyNumber = nil
    }

    func requestClipboard() {
        guard let clipboard else { return }
        remoteClipboardAvailable = false; remoteText = nil; remoteCopyNumber = nil
        clipboard.fetchesRemoteCopies = true
    }

    func copyRemoteClipboard() {
        guard let clipboard, let text = remoteText, let number = remoteCopyNumber,
              !clipboard.hasPublished(since: number) else { return }
        UIPasteboard.general.string = text
        remoteText = nil; remoteCopyNumber = nil; remoteClipboardAvailable = false
    }

    func releaseInput() {
        textTask?.cancel(); textTask = nil
        flushMove()
        if let input {
            for button in buttons {
                input.send(.pointerButton(button: button, isDown: false, x: remotePoint.x, y: remotePoint.y))
            }
            for key in heldKeys { input.send(.keyboard(scancode: key, isReleased: true)) }
        }
        buttons.removeAll(); heldKeys.removeAll()
    }
}

/// UIKit surface: the newest fully decoded frame replaces an older pending
/// frame; the AVFoundation display layer avoids a CGImage conversion per frame.
/// Input button transitions are sent immediately; pointer motion is coalesced.
@MainActor
final class NativeRDPCanvas: UIView, UIGestureRecognizerDelegate {
    weak var controller: NativeRDPController?
    private let video = AVSampleBufferDisplayLayer()
    private let buffers = RDPFrameSampleBufferFactory()
    private var latest: (RDPDecodedFramePresentation, Date)?
    private var link: CADisplayLink?
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private let cursor = CAShapeLayer()
    private var pointer: RDPRemotePoint?
    private var directDragging = false
    private var scrollRemainder: CGFloat = 0
    private let directTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    private let indirectTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; clipsToBounds = true; isMultipleTouchEnabled = true
        video.videoGravity = .resize
        layer.addSublayer(video)
        cursor.strokeColor = UIColor.white.cgColor
        cursor.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
        cursor.lineWidth = 1.5
        cursor.path = UIBezierPath(ovalIn: CGRect(x: -5, y: -5, width: 10, height: 10)).cgPath
        cursor.isHidden = true
        layer.addSublayer(cursor)
        let touch = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        touch.allowedTouchTypes = directTypes
        let right = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        right.minimumPressDuration = 0.45; right.allowedTouchTypes = directTypes
        touch.require(toFail: right)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.maximumNumberOfTouches = 1; pan.allowedTouchTypes = directTypes
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        scroll.allowedTouchTypes = directTypes
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        wheel.allowedTouchTypes = []
        wheel.allowedScrollTypesMask = [.continuous, .discrete]
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(magnify(_:)))
        pinch.delegate = self; scroll.delegate = self
        let mouse = UITapGestureRecognizer(target: self, action: #selector(mouseClick(_:)))
        mouse.allowedTouchTypes = indirectTypes; mouse.buttonMaskRequired = .primary
        let mouseRight = UITapGestureRecognizer(target: self, action: #selector(mouseClick(_:)))
        mouseRight.allowedTouchTypes = indirectTypes; mouseRight.buttonMaskRequired = .secondary
        let mouseDrag = UIPanGestureRecognizer(target: self, action: #selector(physicalDrag(_:)))
        mouseDrag.allowedTouchTypes = indirectTypes
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        [touch,right,pan,scroll,wheel,pinch,mouse,mouseRight,mouseDrag,hover].forEach { addGestureRecognizer($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, link == nil {
            let display = CADisplayLink(target: self, selector: #selector(tick))
            display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            display.add(to: .main, forMode: .common)
            link = display
            becomeFirstResponder()
        } else if window == nil {
            stop()
        }
    }

    func stop() {
        link?.invalidate(); link = nil
        controller?.releaseInput()
        clear()
    }

    func clear() {
        latest = nil; buffers.reset(); video.flushAndRemoveImage()
        pointer = nil; cursor.isHidden = true; zoom = 1; offset = .zero
    }

    func offer(_ frame: RDPDecodedFramePresentation, receivedAt: Date) {
        latest = (frame, receivedAt)
    }

    @objc private func tick() {
        controller?.flushMove()
        if video.status == .failed { video.flush(); buffers.reset() }
        guard video.isReadyForMoreMediaData, let (presentation, date) = latest else { return }
        latest = nil
        do {
            if buffers.willChangeDisplayFormat(for: presentation) { video.flushAndRemoveImage() }
            video.enqueue(try buffers.makeSampleBuffer(for: presentation))
            controller?.frameEnqueued(at: date)
        } catch { buffers.reset(); video.flush() }
    }

    private var desktopRect: CGRect {
        guard let size = controller?.desktopSize, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height) * zoom
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: bounds.midX - width/2 + offset.x, y: bounds.midY - height/2 + offset.y, width: width, height: height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = desktopRect
        if let pointer { placePointer(pointer) }
        CATransaction.commit()
    }
    private func toRemote(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        guard let size = controller?.desktopSize, size.width > 0 else { return nil }
        let rect = desktopRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) * size.width / rect.width,
                       y: (point.y - rect.minY) * size.height / rect.height)
    }
    fileprivate func showPointer(_ point: RDPRemotePoint) {
        pointer = point
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placePointer(point)
        CATransaction.commit()
    }
    private func placePointer(_ point: RDPRemotePoint) {
        guard let size = controller?.desktopSize, size.width > 0, size.height > 0 else { return }
        let rect = desktopRect
        cursor.position = CGPoint(x: rect.minX + CGFloat(point.x)/size.width*rect.width,
                                  y: rect.minY + CGFloat(point.y)/size.height*rect.height)
        cursor.isHidden = false
    }
    @objc private func tap(_ g: UITapGestureRecognizer) {
        becomeFirstResponder()
        if controller?.mouseMode == .direct {
            guard let p = toRemote(g.location(in: self)) else { return }
            controller?.move(to: p)
        }
        controller?.click(.left)
    }
    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        if controller?.mouseMode == .direct {
            guard let p = toRemote(g.location(in: self)) else { return }
            controller?.move(to: p)
        }
        controller?.click(.right)
    }
    @objc private func drag(_ g: UIPanGestureRecognizer) {
        guard let controller else { return }
        if controller.mouseMode == .trackpad {
            let delta = g.translation(in: self)
            let scale = controller.desktopSize.width / max(1, desktopRect.width)
            controller.move(delta: CGPoint(x: delta.x*scale, y: delta.y*scale))
            g.setTranslation(.zero, in: self)
        } else {
            if g.state == .began, let p = toRemote(g.location(in: self)) {
                controller.move(to: p); controller.button(.left, down: true); directDragging = true
            }
            if directDragging, let p = toRemote(g.location(in: self), clamp: true) { controller.move(to: p) }
            if [.ended,.cancelled,.failed].contains(g.state), directDragging {
                controller.button(.left, down: false); directDragging = false
            }
        }
    }
    @objc private func scroll(_ g: UIPanGestureRecognizer) {
        let delta = g.translation(in: self).y
        g.setTranslation(.zero, in: self)
        scrollRemainder += delta
        let steps = Int(scrollRemainder / 18)
        if steps != 0 { controller?.wheel(steps * 120); scrollRemainder -= CGFloat(steps)*18 }
        if [.ended,.cancelled,.failed].contains(g.state) { scrollRemainder = 0 }
    }
    @objc private func magnify(_ g: UIPinchGestureRecognizer) {
        let oldRect = desktopRect
        let point = g.location(in: self)
        let relative = CGPoint(x: (point.x-oldRect.minX)/max(1,oldRect.width), y: (point.y-oldRect.minY)/max(1,oldRect.height))
        zoom = min(4, max(1, zoom * g.scale)); g.scale = 1
        let next = desktopRect
        offset.x += point.x - (next.minX + relative.x*next.width)
        offset.y += point.y - (next.minY + relative.y*next.height)
        let maxX = max(0, (next.width-bounds.width)/2), maxY = max(0, (next.height-bounds.height)/2)
        offset.x = min(maxX, max(-maxX, offset.x)); offset.y = min(maxY, max(-maxY, offset.y))
        if zoom == 1 { offset = .zero }
        setNeedsLayout()
    }
    @objc private func mouseClick(_ g: UITapGestureRecognizer) {
        guard let p = toRemote(g.location(in: self)) else { return }
        becomeFirstResponder()
        controller?.move(to: p)
        controller?.click(g.buttonMaskRequired == .secondary ? .right : .left)
    }
    @objc private func physicalDrag(_ g: UIPanGestureRecognizer) {
        guard let p = toRemote(g.location(in: self), clamp: directDragging) else { return }
        controller?.move(to: p)
        if g.state == .began { controller?.button(.left, down: true); directDragging = true }
        if [.ended,.cancelled,.failed].contains(g.state), directDragging {
            controller?.button(.left, down: false); directDragging = false
        }
    }
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        if let p = toRemote(g.location(in: self)) { controller?.move(to: p) }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    /// USB HID usage → Windows set-1 scancode. Physical keyboard uses
    /// scancodes so modifiers and shortcuts reach Windows, not iOS text.
    private func scan(_ press: UIPress) -> RDPKeyboardScancode? {
        guard let hid = press.key?.keyCode.rawValue else { return nil }
        let letters: [UInt16] = [0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c]
        if (4...29).contains(hid) { return .init(code: letters[Int(hid-4)]) }
        if (30...39).contains(hid) { return .init(code: UInt16(hid-28)) }
        let normal: [Int:UInt16] = [40:0x1c,41:0x01,42:0x0e,43:0x0f,44:0x39,45:0x0c,46:0x0d,47:0x1a,48:0x1b,49:0x2b,51:0x27,52:0x28,53:0x29,54:0x33,55:0x34,56:0x35,57:0x3a,68:0x57,69:0x58,224:0x1d,225:0x2a,226:0x38,229:0x36]
        let extended: [Int:UInt16] = [73:0x52,74:0x47,75:0x49,76:0x53,77:0x4f,78:0x51,79:0x4d,80:0x4b,81:0x50,82:0x48,227:0x5b,228:0x1d,230:0x38,231:0x5c]
        if (58...67).contains(hid) { return .init(code: UInt16(hid-58+0x3b)) }
        if let code = normal[Int(hid)] { return .init(code: code) }
        if let code = extended[Int(hid)] { return .init(code: code, isExtended: true) }
        return nil
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { press in
            guard let code = scan(press) else { return true }
            controller?.key(code, down: true); return false
        }
        if !rest.isEmpty { super.pressesBegan(Set(rest), with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { press in
            guard let code = scan(press) else { return true }
            controller?.key(code, down: false); return false
        }
        if !rest.isEmpty { super.pressesEnded(Set(rest), with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        controller?.releaseInput()
        super.pressesCancelled(presses, with: event)
    }
    override func resignFirstResponder() -> Bool {
        controller?.releaseInput()
        return super.resignFirstResponder()
    }
}

private struct NativeRDPSurface: UIViewRepresentable {
    let controller: NativeRDPController
    func makeUIView(context: Context) -> NativeRDPCanvas {
        let canvas = NativeRDPCanvas(frame: .zero)
        canvas.controller = controller
        controller.canvas = canvas
        return canvas
    }
    func updateUIView(_ uiView: NativeRDPCanvas, context: Context) {}
    static func dismantleUIView(_ uiView: NativeRDPCanvas, coordinator: ()) { uiView.stop() }
}

struct NativeRDPView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var controller = NativeRDPController()
    @AppStorage("nativeRDP.host") private var host = ""
    @AppStorage("nativeRDP.user") private var user = "Administrator"
    @AppStorage("nativeRDP.port") private var port = "3389"
    @State private var password = ""
    @State private var quality: NativeRDPQuality = .balanced
    @State private var showTextInput = false
    @State private var typedText = ""
    @State private var verifyFingerprint = ""
    @State private var confirmTrust = false
    @State private var leftHeld = false

    private var showingSession: Bool { controller.phase != .idle }

    var body: some View {
        NavigationStack {
            Group {
                if showingSession {
                    VStack(spacing: 0) {
                        NativeRDPSurface(controller: controller)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay {
                                if let progress = controller.progressMessage {
                                    ProgressView(progress).padding(16)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                } else if !controller.connected, !controller.error.isEmpty {
                                    VStack(spacing: 12) {
                                        Text(controller.error)
                                        if let fingerprint = controller.pendingFingerprint {
                                            Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                                            Button(WindowsWords.text("Verify server fingerprint")) {
                                                verifyFingerprint = ""; confirmTrust = true
                                            }
                                        }
                                    }
                                    .multilineTextAlignment(.center)
                                    .padding(16)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    .padding(.horizontal)
                                }
                            }
                        if controller.connected {
                            HStack {
                                Text(String(format: "%.0f FPS · %.1f Mbps", controller.fps, controller.mbps))
                                Spacer()
                                Text(controller.resolution)
                            }
                            .font(.caption.monospacedDigit()).padding(6)
                            Text(String(format: "Decode %.1f ms · Frame %.1f ms", controller.decodeMS, controller.frameAgeMS))
                                .font(.caption2.monospacedDigit())
                            if !controller.error.isEmpty {
                                Text(controller.error).font(.caption).foregroundStyle(.secondary).padding(4)
                            }
                            HStack {
                                Picker(WindowsWords.text("Mouse mode"), selection: $controller.mouseMode) {
                                    ForEach(NativeRDPMouseMode.allCases) { Text($0.title).tag($0) }
                                }.pickerStyle(.segmented)
                                Button { controller.click(.right) } label: { Image(systemName: "cursorarrow.click.2") }
                                    .accessibilityLabel(WindowsWords.text("Right click"))
                                Button {
                                    leftHeld.toggle()
                                    controller.button(.left, down: leftHeld)
                                } label: { Image(systemName: leftHeld ? "lock.fill" : "hand.draw") }
                                    .accessibilityLabel(WindowsWords.text("Hold left mouse button"))
                                Button { showTextInput = true } label: { Image(systemName: "keyboard") }
                                    .accessibilityLabel(WindowsWords.text("Send text"))
                                Menu {
                                    Button("Enter") { controller.tapKey(0x1c) }
                                    Button("Esc") { controller.tapKey(0x01) }
                                    Button("Tab") { controller.tapKey(0x0f) }
                                    Button("Backspace") { controller.tapKey(0x0e) }
                                    Button("↑") { controller.tapKey(0x48, extended: true) }
                                    Button("↓") { controller.tapKey(0x50, extended: true) }
                                    Button(WindowsWords.text("Send phone clipboard")) { controller.sendClipboard() }
                                    Button(WindowsWords.text("Request remote clipboard")) { controller.requestClipboard() }
                                    Button(WindowsWords.text("Copy remote clipboard")) { controller.copyRemoteClipboard() }
                                        .disabled(!controller.remoteClipboardAvailable)
                                    Toggle(WindowsWords.text("Adaptive resolution"), isOn: $controller.automaticQuality)
                                    Toggle(WindowsWords.text("Reconnect automatically"), isOn: $controller.autoReconnect)
                                } label: { Image(systemName: "ellipsis.circle") }
                            }.padding(8)
                        }
                    }
                } else {
                    Form {
                        Section(WindowsWords.text("Windows RDP native")) {
                            TextField(WindowsWords.text("Server address"), text: $host)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Port", text: $port).keyboardType(.numberPad)
                            TextField(WindowsWords.text("Username"), text: $user).textInputAutocapitalization(.never)
                            SecureField(WindowsWords.text("Password"), text: $password)
                            Picker(WindowsWords.text("Performance"), selection: $quality) {
                                ForEach(NativeRDPQuality.allCases) { Text($0.title).tag($0) }
                            }
                            Toggle(WindowsWords.text("Adaptive resolution"), isOn: $controller.automaticQuality)
                            Toggle(WindowsWords.text("Reconnect automatically"), isOn: $controller.autoReconnect)
                            Button(WindowsWords.text("Connect to Windows")) {
                                controller.connect(host: host, port: port, user: user, password: password, quality: quality)
                                if showingSession { password = "" }
                            }.disabled(host.isEmpty || port.isEmpty || user.isEmpty || password.isEmpty)
                            if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.secondary) }
                        }
                        Text(WindowsWords.text("Native RDP help")).font(.caption)
                    }
                }
            }
            .navigationTitle("RDP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(WindowsWords.text("Close")) { controller.disconnect(); dismiss() }
                }
                if showingSession {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(controller.progressMessage != nil || controller.connected
                            ? WindowsWords.text("Disconnect") : WindowsWords.text("RDP connection settings")) {
                            controller.disconnect(); leftHeld = false
                        }
                    }
                }
            }
            .sheet(isPresented: $showTextInput) {
                NavigationStack {
                    Form {
                        TextEditor(text: $typedText).frame(minHeight: 140)
                        Button(WindowsWords.text("Send text")) {
                            controller.typeText(typedText); typedText = ""; showTextInput = false
                        }.disabled(typedText.isEmpty)
                    }
                    .navigationTitle(WindowsWords.text("Send text"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button(WindowsWords.text("Close")) { typedText = ""; showTextInput = false }
                    } }
                }
            }
            .alert(WindowsWords.text("Verify server fingerprint"), isPresented: $confirmTrust) {
                TextField("SHA-256", text: $verifyFingerprint).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(WindowsWords.text("Trust for this session")) {
                    controller.acceptFingerprint(verifyFingerprint)
                    verifyFingerprint = ""
                }
                Button(WindowsWords.text("Cancel"), role: .cancel) { verifyFingerprint = "" }
            } message: { Text(WindowsWords.text("Fingerprint instruction")) }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                controller.updateMetrics()
            }
        }
        .onChange(of: controller.connected) { _, connected in if !connected { leftHeld = false } }
        .onChange(of: controller.mouseMode) { _, _ in controller.releaseInput(); leftHeld = false }
        .onChange(of: phase) { _, value in
            if value != .active { controller.releaseInput(); leftHeld = false }
            if value == .background { controller.disconnect(); password = "" }
        }
        .onDisappear { controller.disconnect(); password = ""; typedText = "" }
    }
}
