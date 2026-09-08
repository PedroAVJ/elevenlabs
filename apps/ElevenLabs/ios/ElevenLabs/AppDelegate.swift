internal import Expo
import React
import ReactAppDependencyProvider
import UIKit

@main
@MainActor
final class ElevenLabsAppDelegate: ExpoAppDelegate {
    private var launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    private var reactNativeDelegate: ExpoReactNativeFactoryDelegate?
    private var reactNativeFactory: RCTReactNativeFactory?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        self.launchOptions = launchOptions
        // A hard suspension can outlive URLSession's cancellation cleanup.
        // Launch is the only safe time to sweep a prior process's exact private
        // upload artifacts, before this process can start a transcription.
        Observability.start()
        Observability.logStarted(surface: "ios")
        ElevenLabsClient.cleanupAbandonedMultipartUploads()
#if DEBUG
        seedAPIKeyFromEnvironmentIfNeeded()
#else
        // The production EAS build injects the operator-configured private-beta key at archive
        // time. Move it into this app identity's Keychain before AppModel is
        // created so TestFlight launches ready to dictate. The bootstrap never
        // logs or returns credential material.
        _ = PrivateBetaAPIKeyBootstrap().installIfPresent()
#endif
        let delegate = ElevenLabsReactNativeDelegate()
        let factory = ExpoReactNativeFactory(delegate: delegate)
        delegate.dependencyProvider = RCTAppDependencyProvider()
        reactNativeDelegate = delegate
        reactNativeFactory = factory

        return super.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
    }

#if DEBUG
    /// A Mac cannot write to the device Keychain, so installing a debug build
    /// leaves the app with no key until someone types one. Let a debug launch
    /// seed it once from the environment instead. `scripts/install-iphone.sh`
    /// passes it through `DEVICECTL_CHILD_ELEVENLABS_API_KEY`, so the value
    /// never reaches the source tree, the app bundle, or a command line.
    /// Release builds do not contain this path.
    private func seedAPIKeyFromEnvironmentIfNeeded() {
        guard
            let value = ProcessInfo.processInfo
                .environment["ELEVENLABS_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return
        }
        // Overwrite rather than only filling a gap, so rotating the key on the
        // Mac and re-running the install script keeps the phone in sync.
        let keychain = KeychainStore()
        var saveError: String?
        if keychain.load() != value {
            do {
                try keychain.save(value)
            } catch {
                saveError = error.localizedDescription
            }
        }
        recordKeychainSeedResult(
            storedKey: keychain.load() != nil,
            saveError: saveError
        )
    }

    /// Report only whether a key is present, never the key itself, so an
    /// install can be verified from the Mac without a dictation run.
    private func recordKeychainSeedResult(storedKey: Bool, saveError: String?) {
        guard
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else {
            return
        }
        let report: [String: Any] = [
            "hasAPIKey": storedKey,
            "saveError": saveError ?? "none",
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        try? data.write(
            to: directory.appendingPathComponent("last-install-check.json"),
            options: .atomic
        )
    }
#endif

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = ElevenLabsSceneDelegate.self
        return configuration
    }

    func startReactNative(in window: UIWindow) {
        guard let reactNativeFactory else {
            fatalError("React Native was not initialized before scene connection")
        }
        reactNativeFactory.startReactNative(
            withModuleName: "main",
            in: window,
            launchOptions: launchOptions
        )
    }
}

private final class ElevenLabsReactNativeDelegate: ExpoReactNativeFactoryDelegate {
    override func sourceURL(for bridge: RCTBridge) -> URL? {
        bridge.bundleURL ?? bundleURL()
    }

    override func bundleURL() -> URL? {
#if DEBUG
        RCTBundleURLProvider.sharedSettings().jsBundleURL(
            forBundleRoot: ".expo/.virtual-metro-entry"
        )
#else
        Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
    }
}

