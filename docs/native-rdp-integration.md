# Native RDP: experimental integration

Pinned upstream https://github.com/steelbrain/RDPKit/tree/086985d0f9fd9629e8ff231128e5784cef4644f5 (MIT), with Apple VideoToolbox hardware decoding and direct TCP RDP. No gateway required on this path. The old HTTPS gateway is still available.

The new iOS screen includes a session-thread-backed client, strict host/certificate decision before credentials, explicit session-only fingerprint verification, latest-frame display queue, 60Hz presentation ceiling, touch/relative mouse, physical pointer and keyboard event forwarding, wheel, zoom, clipboard actions, bounded reconnect for network errors, and resolution reduction/recovery using measured decode/presentation pressure when RDP Display Control is available.

No frame-rate or input-latency guarantee. Presentation counter measures frames enqueued, not actual photons. Frame age is receive-to-enqueue, not network RTT. The iOS application has not been compiled against the pinned library or tested with Windows. Bluetooth mouse behavior on iPhone and actual RDP compatibility require on-device testing. Never disable trust checks. No Windows password is stored in preferences. Clipboard retrieval is explicit.

Next validation: resolve SwiftPM dependencies, typecheck with iOS SDK, test trusted/untrusted/pinned cert and redirection, verify input coordinate mapping at each resolution, Wi-Fi/5G tests, thermal/memory tests, actual remote Windows on RDP and NLA.
