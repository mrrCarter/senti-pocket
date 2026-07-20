import Foundation
#if canImport(CallKit) && !targetEnvironment(macCatalyst)
import CallKit

/// Forge prototype (pocket-forge): the "Senti is calling" ring as a REAL iOS call via CallKit.
/// CallKit's incoming-call UI (full-screen, rings, vibrates, shows on the lock screen) needs NO paid
/// account when reported from the foreground — so it's demoable today. The only account-gated piece is
/// the REMOTE trigger while the app is backgrounded/locked, which needs a VoIP PushKit push (VoIP cert =
/// PlexAura Developer account). This class is that seam: `ring()` presents the call now; later a PushKit
/// delegate calls the same `ring()` on a wake, so "Senti pings you → your phone rings" ships same-day the
/// account clears.
final class SentiCallManager: NSObject, CXProviderDelegate {
    static let shared = SentiCallManager()
    private let provider: CXProvider

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.includesCallsInRecents = false
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Present an incoming "Senti is calling" — rings + vibrates + shows the native call UI.
    func ring(callerName: String = "Senti is calling") {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Senti Pocket")
        update.localizedCallerName = callerName
        update.hasVideo = false
        provider.reportNewIncomingCall(with: UUID(), update: update) { error in
            if let error = error { NSLog("SentiCallKit ring error: \(error)") }
        }
    }

    /// DEMO: ring shortly after launch so a headless screenshot catches the native call UI.
    func scheduleDemoRing(after seconds: Double = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.ring()
        }
    }

    // CXProviderDelegate — minimal: accept answer/end so the demo call is interactive.
    func providerDidReset(_ provider: CXProvider) {}
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { action.fulfill() }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) { action.fulfill() }
}
#endif