@MainActor
final class ElevenLabsSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// The coordinator keeps the exact native recording engine alive while
    /// React Native owns the containing app UI. This remains computed so a
    /// cold Live Activity launch captures its four-second host lease before
    /// AppModel restores journals.
    private var model: AppModel { ElevenLabsCoordinator.shared.model }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Capture every URL context before constructing AppModel. The value is
        // still subject to the existing short lease and exact supported-host
        // catalog; this only preserves evidence that was valid when iOS
        // delivered the user's Live Activity tap.
        let incomingURLs = connectionOptions.urlContexts.map { context in
            let sourceApplication = context.options.sourceApplication
                ?? connectionOptions.sourceApplication
            return (
                url: context.url,
                sourceApplication: sourceApplication,
                liveActivityContext: LiveActivityLaunchContext.capture(
                    for: context.url,
                    sourceApplication: sourceApplication
                )
            )
        }

        _ = model
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        guard let appDelegate = UIApplication.shared.delegate
            as? ElevenLabsAppDelegate else {
            fatalError("ElevenLabsAppDelegate is unavailable")
        }
        appDelegate.startReactNative(in: window)
        window.makeKeyAndVisible()

        for incomingURL in incomingURLs {
            handleIncomingURL(
                incomingURL.url,
                sourceApplication: incomingURL.sourceApplication,
                liveActivityContext: incomingURL.liveActivityContext,
                deliveryRoute: "scene-connection"
            )
        }
        model.handleActivation()
    }

    func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) {
        for context in URLContexts {
            let liveActivityContext = LiveActivityLaunchContext.capture(
                for: context.url,
                sourceApplication: context.options.sourceApplication
            )
            handleIncomingURL(
                context.url,
                sourceApplication: context.options.sourceApplication,
                liveActivityContext: liveActivityContext,
                deliveryRoute: "scene-open-url"
            )
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        model.handleActivation()
    }

    private func handleIncomingURL(
        _ url: URL,
        sourceApplication: String?,
        liveActivityContext: LiveActivityLaunchContext?,
        deliveryRoute: String
    ) {
        model.captureLiveActivityLaunchContext(
            liveActivityContext,
            for: url
        )
        captureReturnApplication(
            from: url,
            sourceApplication: sourceApplication,
            deliveryRoute: deliveryRoute
        )
        model.handleIncomingURL(url)
    }

    private func captureReturnApplication(
        from url: URL,
        sourceApplication: String?,
        deliveryRoute: String
    ) {
        guard
            url.scheme == "elevenlabs",
            url.host == "dictate",
            url.path == "/start",
            let sessionValue = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?
                .queryItems?
                .first(where: { $0.name == "session" })?
                .value,
            let sessionID = UUID(uuidString: sessionValue)
        else {
            return
        }

        let sharedStore = SharedDictationStore()
        let snapshot = sharedStore.load()
        guard snapshot.sessionID == sessionID else { return }

        sharedStore.setIncomingURLContext(
            deliveryRoute: deliveryRoute,
            sourceApplication: sourceApplication,
            sessionID: sessionID
        )

        guard
            let sourceApplication,
            HostAppSwitcher.isValidReturnBundleIdentifier(sourceApplication)
        else {
            return
        }
        sharedStore.setReturnBundleIdentifier(
            sourceApplication,
            sessionID: sessionID
        )
    }
}

/// Immutable evidence captured at the scene URL boundary. Holding this value
/// does not extend the App Group lease: it binds a lease that was already valid
/// to the exact Live Activity tap currently being delivered.
@MainActor
struct LiveActivityLaunchContext: Equatable {
    let visibleKeyboardHostLease: VisibleHostApplicationLease?
    let sourceBundleIdentifier: String?

    static func capture(
        for url: URL,
        sourceApplication: String?,
        visibleLeaseCache: VisibleHostApplicationLeaseCache =
            VisibleHostApplicationLeaseCache(),
        now: Date = Date()
    ) -> LiveActivityLaunchContext? {
        guard
            url.scheme == "elevenlabs",
            url.host == "live-activity",
            ["/start", "/resume"].contains(url.path)
        else {
            return nil
        }

        let visibleLease: VisibleHostApplicationLease?
        if
            let fresh = visibleLeaseCache.freshLease(now: now),
            HostAppSwitcher.supportsAutomaticReturn(
                to: fresh.bundleIdentifier
            )
        {
            visibleLease = fresh
        } else {
            visibleLease = nil
        }

        return LiveActivityLaunchContext(
            visibleKeyboardHostLease: visibleLease,
            sourceBundleIdentifier: HostAppSwitcher.appInfo(
                for: sourceApplication
            )?.bundleIdentifier
        )
    }
}

@MainActor
struct LiveActivityReturnTargetResolution: Equatable {
    enum Evidence: String, Equatable {
        case scenePreflight = "scene_preflight"
        case currentVisibleLease = "current_visible_lease"
        case sourceApplication = "source_application"
        case unavailable
    }

    let bundleIdentifier: String?
    let processIdentifier: Int32?
    let evidence: Evidence

    static func resolve(
        launchContext: LiveActivityLaunchContext?,
        currentVisibleLease: VisibleHostApplicationLease?
    ) -> LiveActivityReturnTargetResolution {
        if let lease = launchContext?.visibleKeyboardHostLease {
            return LiveActivityReturnTargetResolution(
                bundleIdentifier: lease.bundleIdentifier,
                processIdentifier: lease.processIdentifier,
                evidence: .scenePreflight
            )
        }
        if let lease = currentVisibleLease {
            return LiveActivityReturnTargetResolution(
                bundleIdentifier: lease.bundleIdentifier,
                processIdentifier: lease.processIdentifier,
                evidence: .currentVisibleLease
            )
        }
        if let sourceBundleIdentifier = launchContext?.sourceBundleIdentifier {
            return LiveActivityReturnTargetResolution(
                bundleIdentifier: sourceBundleIdentifier,
                processIdentifier: nil,
                evidence: .sourceApplication
            )
        }
        return LiveActivityReturnTargetResolution(
            bundleIdentifier: nil,
            processIdentifier: nil,
            evidence: .unavailable
        )
    }
}
