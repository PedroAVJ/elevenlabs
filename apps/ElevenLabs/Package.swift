// swift-tools-version: 6.0

import PackageDescription

/// A deliberately narrow package used to run the pure macOS regression suites
/// without launching either application target. The shipping products remain
/// defined by ios/ElevenLabs.xcodeproj.
let package = Package(
    name: "ElevenLabsMacLogic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ElevenLabsKeychain",
            path: "ios/ElevenLabs",
            exclude: [
                "AppModel.swift",
                "Assets.xcassets",
                "AudioRecorder.swift",
                "AudioRecorderStartPolicy.swift",
                "AudioDiagnosticsStore.swift",
                "ContentView.swift",
                "DictationActivityAttributes.swift",
                "DictationEngine.swift",
                "DictationIntents.swift",
                "DictationLiveActivity.swift",
                "ElevenLabsClient.swift",
                "HistoryStore.swift",
                "HistoryView.swift",
                "HostAppSwitcher.swift",
                "Info.plist",
                "KeyboardSetupStatus.swift",
                "SettingsView.swift",
                "SharedDictation.swift",
                "ElevenLabs.entitlements",
                "AppDelegate.swift",
                "TranscriptionModels.swift",
            ],
            sources: ["KeychainStore.swift"]
        ),
        .target(
            name: "ElevenLabsClient",
            path: "ios/ElevenLabs",
            exclude: [
                "AppModel.swift",
                "Assets.xcassets",
                "AudioRecorder.swift",
                "AudioDiagnosticsStore.swift",
                "ContentView.swift",
                "DictationActivityAttributes.swift",
                "DictationEngine.swift",
                "DictationIntents.swift",
                "DictationLiveActivity.swift",
                "HistoryStore.swift",
                "HistoryView.swift",
                "HostAppSwitcher.swift",
                "Info.plist",
                "KeyboardSetupStatus.swift",
                "KeychainStore.swift",
                "SettingsView.swift",
                "SharedDictation.swift",
                "ElevenLabs.entitlements",
                "AppDelegate.swift",
            ],
            sources: [
                "AudioRecorderStartPolicy.swift",
                "ElevenLabsClient.swift",
                "SegmentedDictationModel.swift",
                "TranscriptionModels.swift",
            ]
        ),
        .target(
            name: "ElevenLabs",
            path: "ios/ElevenLabsMac",
            exclude: [
                "MacAppModel.swift",
                "MacAudioDevice.swift",
                "MacAudioRecorder.swift",
                "MacSingleOutputAudioRecorder.swift",
                "MacSoundIsolationProcessor.swift",
                "MacVoiceIsolationProbe.swift",
                "MacContentView.swift",
                "MacGlobalHotKey.swift",
                "MacKeyboardLayout.swift",
                "MacKeyboardMap.swift",
                "MacPasteController.swift",
                "MacPermissions.swift",
                "MacReliabilityStore.swift",
                "MacSettingsView.swift",
                "MacSoundEffects.swift",
                "MacStatusHUD.swift",
                "Sounds",
                "ElevenLabsMacApp.swift",
            ],
            sources: [
                "MacDeliveryPolicyStore.swift",
                "MacDeliveryTarget.swift",
                "MacDiagnostics.swift",
                "MacHistoryStore.swift",
                "MacActiveCaptureRecovery.swift",
                "MacApplicationPresence.swift",
                "MacPendingAudioStore.swift",
                "MacPendingTranscriptStore.swift",
                "MacPasteVerification.swift",
                "MacDictationKeys.swift",
                "MacKeyboardMapModel.swift",
                "MacHUDActivity.swift",
                "MacInputMode.swift",
                "MacSingleInstanceLease.swift",
                "MacTranscriptionWorkload.swift",
                "MacTranscriptPostProcessor.swift",
                "MacVocabularyStore.swift",
            ]
        ),
        .testTarget(
            name: "ElevenLabsMacTests",
            dependencies: ["ElevenLabs", "ElevenLabsKeychain"],
            path: "ios/ElevenLabsMacTests"
        ),
        .testTarget(
            name: "ElevenLabsClientTests",
            dependencies: ["ElevenLabsClient"],
            path: "ios/ElevenLabsTests",
            exclude: [
                "HistoryStoreTests.swift",
                "SharedDictationStoreTests.swift",
                "Fixtures",
            ],
            sources: [
                "AudioRecorderStartPolicyTests.swift",
                "ElevenLabsClientTests.swift",
                "SegmentedDictationModelTests.swift",
            ],
            swiftSettings: [.define("ELEVENLABS_SWIFT_PACKAGE")]
        ),
    ]
)
