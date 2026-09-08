import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import test from "node:test";

const root = fileURLToPath(new URL("..", import.meta.url));
const expected = {
  "name": "elevenlabs",
  "version": "0.7.37",
  "url": "https://github.com/PedroAVJ/elevenlabs",
  "dependencies": []
};

async function json(...parts) {
  return JSON.parse(await readFile(join(root, ...parts), "utf8"));
}

function withoutCompileDisabledSwift(source) {
  const kept = [];
  let disabledDepth = 0;
  for (const line of source.split(/\r?\n/)) {
    if (/^\s*#if\s+false\b/.test(line)) {
      disabledDepth += 1;
      continue;
    }
    if (disabledDepth > 0 && /^\s*#if\b/.test(line)) {
      disabledDepth += 1;
      continue;
    }
    if (disabledDepth > 0 && /^\s*#endif\b/.test(line)) {
      disabledDepth -= 1;
      continue;
    }
    if (disabledDepth === 0) kept.push(line);
  }
  assert.equal(disabledDepth, 0, "compile-disabled Swift blocks must be balanced");
  return kept.join("\n");
}

test("plugin metadata is synchronized", async () => {
  const codex = await json(".codex-plugin", "plugin.json");
  assert.equal(codex.name, expected.name);
  assert.equal(codex.version, expected.version);
  assert.equal(codex.homepage, expected.url);
  assert.equal(codex.repository, expected.url);
  await access(join(root, "README.md"));
  await access(join(root, "AGENTS.md"));
  await access(join(root, "LICENSE"));

  if (expected.codexOnly) {
    await assert.rejects(access(join(root, ".claude-plugin", "plugin.json")));
  } else {
    const claude = await json(".claude-plugin", "plugin.json");
    assert.equal(claude.name, codex.name);
    assert.equal(claude.version, codex.version);
    assert.equal(claude.homepage, expected.url);
    assert.equal(claude.repository, expected.url);
    for (const dependency of expected.dependencies) {
      assert.ok((claude.dependencies ?? []).includes(dependency));
    }
  }

  const pkg = await json("package.json");
  assert.equal(pkg.version, expected.version);
  assert.equal(pkg.homepage, expected.url + "#readme");
  assert.equal(pkg.repository.url, "git+" + expected.url + ".git");
});

test("native Dictation Button interface is bundled and uses original artwork", async () => {
  const nativeRoot = join(root, "apps", "ElevenLabs");
  for (const path of [
    "AGENTS.md",
    "LICENSE",
    "Package.swift",
    "README.md",
    "ios/ElevenLabs.xcodeproj",
  ]) {
    await access(join(nativeRoot, path));
  }

  const iconRoot = join(
    nativeRoot,
    "ios",
    "ElevenLabs",
    "Assets.xcassets",
    "AppIcon.appiconset",
  );
  const expectedSizes = new Map([
    ["AppIcon-16.png", 16],
    ["AppIcon-32.png", 32],
    ["AppIcon-64.png", 64],
    ["AppIcon-128.png", 128],
    ["AppIcon-256.png", 256],
    ["AppIcon-512.png", 512],
    ["AppIcon-20@2x.png", 40],
    ["AppIcon-20@3x.png", 60],
    ["AppIcon-29@2x.png", 58],
    ["AppIcon-29@3x.png", 87],
    ["AppIcon-40@2x.png", 80],
    ["AppIcon-40@3x.png", 120],
    ["AppIcon-60@2x.png", 120],
    ["AppIcon-60@3x.png", 180],
    ["AppIcon.png", 1024],
    ["AppIcon-iOS.png", 1024],
  ]);

  for (const [name, expectedSize] of expectedSizes) {
    const png = await readFile(join(iconRoot, name));
    assert.equal(png.subarray(1, 4).toString(), "PNG", `${name} is a PNG`);
    assert.equal(png.readUInt32BE(16), expectedSize, `${name} width`);
    assert.equal(png.readUInt32BE(20), expectedSize, `${name} height`);
  }

  const desktopIcon = await readFile(join(root, "assets", "elevenlabs-icon.png"));
  const desktopIconSource = await readFile(join(root, "assets", "elevenlabs-icon.svg"), "utf8");
  const iosIcon = await readFile(join(root, "assets", "elevenlabs-ios-icon.png"));
  assert.equal(desktopIcon[25], 6, "the macOS/plugin PNG must carry alpha");
  assert.equal(iosIcon[25], 2, "the iOS PNG must remain opaque RGB");
  assert.ok(desktopIconSource.includes('x="6" y="6" width="1012" height="1012"'));
  assert.ok(desktopIconSource.includes('x="224" y="362" width="54" height="300"'));
  assert.ok(desktopIconSource.includes('x="314" y="286" width="54" height="452"'));
  assert.ok(desktopIconSource.includes('x="502" y="244" width="40" height="536"'));
  assert.ok(desktopIconSource.includes('x="596" y="330" width="230" height="42"'));
  assert.ok(!desktopIconSource.includes('x="344" y="214" width="112" height="596"'));

  assert.deepEqual(
    await readFile(join(iconRoot, "AppIcon.png")),
    await readFile(join(root, "assets", "elevenlabs-icon.png")),
    "the native macOS 1024px icon must exactly match the plugin icon",
  );
  assert.deepEqual(
    await readFile(join(iconRoot, "AppIcon-iOS.png")),
    await readFile(join(root, "assets", "elevenlabs-ios-icon.png")),
    "the native iOS marketing icon must exactly match the opaque iOS icon",
  );
  assert.deepEqual(
    await readFile(
      join(root, "skills", "elevenlabs", "assets", "elevenlabs-icon.png"),
    ),
    await readFile(join(root, "assets", "elevenlabs-icon.png")),
    "the skill icon must exactly match the plugin icon",
  );
});

test("the provider plugin stays ElevenLabs while native display surfaces use Dictation Button", async () => {
  const codex = await json(".codex-plugin", "plugin.json");
  const claude = await json(".claude-plugin", "plugin.json");
  const pkg = await json("package.json");
  for (const metadata of [codex, claude, pkg]) {
    assert.match(metadata.description, /ElevenLabs/i);
  }

  assert.equal(
    (await readFile(join(root, "apps", "ElevenLabs", "ios", "ElevenLabs", "Info.plist"), "utf8"))
      .match(/<key>CFBundleDisplayName<\/key>\s*<string>([^<]+)<\/string>/)?.[1],
    "Dictation Button",
  );
  assert.equal(
    (await readFile(join(root, "apps", "ElevenLabs", "ios", "ElevenLabsKeyboard", "Info.plist"), "utf8"))
      .match(/<key>CFBundleDisplayName<\/key>\s*<string>([^<]+)<\/string>/)?.[1],
    "Dictation Button",
  );
  assert.equal(
    (await readFile(join(root, "apps", "ElevenLabs", "ios", "ElevenLabsLiveActivity", "Info.plist"), "utf8"))
      .match(/<key>CFBundleDisplayName<\/key>\s*<string>([^<]+)<\/string>/)?.[1],
    "Dictation Button",
  );
});

test("the iPhone installer requires consent and renews App Group signing", async () => {
  const nativeRoot = join(root, "apps", "ElevenLabs");
  const project = await readFile(
    join(nativeRoot, "ios", "ElevenLabs.xcodeproj", "project.pbxproj"),
    "utf8",
  );
  const installer = await readFile(
    join(nativeRoot, "scripts", "install-iphone.sh"),
    "utf8",
  );

  assert.equal(
    project.match(/ELEVENLABS_APP_ENTITLEMENTS_FILE =/g)?.length,
    2,
    "both app configurations must define a resolved entitlement path",
  );
  assert.equal(
    project.match(/ELEVENLABS_KEYBOARD_ENTITLEMENTS_FILE =/g)?.length,
    2,
    "both keyboard configurations must define a resolved entitlement path",
  );
  assert.match(installer, /profile-backups/);
  assert.match(installer, /ExpirationDate/);
  assert.match(
    installer,
    /ELEVENLABS_APP_ENTITLEMENTS_FILE="\$app_entitlements"/,
  );
  assert.match(
    installer,
    /ELEVENLABS_KEYBOARD_ENTITLEMENTS_FILE="\$keyboard_entitlements"/,
  );
  assert.match(installer, /the device did not accept the app installation/);
  assert.doesNotMatch(installer, /device install app[^\n]*\|\s*tail/);
  assert.match(installer, /-derivedDataPath "\$build_dir\/DerivedData"/);
  assert.doesNotMatch(installer, /CONFIGURATION_BUILD_DIR=/);
  assert.match(installer, /--confirm-device-replacement/);
  assert.match(installer, /manual device replacement was not explicitly authorized/);
  assert.match(installer, /Type REPLACE ELEVENLABS to continue/);
  assert.match(installer, /refusing device replacement without an interactive terminal/);
  assert.match(installer, /launch_after_install=false/);
  assert.match(installer, /--launch-after-install/);
  assert.doesNotMatch(installer, /--pause-before-install/);
  assert.doesNotMatch(installer, /Verifying launchability without activation/);
  assert.ok(
    installer.indexOf("manual device replacement was not explicitly authorized") <
      installer.indexOf("env_file="),
    "authorization must fail before identity loading or build work",
  );
  assert.ok(
    installer.indexOf("Type REPLACE ELEVENLABS to continue") <
      installer.indexOf("xcrun devicectl device install app"),
    "the interactive confirmation must precede device replacement",
  );
});

test("the iPhone keyboard is a send-only delivery surface", async () => {
  const nativeRoot = join(root, "apps", "ElevenLabs");
  const appModel = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "AppModel.swift"),
    "utf8",
  );
  const contentView = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "ContentView.swift"),
    "utf8",
  );
  const sharedDictation = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "SharedDictation.swift"),
    "utf8",
  );
  const keyboardView = await readFile(
    join(nativeRoot, "ios", "ElevenLabsKeyboard", "KeyboardView.swift"),
    "utf8",
  );
  const keyboardController = await readFile(
    join(nativeRoot, "ios", "ElevenLabsKeyboard", "KeyboardViewController.swift"),
    "utf8",
  );
  const controlIntents = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "LiveActivityControlIntents.swift"),
    "utf8",
  );

  assert.doesNotMatch(keyboardView, /model\.startDictation/);
  assert.doesNotMatch(keyboardView, /Button\([^)]*Start dictation/);
  assert.match(keyboardView, /Text\("Start from Live Activity"\)/);
  assert.match(
    keyboardView,
    /\[\.recording, \.paused\]\.contains\(model\.snapshot\.phase\)/,
  );
  assert.match(keyboardView, /StopAndInsertDictationIntent\(sessionID: sessionID\)/);
  assert.match(keyboardView, /model\.stopAndTranscribe\(expectedSessionID: sessionID\)/);
  assert.match(
    keyboardView,
    /isSending \? "Transcribing dictation" : "Send dictation"/,
  );
  assert.match(keyboardView, /Text\("Send"\)/);
  assert.match(keyboardView, /frame\(maxWidth: \.infinity, minHeight: 54\)/);
  assert.match(
    keyboardView,
    /RoundedRectangle\(cornerRadius: 14, style: \.continuous\)/,
  );
  assert.doesNotMatch(keyboardView, /background\(Circle\(\)\.fill\(fill\)\)/);
  assert.doesNotMatch(keyboardView, /model\.pauseDictation/);
  assert.doesNotMatch(keyboardView, /model\.resumeDictation/);
  assert.doesNotMatch(keyboardView, /model\.cancelDictation/);
  assert.doesNotMatch(keyboardView, /else\s*\{\s*EmptyView\(\)/);
  assert.match(controlIntents, /struct StopAndInsertDictationIntent:/);
  assert.match(controlIntents, /expectedSessionID: parsedSessionID/);
  assert.match(
    controlIntents,
    /StartDictationFromLiveActivityIntent:[\s\S]*opensIntent: OpenURLIntent/,
  );
  assert.match(contentView, /Keyboard Settings/);
  assert.match(contentView, /Allow Full Access/);
  assert.match(contentView, /It only sends the finished transcript\./);
  assert.doesNotMatch(contentView, /model\.startDictation/);
  assert.doesNotMatch(contentView, /KEYBOARD SETUP REQUIRED/);
  assert.match(appModel, /prefs:root=General&path=Keyboard/);
  assert.doesNotMatch(
    appModel,
    /startFromLiveActivity\(\)[\s\S]*guard isKeyboardReady/,
  );
  assert.doesNotMatch(sharedDictation, /struct KeyboardSetupStatusStore/);
  assert.doesNotMatch(
    keyboardController,
    /keyboardSetupStatusStore\.save\(hasFullAccess: hasFullAccess\)/,
  );
});

test("iPhone dictation follows the Control Center, Live Activity, keyboard flow", async () => {
  const nativeRoot = join(root, "apps", "ElevenLabs");
  const keyboardModel = await readFile(
    join(nativeRoot, "ios", "ElevenLabsKeyboard", "KeyboardModel.swift"),
    "utf8",
  );
  const keyboardView = await readFile(
    join(nativeRoot, "ios", "ElevenLabsKeyboard", "KeyboardView.swift"),
    "utf8",
  );
  const appModel = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "AppModel.swift"),
    "utf8",
  );
  const audioRecorder = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "AudioRecorder.swift"),
    "utf8",
  );
  const audioRecorderPolicy = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "AudioRecorderStartPolicy.swift"),
    "utf8",
  );
  const audioDiagnostics = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "AudioDiagnosticsStore.swift"),
    "utf8",
  );
  const observability = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "Observability.swift"),
    "utf8",
  );
  const appDelegate = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "AppDelegate.swift"),
    "utf8",
  );
  const dictationEngine = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "DictationEngine.swift"),
    "utf8",
  );
  const activityAttributes = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "DictationActivityAttributes.swift"),
    "utf8",
  );
  const liveActivity = await readFile(
    join(nativeRoot, "ios", "ElevenLabsLiveActivity", "ElevenLabsLiveActivityWidget.swift"),
    "utf8",
  );
  const liveActivityManager = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "DictationLiveActivity.swift"),
    "utf8",
  );
  const hostResolver = await readFile(
    join(nativeRoot, "ios", "ElevenLabsKeyboard", "HostApplicationResolver.swift"),
    "utf8",
  );
  const keyboardController = await readFile(
    join(nativeRoot, "ios", "ElevenLabsKeyboard", "KeyboardViewController.swift"),
    "utf8",
  );
  const nativeBridge = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "ElevenLabsNative.swift"),
    "utf8",
  );
  const keyboardSetupStatus = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "KeyboardSetupStatus.swift"),
    "utf8",
  );
  const expoApp = await readFile(join(nativeRoot, "App.js"), "utf8");
  const expoConfig = await readFile(join(nativeRoot, "app.json"), "utf8");
  const iosInfoPlist = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "Info.plist"),
    "utf8",
  );
  const hostSwitcher = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "HostAppSwitcher.swift"),
    "utf8",
  );
  const contentView = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "ContentView.swift"),
    "utf8",
  );
  const controlIntents = await readFile(
    join(nativeRoot, "ios", "ElevenLabs", "LiveActivityControlIntents.swift"),
    "utf8",
  );
  const xcodeProject = await readFile(
    join(nativeRoot, "ios", "ElevenLabs.xcodeproj", "project.pbxproj"),
    "utf8",
  );

  assert.match(keyboardModel, /func pauseDictation\(expectedSessionID: UUID\)/);
  assert.match(keyboardModel, /func resumeDictation\(expectedSessionID: UUID\)/);
  assert.match(keyboardModel, /func cancelDictation\(expectedSessionID: UUID\)/);
  assert.match(keyboardModel, /return switch pendingControl/);
  assert.match(keyboardView, /KBStateProgress\(kind: \.preparing\)/);
  assert.match(keyboardView, /KBStateProgress\(kind: \.sending\)/);
  assert.match(keyboardView, /case \.sending, \.cancelling:[\s\S]*ProgressView\(\)/);
  assert.match(keyboardView, /KBPreparedIntentButtonStyle/);
  assert.match(keyboardView, /dark: \(0\.07, 0\.07, 0\.08\)/);

  const deliveryStart = keyboardModel.indexOf(
    "private func deliverCompletedTranscript",
  );
  const deliveryEnd = keyboardModel.indexOf(
    "private func showInsertedConfirmation",
    deliveryStart,
  );
  assert.ok(deliveryStart >= 0);
  assert.ok(deliveryEnd > deliveryStart);
  const delivery = keyboardModel.slice(deliveryStart, deliveryEnd);
  const insertionBoundary = delivery.indexOf("store.markInsertionStarted");
  const documentMutation = delivery.indexOf("insertTranscript(transcript)");
  const confirmedDelivery = delivery.indexOf("if result.confirmed");
  const insertionAcknowledgement = delivery.indexOf("store.markInserted");
  assert.ok(insertionBoundary >= 0);
  assert.ok(documentMutation > insertionBoundary);
  assert.ok(confirmedDelivery > documentMutation);
  assert.ok(insertionAcknowledgement > confirmedDelivery);
  assert.match(delivery, /isInsertionSurfaceReady/);
  assert.doesNotMatch(delivery, /InsertionContextDeliveryPolicy/);
  assert.doesNotMatch(delivery, /blockDelivery/);
  assert.doesNotMatch(delivery, /cursor changed/i);

  const keyboardStart = keyboardModel.indexOf("func startDictation()");
  const keyboardStop = keyboardModel.indexOf(
    "func stopAndTranscribe",
    keyboardStart,
  );
  const protectedStart = keyboardModel.slice(keyboardStart, keyboardStop);
  const hostResolution = protectedStart.indexOf("resolveHostApplication()");
  const sharedSession = protectedStart.indexOf("store.begin(");
  const containingAppURL = protectedStart.indexOf(
    'string: "elevenlabs://dictate/start?session=',
  );
  const containingAppOpen = protectedStart.indexOf("openContainingApp(url)");
  assert.ok(keyboardStart >= 0);
  assert.ok(keyboardStop > keyboardStart);
  assert.ok(hostResolution >= 0);
  assert.ok(sharedSession > hostResolution);
  assert.ok(containingAppURL > sharedSession);
  assert.ok(containingAppOpen > containingAppURL);

  assert.match(appModel, /func pauseSharedRecording\(expectedSessionID: UUID\)/);
  assert.match(
    appModel,
    /func pauseSharedRecording[\s\S]*recorder\.stop\(deactivatesSession: true\)/,
  );
  assert.match(
    appModel,
    /continuationStore\.beginPausedBoundary\([\s\S]*transcribeActiveRecording\(publishState: false\)/,
  );
  assert.doesNotMatch(appModel, /func resumeSharedRecording/);
  assert.match(
    audioRecorder,
    /func resume\([\s\S]*\) async throws\(AudioRecorderError\)/,
  );
  assert.match(
    audioRecorder,
    /if !reactivatesSession \{[\s\S]*try recorder\.start\(\)[\s\S]*completeResume\(\)/,
  );
  assert.doesNotMatch(audioRecorder, /private var recorder: AVAudioRecorder/);
  assert.doesNotMatch(audioRecorder, /AVAudioRecorder\(url:/);
  assert.match(audioRecorder, /try engine\.start\(\)/);
  assert.match(
    audioRecorder,
    /func start\(\) throws\(AudioCaptureStartError\)/,
  );
  assert.match(
    audioRecorder,
    /AVAudioSession\.ErrorCode\(rawValue: diagnostic\.code\)/,
  );
  assert.match(audioRecorder, /switch code \{/);
  assert.match(audioRecorder, /@unknown default:/);
  assert.doesNotMatch(
    audioRecorder,
    /if code == AVAudioSession\.ErrorCode/,
  );
  assert.doesNotMatch(audioRecorder, /foregroundRequired\(underlying:/);
  assert.doesNotMatch(
    audioRecorder,
    /configurationFailed\(stage: String/,
  );
  for (const appleCase of [
    "none",
    "mediaServicesFailed",
    "isBusy",
    "incompatibleCategory",
    "cannotInterruptOthers",
    "missingEntitlement",
    "siriIsRecording",
    "cannotStartPlaying",
    "cannotStartRecording",
    "badParam",
    "insufficientPriority",
    "resourceNotAvailable",
    "unspecified",
    "expiredSession",
    "sessionNotActive",
  ]) {
    assert.match(audioRecorder, new RegExp(`case \\.${appleCase}:`));
  }
  assert.match(
    audioRecorderPolicy,
    /enum AudioCaptureStartSystemFailure:[\s\S]*case cannotStartRecording/,
  );
  assert.match(
    audioRecorderPolicy,
    /case unspecified[\s\S]*case unknownCode/,
  );
  assert.equal(
    [...xcodeProject.matchAll(/SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;/g)].length,
    10,
  );
  assert.match(
    audioRecorderPolicy,
    /retryDelaysMilliseconds: \[250\]/,
  );
  assert.match(
    audioRecorder,
    /activeRecorder = nil[\s\S]*releaseAudioSession\(reason: releaseReason\)/,
  );
  assert.match(
    audioRecorder,
    /retryDelaysMilliseconds[\s\S]*notifyOthersOnDeactivation/,
  );
  const audioConfigurationStart = audioRecorder.indexOf(
    "private func configureSessionForRecording",
  );
  const audioConfigurationEnd = audioRecorder.indexOf(
    "private func preferBuiltInMicrophone",
    audioConfigurationStart,
  );
  assert.ok(audioConfigurationStart >= 0);
  assert.ok(audioConfigurationEnd > audioConfigurationStart);
  const audioConfiguration = audioRecorder.slice(
    audioConfigurationStart,
    audioConfigurationEnd,
  );
  assert.match(audioConfiguration, /case \.mediaPreservingPlayAndRecord/);
  assert.match(audioConfiguration, /options\.insert\(\.mixWithOthers\)/);
  assert.match(audioConfiguration, /options\.insert\(\.duckOthers\)/);
  assert.match(audioConfiguration, /options\.insert\(\.allowBluetoothA2DP\)/);
  assert.doesNotMatch(audioConfiguration, /\.allowBluetoothHFP/);
  assert.doesNotMatch(audioConfiguration, /options\.insert\(\.defaultToSpeaker\)/);
  assert.match(audioConfiguration, /\.playAndRecord/);
  assert.doesNotMatch(audioConfiguration, /setCategory\([\s\S]*\.record,/);
  assert.match(audioRecorderPolicy, /mixesWithOthers: true/);
  assert.match(audioRecorderPolicy, /ducksOthers: false/);
  assert.match(audioRecorderPolicy, /allowsBluetoothA2DPOutput: true/);
  assert.match(
    audioRecorderPolicy,
    /usesConditionalBuiltInSpeakerFallback: true/,
  );
  assert.match(
    audioRecorder,
    /shouldApplySpeakerFallback[\s\S]*overrideOutputAudioPort\(\.speaker\)/,
  );
  assert.match(audioRecorder, /session\.currentRoute\.inputs\.contains/);
  assert.match(
    audioRecorder,
    /AudioRecorderInputRoutePolicy\.shouldSetPreferredBuiltInInput/,
  );
  assert.match(audioRecorder, /expectedGeneration == audioSessionGeneration/);
  assert.match(audioRecorder, /Observability\.logAudioSessionRelease/);
  assert.match(
    audioRecorder,
    /Observability\.logOtherAudioRecoveryObservation/,
  );
  assert.match(audioRecorder, /Observability\.logAudioRouteChanged/);
  const recorderRetryStart = audioRecorder.indexOf(
    "private func startPreparedRecorder",
  );
  const recorderRetryEnd = audioRecorder.indexOf(
    "private func elapsedMilliseconds",
    recorderRetryStart,
  );
  assert.ok(recorderRetryStart >= 0);
  assert.ok(recorderRetryEnd > recorderRetryStart);
  const recorderRetry = audioRecorder.slice(
    recorderRetryStart,
    recorderRetryEnd,
  );
  assert.match(
    recorderRetry,
    /prepareActivatedRouteForRecording\(\s*forceInputReassertion: true/,
  );
  assert.doesNotMatch(recorderRetry, /setActive\(\s*false/);
  assert.doesNotMatch(audioRecorderPolicy, /recycleSession/);
  assert.match(
    audioRecorder,
    /mustFinalize[\s\S]*finishRecording\([\s\S]*releaseReason: \.unexpectedEnd/,
  );
  assert.match(
    audioRecorder,
    /func resume\([\s\S]*throws\(AudioRecorderError\)[\s\S]*try activateAudioSession\(session\)[\s\S]*AudioCaptureStartFailurePolicy\.decision/,
  );
  const recorderResumeStart = audioRecorder.indexOf(
    "func resume(",
  );
  const recorderResumeEnd = audioRecorder.indexOf(
    "private func completeResume",
    recorderResumeStart,
  );
  assert.ok(recorderResumeStart >= 0);
  assert.ok(recorderResumeEnd > recorderResumeStart);
  assert.doesNotMatch(
    audioRecorder.slice(recorderResumeStart, recorderResumeEnd),
    /setActive\(\s*false/,
  );
  assert.match(appModel, /acceptedCommands = \[\.pause, \.stop, \.cancel\]/);
  assert.match(appModel, /acceptedCommands = \[\.stop, \.cancel\]/);
  assert.match(
    appModel,
    /func performSharedIntentCommand\([\s\S]*takePendingCommand\([\s\S]*await liveActivityUpdateTask\?\.value/,
  );
  assert.match(
    appModel,
    /case \.stop where isRecording \|\| isPaused:[\s\S]*stopAndTranscribe\(\)/,
  );
  assert.match(
    appModel,
    /func stopAndTranscribe\(\)[\s\S]*publishTranscribingState\(\)[\s\S]*recorder\.stop\(\)/,
  );
  assert.doesNotMatch(
    appModel,
    /Microphone route changed\. Recording continues\./,
  );
  assert.doesNotMatch(appModel, /coalescesIfSuperseded/);
  assert.match(
    appModel,
    /private func startLiveActivityVisualization\(sessionID: UUID\)[\s\S]*meterLevels: self\.recorder\.meterLevels[\s\S]*Task\.sleep\(for: \.milliseconds\(180\)\)/,
  );
  assert.match(appModel, /requestPausedContinuation\(\s*sessionID:/);
  assert.match(appModel, /completePausedPart\([\s\S]*case let \.waiting/);
  assert.match(appModel, /startImmediateContinuationIfPossible\(\s*sessionID:/);
  assert.match(appModel, /beginImmediateContinuation\([\s\S]*pendingPartIDs/);
  assert.match(appModel, /bankImmediateContinuationPart\(/);
  assert.match(appModel, /abandonImmediateContinuation\(/);

  assert.match(activityAttributes, /var visualizationFrame: UInt8\?/);
  assert.match(activityAttributes, /var audioLevel: Double\?/);
  assert.match(activityAttributes, /var meterLevels: \[Double\]\?/);
  assert.match(activityAttributes, /var returnsToIdleLauncher: Bool/);
  assert.match(liveActivity, /PauseDictationIntent\(sessionID: sessionID\)/);
  assert.doesNotMatch(liveActivity, /ResumeDictationIntent\(sessionID: sessionID\)/);
  assert.match(liveActivity, /CancelDictationIntent\(sessionID: sessionID\)/);
  assert.match(
    liveActivity,
    /Link\(destination: URL\(string: "elevenlabs:\/\/live-activity\/start"\)!\)/,
  );
  assert.match(liveActivity, /Text\("Start dictation"\)/);
  assert.match(liveActivity, /elevenlabs:\/\/live-activity\/start/);
  assert.doesNotMatch(liveActivity, /live-activity\/(?:pause|resume)/);
  assert.match(liveActivity, /live-activity\/status\?session=/);
  assert.doesNotMatch(liveActivityManager, /acknowledgementDelay/);
  assert.match(
    liveActivityManager,
    /if phase\.returnsToIdleLauncher \{[\s\S]*activity\.update\([\s\S]*phase: \.idle/,
  );
  assert.match(liveActivityManager, /func ensureIdleLauncher\(\) async throws/);
  assert.match(liveActivityManager, /Activity\.request\(/);
  assert.doesNotMatch(liveActivityManager, /func removeIdleLaunchers\(\)/);
  assert.match(
    liveActivityManager,
    /let precedingUpdate = activityUpdateTail[\s\S]*activityUpdateTail = queuedUpdate/,
  );
  assert.match(liveActivityManager, /struct LiveActivityUpdateGate/);
  assert.match(
    liveActivityManager,
    /updateGate\.announce\(sessionID: sessionID\)[\s\S]*updateGate\.permits/,
  );
  assert.match(
    liveActivityManager,
    /sessionGate\.close\(sessionID: sessionID\)[\s\S]*let terminalUpdate = Task[\s\S]*await precedingUpdate\?\.value/,
  );
  assert.match(
    liveActivityManager,
    /func prepareForRecording\([\s\S]*LiveActivityRecordingPreflight\.action\([\s\S]*try await start\(sessionID: sessionID, startedAt: startedAt\)[\s\S]*currentActivity\(for: sessionID\)/,
  );
  const resumeStart = dictationEngine.indexOf(
    "func resume(expectedSessionID: UUID)",
  );
  const stopStart = dictationEngine.indexOf("func stop()", resumeStart);
  assert.ok(resumeStart >= 0);
  assert.ok(stopStart > resumeStart);
  const resumePath = dictationEngine.slice(resumeStart, stopStart);
  assert.ok(
    resumePath.indexOf("try await liveActivity.prepareForRecording(") <
      resumePath.indexOf("try await beginHotSegmentCapture()"),
    "resume must establish a live ActivityKit activity before activating audio",
  );
  assert.match(
    observability,
    /elevenlabs\.live_activity_recording_preflight/,
  );
  assert.match(liveActivity, /struct ElevenLabsDictationControl: ControlWidget/);
  assert.match(
    liveActivity,
    /static let kind = ElevenLabsDictationControlContract\.kind/,
  );
  assert.match(
    liveActivity,
    /StaticControlConfiguration\([\s\S]*provider: DictationControlValueProvider\(\)/,
  );
  assert.match(
    liveActivity,
    /ControlWidgetToggle\([\s\S]*"Dictation",[\s\S]*isOn: presentation\.isOn,[\s\S]*action: ToggleDictationControlIntent\(\)/,
  );
  assert.match(
    liveActivity,
    /\) \{ requestedIsOn in[\s\S]*presentation\.status\(requestedIsOn: requestedIsOn\)[\s\S]*presentation\.systemImageName\([\s\S]*requestedIsOn: requestedIsOn/,
  );
  const controlWidgetStart = liveActivity.indexOf(
    "struct ElevenLabsDictationControl: ControlWidget",
  );
  const liveActivityWidgetStart = liveActivity.indexOf(
    "struct ElevenLabsLiveActivityWidget: Widget",
    controlWidgetStart,
  );
  assert.ok(controlWidgetStart >= 0);
  assert.ok(liveActivityWidgetStart > controlWidgetStart);
  const controlWidget = liveActivity.slice(
    controlWidgetStart,
    liveActivityWidgetStart,
  );
  assert.doesNotMatch(controlWidget, /OpenURLIntent/);
  assert.doesNotMatch(controlWidget, /systemImage: "waveform"/);
  assert.match(liveActivity, /case \.off: "Off"/);
  assert.match(liveActivity, /case \.starting: "Starting"/);
  assert.match(liveActivity, /case \.recording: "Recording"/);
  assert.match(liveActivity, /case \.pausing: "Pausing"/);
  assert.match(liveActivity, /case \.paused: "Paused"/);
  assert.match(liveActivity, /case \.resuming: "Resuming"/);
  assert.match(liveActivity, /case \.off, \.starting: "mic\.fill"/);
  assert.match(liveActivity, /case \.recording, \.resuming: "waveform"/);
  assert.match(liveActivity, /case \.pausing, \.paused: "play\.fill"/);
  assert.match(controlWidget, /\.tint\(\.red\)/);
  assert.match(
    liveActivity,
    /SharedDictationStore\(\)\.load\(\)\.phase/,
  );
  assert.match(liveActivity, /\.displayName\("Dictation Button"\)/);
  assert.doesNotMatch(liveActivity, /Text\("ElevenLabs"\)/);
  assert.match(
    controlIntents,
    /struct ToggleDictationControlIntent:[\s\S]*?AudioRecordingIntent,[\s\S]*?LiveActivityIntent,[\s\S]*?SetValueIntent/,
  );
  assert.equal(
    xcodeProject.match(
      /\/\* LiveActivityControlIntents\.swift in Sources \*\/ =/g,
    )?.length,
    3,
    "the control intent must remain in the app, keyboard, and widget targets",
  );
  assert.match(
    controlIntents,
    /@Parameter\(title: "Recording"\)[\s\S]*var value: Bool/,
  );
  const controlIntentStart = controlIntents.indexOf(
    "struct ToggleDictationControlIntent:",
  );
  const compatibilityIntentStart = controlIntents.indexOf(
    "struct StartDictationFromLiveActivityIntent",
    controlIntentStart,
  );
  assert.ok(controlIntentStart >= 0);
  assert.ok(compatibilityIntentStart > controlIntentStart);
  const controlIntent = controlIntents.slice(
    controlIntentStart,
    compatibilityIntentStart,
  );
  assert.match(controlIntent, /static let openAppWhenRun = false/);
  assert.match(
    controlIntent,
    /\[\.background, \.foreground\(\.dynamic\)\]/,
  );
  assert.match(controlIntent, /continueInForeground\(/);
  assert.match(controlIntent, /requestToContinueInForeground\(/);
  assert.match(controlIntent, /requiresForegroundContinuation/);
  assert.match(
    controlIntent,
    /foregroundAction[\s\S]*requestedIsOn: requestedIsOn[\s\S]*phase: store\.load\(\)\.phase/,
  );
  assert.match(
    dictationEngine,
    /rollbackInitialStartForForegroundContinuation[\s\S]*abandonEmptyHotCapture/,
  );
  assert.match(
    dictationEngine,
    /rollbackResumeForForegroundContinuation[\s\S]*to: \.paused/,
  );
  assert.match(controlIntent, /DictationControlTransition\.action\(/);
  assert.match(controlIntent, /performDictationControlAction\(/);
  assert.match(controlIntents, /DictationEngine\.shared\.showIdleLauncher\(\)/);
  assert.match(controlIntents, /DictationEngine\.shared\.pause\(/);
  assert.match(controlIntents, /DictationEngine\.shared\.resume\(/);
  assert.match(controlIntent, /ElevenLabsDictationControlContract\.reload\(\)/);
  assert.doesNotMatch(controlIntent, /ForegroundControlStartRequest\.submit\(\)/);
  assert.doesNotMatch(controlIntent, /OpenIntent/);
  assert.doesNotMatch(controlIntent, /OpenURLIntent/);
  assert.doesNotMatch(controlIntent, /elevenlabs:\/\//);
  assert.doesNotMatch(controlIntents, /consume\(ifApplicationIsActive/);
  assert.match(appModel, /resumePendingKeyboardLiveActivityIfNeeded\(\)/);
  assert.match(
    appModel,
    /LiveActivityStartReadiness\.permitsRequest\([\s\S]*pendingLiveActivityStart = PendingLiveActivityStart/,
  );
  assert.match(
    appModel,
    /private func resumePendingKeyboardLiveActivityIfNeeded\(\)[\s\S]*requestKeyboardLiveActivity/,
  );
  assert.match(
    appModel,
    /liveActivityStartTask == nil,[\s\S]*liveActivityStartSessionID != snapshot\.sessionID/,
  );
  assert.match(
    appModel,
    /guard liveActivityStartSessionID != sessionID else \{ return \}/,
  );
  assert.match(
    appModel,
    /try await liveActivity\.start\([\s\S]*synchronizeStartedLiveActivity/,
  );
  assert.doesNotMatch(liveActivity, /Image\("ElevenLabsControlMark"\)/);
  assert.match(liveActivity, /state\.visualizationFrame/);
  assert.match(liveActivity, /state\.audioLevel/);
  assert.match(liveActivity, /state\.meterLevels/);
  assert.match(liveActivity, /struct ActivityDurationText: View/);
  assert.match(liveActivity, /timerInterval: startedAt\.\.\.Date\.distantFuture/);
  assert.match(liveActivity, /struct SessionSignal: View/);
  assert.match(liveActivity, /struct CompactStudioMeter: View/);
  assert.match(liveActivity, /struct MinimalRecordingMark: View/);
  assert.match(liveActivity, /struct MinimalSessionSignal: View/);
  assert.doesNotMatch(liveActivity, /struct CompactHeldPeakCaps: View/);
  assert.match(liveActivity, /struct CompactSessionSignal: View/);
  assert.match(
    liveActivity,
    /minimal: \{[\s\S]*MinimalSessionSignal\([\s\S]*state: context\.state,[\s\S]*phase: phase/,
  );
  const minimalRecordingStart = liveActivity.indexOf(
    "private struct MinimalRecordingMark: View",
  );
  const compactStudioMeterStart = liveActivity.indexOf(
    "private struct CompactStudioMeter: View",
    minimalRecordingStart,
  );
  assert.ok(minimalRecordingStart >= 0);
  assert.ok(compactStudioMeterStart > minimalRecordingStart);
  const minimalRecording = liveActivity.slice(
    minimalRecordingStart,
    compactStudioMeterStart,
  );
  assert.match(minimalRecording, /barCount: 6/);
  assert.match(minimalRecording, /barWidth: CGFloat = 1\.5/);
  assert.match(minimalRecording, /barSpacing: CGFloat = 1\.35/);
  assert.doesNotMatch(minimalRecording, /Circle\(\)/);
  assert.doesNotMatch(minimalRecording, /\.fill\(Color\.white\)/);
  assert.match(
    minimalRecording,
    /LinearGradient\([\s\S]*LAPalette\.minimalMeterLow,[\s\S]*LAPalette\.minimalMeterMid,[\s\S]*LAPalette\.minimalMeterPeak,[\s\S]*startPoint: \.bottom,[\s\S]*endPoint: \.top/,
  );
  assert.match(minimalRecording, /\.linear\(duration: 0\.18\)/);
  assert.match(
    liveActivity,
    /LinearGradient\([\s\S]*LAPalette\.compactRecording,[\s\S]*LAPalette\.compactRecordingPeak,[\s\S]*startPoint: \.bottom,[\s\S]*endPoint: \.top/,
  );
  assert.match(liveActivity, /case \.paused:[\s\S]*Image\(systemName: "snowflake"\)/);
  assert.match(liveActivity, /FrozenWaveformMark\(/);
  assert.match(
    liveActivity,
    /compactLeading: \{[\s\S]*CompactSessionSignal\([\s\S]*height: 18/,
  );
  assert.match(
    liveActivity,
    /compactTrailing: \{[\s\S]*tint: phase\.compactTint/,
  );
  assert.match(liveActivity, /var barCount = 9/);
  assert.match(liveActivity, /barCount: 21/);
  assert.match(liveActivity, /fillsAvailableWidth: true/);
  assert.match(liveActivity, /title: "Pause"/);
  assert.doesNotMatch(liveActivity, /title: "Resume"/);
  assert.match(liveActivity, /title: "Cancel"/);
  assert.match(liveActivity, /Open Control Center to continue/);
  assert.match(liveActivity, /minHeight: 50/);
  const sessionSignalStart = liveActivity.indexOf(
    "private struct SessionSignal: View",
  );
  const compactMeterLevelsStart = liveActivity.indexOf(
    "private enum CompactMeterLevels",
    sessionSignalStart,
  );
  const durationTextStart = liveActivity.indexOf(
    "private struct ActivityDurationText: View",
    sessionSignalStart,
  );
  assert.ok(sessionSignalStart >= 0);
  assert.ok(compactMeterLevelsStart > sessionSignalStart);
  assert.ok(durationTextStart > sessionSignalStart);
  assert.doesNotMatch(
    liveActivity.slice(sessionSignalStart, compactMeterLevelsStart),
    /Circle\(\)/,
  );
  const compactSignalStart = liveActivity.indexOf(
    "private struct CompactSessionSignal: View",
  );
  assert.ok(compactSignalStart >= 0);
  const compactSignal = liveActivity.slice(compactSignalStart, durationTextStart);
  assert.match(compactSignal, /snowflake/);
  assert.match(liveActivity, /let silenceRatio: CGFloat = 0\.17/);
  assert.match(liveActivity, /reduceMotion \? nil : \.linear\(duration: 0\.20\)/);
  assert.match(
    liveActivityManager,
    /Paused minimal UI is a snowflake[\s\S]*audioLevelBySessionID\[sessionID\] = nil/,
  );
  const liveWaveformStart = liveActivity.indexOf(
    "private struct WaveformMark: View",
  );
  const frozenWaveformStart = liveActivity.indexOf(
    "private struct FrozenWaveformMark: View",
    liveWaveformStart,
  );
  assert.ok(liveWaveformStart >= 0);
  assert.ok(frozenWaveformStart > liveWaveformStart);
  assert.doesNotMatch(
    liveActivity.slice(liveWaveformStart, frozenWaveformStart),
    /\.animation\([\s\S]*value: frame/,
  );
  assert.match(liveActivity, /phase == \.recording \|\| phase == \.paused/);
  assert.match(liveActivity, /struct TranscriptionProgressMark: View/);
  assert.match(liveActivity, /Circle\(\)[\s\S]*\.trim\(from: 0\.06, to: 0\.34\)/);
  assert.doesNotMatch(liveActivity, /IndeterminateProgressRail/);
  assert.doesNotMatch(liveActivity, /ProgressView/);
  assert.match(liveActivity, /Text\(phase\.title\)/);
  assert.match(
    appModel,
    /private func startFromForegroundControl\(\)[\s\S]*sharedStore\.begin\([\s\S]*returnBundleIdentifier: nil/,
  );
  assert.match(appModel, /startKeyboardLiveActivity\(for: sharedSnapshot\)/);
  assert.match(appModel, /advancesVisualization: true/);
  assert.doesNotMatch(appModel, /tick\.isMultiple\(of: 2\)/);
  assert.match(dictationEngine, /tick\.isMultiple\(of: 2\)/);
  assert.match(
    dictationEngine,
    /beginCapture\([\s\S]*audioFileExtension: "wav"/,
  );
  assert.match(dictationEngine, /startRealtimeTranscription\(/);
  assert.match(dictationEngine, /finishRealtimeTranscription\(\)/);
  assert.match(dictationEngine, /updateRealtimeTranscript\(/);
  assert.match(dictationEngine, /setRealtimeDraftSendable\(/);
  assert.match(dictationEngine, /publishBatchCompletion\(/);
  assert.match(
    dictationEngine,
    /settleRealtimeDeliveryAfterBatchFailure\(/,
  );
  assert.match(controlIntents, /SharedDictationIntentCommandRouter/);
  for (const intent of ["Pause", "Cancel"]) {
    assert.match(
      controlIntents,
      new RegExp(
        `struct ${intent}DictationIntent:[\\s\\S]*?AudioRecordingIntent,[\\s\\S]*?LiveActivityIntent,`,
      ),
    );
    assert.match(
      controlIntents,
      new RegExp(
        `routeToKeyboardOwner\\([\\s\\S]*?\\.${intent.toLowerCase()}[\\s\\S]*?performSharedIntentCommand\\([\\s\\S]*?\\.${intent.toLowerCase()}`,
      ),
    );
  }
  assert.match(
    controlIntents,
    /struct StopAndInsertDictationIntent:[\s\S]*?routeToKeyboardOwner\([\s\S]*?\.stop[\s\S]*?performSharedIntentCommand\([\s\S]*?\.stop/,
  );
  assert.match(controlIntents, /struct ResumeDictationIntent:/);
  assert.doesNotMatch(controlIntents, /routeToKeyboardOwner\(\s*\.resume/);

  assert.match(
    keyboardView,
    /private struct KBStableSendButton: View, @MainActor Equatable/,
  );
  assert.match(keyboardView, /lhs\.model === rhs\.model/);
  assert.match(keyboardView, /isSending = true[\s\S]*model\.stopAndTranscribe/);
  assert.match(keyboardView, /KBPreparedIntentButtonStyle: ButtonStyle/);
  assert.doesNotMatch(keyboardView, /KBPreparedIntentButtonStyle: PrimitiveButtonStyle/);
  assert.match(keyboardView, /DragGesture\(minimumDistance: 0\)/);
  assert.doesNotMatch(keyboardView, /sendButton\s*\.disabled/);
  assert.match(keyboardView, /KBStableSendButton\([\s\S]*\.equatable\(\)/);
  assert.match(
    keyboardView,
    /\[\.recording, \.paused\]\.contains\(model\.snapshot\.phase\)[\s\S]*sendButton/,
  );
  assert.match(keyboardView, /isPaused: model\.snapshot\.phase == \.paused/);
  assert.match(
    nativeBridge,
    /guard delay < \(pendingNotificationDelay \?\? delay\) else \{ return \}/,
  );
  assert.match(nativeBridge, /pendingNotification = nil\s*pendingNotificationDelay = nil/);
  assert.match(expoApp, /const \[state, setState\] = useState\(null\)/);
  assert.match(expoApp, /if \(!state \|\| !state\.launchStateReady\) \{[\s\S]*<SafeAreaView style=\{styles\.screen\}>/);
  assert.doesNotMatch(expoApp, /useState\(emptyState\)/);
  assert.match(expoApp, /launchStateReady: true/);
  assert.match(expoConfig, /"userInterfaceStyle": "automatic"/);
  assert.match(iosInfoPlist, /<key>UIUserInterfaceStyle<\/key>\s*<string>Automatic<\/string>/);
  assert.match(expoApp, /DynamicColorIOS/);
  assert.match(expoApp, /<ActivityIndicator[\s\S]*accessibilityLabel="Transcribing dictation"/);
  assert.match(expoApp, /useColorScheme\(\) === 'dark'/);
  assert.match(expoApp, /pausedBackground: adaptiveColor/);
  assert.match(nativeBridge, /static let completed = "ios-onboarding-completed-v3"/);
  assert.match(nativeBridge, /static let legacyCompleted = "ios-onboarding-completed-v2"/);
  assert.match(nativeBridge, /resolvedCompletedOnboarding\(\)/);
  assert.match(
    nativeBridge,
    /"duration": headlessDuration \?\? model\.sessionElapsedDuration/,
  );
  assert.match(
    nativeBridge,
    /sharedSnapshot\.sessionKind == \.segmentedIntent/,
  );
  assert.match(nativeBridge, /"keyboardSetupDetected": keyboardSetup\.wasDetected/);
  assert.match(nativeBridge, /practicedControlCenterStart, keyboardSetup\.hasFullAccess/);
  assert.match(keyboardSetupStatus, /func record\(hasFullAccess: Bool/);
  assert.match(keyboardSetupStatus, /KeyboardInsertionTelemetryStore/);
  assert.match(keyboardSetupStatus, /let transcript: String/);
  assert.match(keyboardModel, /insertionTelemetry\.begin\(/);
  assert.match(keyboardModel, /insertionTelemetry\.finish/);
  assert.match(observability, /elevenlabs\.transcription_completed/);
  assert.match(observability, /elevenlabs\.transcription_failed/);
  assert.match(observability, /"sampleCount"/);
  assert.match(observability, /"activeMicrophoneMode"/);
  assert.match(observability, /elevenlabs\.keyboard_delivery/);
  assert.match(observability, /elevenlabs\.realtime_transcription/);
  assert.doesNotMatch(observability, /attributes\["transcript"\]/);
  assert.doesNotMatch(observability, /attributes\["contextBeforeMutation"\]/);
  assert.doesNotMatch(observability, /attributes\["contextAfterMutation"\]/);
  assert.match(nativeBridge, /flushKeyboardInsertionTelemetry\(\)/);
  assert.match(keyboardSetupStatus, /hostApplicationIdentityKey/);
  assert.match(keyboardView, /keyboardSetupStatusStore\.record\([\s\S]*hasFullAccess: model\.hasFullAccess/);
  const onboardingStart = expoApp.indexOf("function Onboarding");
  const onboardingEnd = expoApp.indexOf("function useReducedMotion", onboardingStart);
  assert.ok(onboardingStart >= 0);
  assert.ok(onboardingEnd > onboardingStart);
  const onboarding = expoApp.slice(onboardingStart, onboardingEnd);
  assert.doesNotMatch(onboarding, />Done<|update\('completeOnboarding'\)/);
  assert.match(onboarding, /Setup finishes automatically/);
  assert.match(nativeBridge, /"launchStateReady": launchStateReady/);
  assert.match(nativeBridge, /UIApplication\.didBecomeActiveNotification/);
  assert.match(nativeBridge, /Task\.sleep\(for: \.milliseconds\(220\)\)/);
  assert.match(controlIntents, /markControlCenterPractice\(\)/);
  assert.match(nativeBridge, /func sharedDictationDidChange\(\)/);
  assert.match(nativeBridge, /func markControlCenterPractice\(\)/);
  assert.match(observability, /elevenlabs\.dictation_control_transition/);
  assert.match(observability, /elevenlabs\.launch_presentation/);
  assert.match(expoApp, /function SwipeBackCue\(/);
  assert.match(expoApp, /setInterval\([\s\S]*, 90\)/);
  assert.match(expoApp, /return 4 \+ 155 \* voiceEnergy/);
  assert.doesNotMatch(expoApp, /frozenShape|statusSnowflake|pauseSnowflake/);
  assert.match(expoApp, /Report garbled/);
  assert.match(audioDiagnostics, /maximumStoredBytes: Int64 = 250 \* 1_024 \* 1_024/);
  assert.match(audioDiagnostics, /FileProtectionType\.complete/);
  assert.match(audioDiagnostics, /\.completeFileProtection/);
  assert.match(audioDiagnostics, /recordsByHistoryID: \[UUID: AudioDiagnosticRecord\]/);
  assert.match(audioDiagnostics, /func record\(for historyID: UUID\)[\s\S]*recordsByHistoryID\[historyID\]/);
  assert.match(audioDiagnostics, /delete\(historyID: record\.historyID\)/);
  assert.doesNotMatch(
    nativeBridge,
    /func snapshot\(\)[\s\S]*pruneAudioDiagnosticsToHistory\(\)[\s\S]*let phase/,
  );
  assert.match(
    appModel,
    /let diagnosticSourceID = activeContinuationPartID[\s\S]*archiveAudioDiagnostics/,
  );
  assert.match(observability, /elevenlabs\.audio_diagnostic_retained/);
  assert.match(observability, /elevenlabs\.audio_diagnostic_reported_garbled/);
  assert.doesNotMatch(observability, /Data\(contentsOf:|AVAudioFile|AVAudioPlayer/);
  assert.doesNotMatch(expoApp, /swipeCard|LIVE ACTIVITY ON/);

  assert.match(contentView, /ios-onboarding-completed-v3/);
  assert.match(contentView, /ios-onboarding-control-practiced-v2/);
  assert.match(contentView, /Add your Live Activity\./);
  assert.match(contentView, /Start from the Live Activity\./);
  assert.match(contentView, /Allow Full Access/);
  assert.match(contentView, /Swipe back/);
  assert.match(contentView, /ReactiveVoiceBars\(level: recorder\.level\)/);
  assert.match(contentView, /ProcessingWaveform\(tint:/);
  assert.doesNotMatch(contentView, /ProgressView/);
  assert.match(contentView, /FrozenVoiceBars\(\)/);
  assert.match(contentView, /stage == \.paused \? Theme\.iceSoft : \.black/);
  assert.match(contentView, /private struct SwipeBackCue: View/);
  assert.doesNotMatch(contentView, /LIVE ACTIVITY ON/);
  assert.doesNotMatch(contentView, /Open the Live Activity in Notification Center/);
  const handoffStart = contentView.indexOf("private struct SessionHandoffView");
  const readyStart = contentView.indexOf("private struct ReadyView", handoffStart);
  assert.ok(handoffStart >= 0);
  assert.ok(readyStart > handoffStart);
  const handoffSurface = contentView.slice(handoffStart, readyStart);
  assert.doesNotMatch(handoffSurface, /RoundedRectangle/);

  const activeAppModel = withoutCompileDisabledSwift(appModel);
  assert.match(appModel, /RETIRED_AUTOMATIC_SWITCHBACK/);
  assert.doesNotMatch(activeAppModel, /HostAppSwitcher\./);
  assert.doesNotMatch(activeAppModel, /startFromLiveActivity/);
  assert.doesNotMatch(keyboardView, /model\.startDictation/);
  assert.match(
    hostSwitcher,
    /app\(chatGPTBundleIdentifier, "ChatGPT", "chatgpt:\/\/"\)/,
  );
  assert.match(
    hostSwitcher,
    /app\(claudeBundleIdentifier, "Claude", "claude:\/\/"\)/,
  );

  const completionCommit = dictationEngine.indexOf(
    "The transcript is now durable",
  );
  const idleActivityUpdate = dictationEngine.indexOf(
    "await liveActivity.end(\n                .completed",
    completionCommit,
  );
  const completionFinish = dictationEngine.indexOf("finish()", idleActivityUpdate);
  assert.ok(completionCommit >= 0);
  assert.ok(idleActivityUpdate > completionCommit);
  assert.ok(completionFinish > idleActivityUpdate);
  assert.doesNotMatch(
    dictationEngine.slice(completionCommit, idleActivityUpdate),
    /endBackgroundExecution\(\)/,
  );
});

test("dormant iPhone host-compatibility files match the reviewed baseline", async () => {
  const manifestPath = join(
    root,
    "apps",
    "ElevenLabs",
    "docs",
    "protected-switchback.sha256",
  );
  const manifest = await readFile(manifestPath, "utf8");
  const entries = manifest
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));

  assert.equal(entries.length, 9, "the dormant compatibility baseline is exact");
  assert.doesNotMatch(manifest, /AppModel\.swift/);
  assert.doesNotMatch(manifest, /KeyboardView\.swift/);
  for (const entry of entries) {
    const match = entry.match(/^([a-f0-9]{64})  (.+)$/);
    assert.ok(match, `invalid protected switchback entry: ${entry}`);
    const [, expectedDigest, relativePath] = match;
    const source = await readFile(join(root, relativePath));
    const actualDigest = createHash("sha256").update(source).digest("hex");
    assert.equal(
      actualDigest,
      expectedDigest,
      `${relativePath} changed; do not alter dormant host-compatibility code without a new explicit product decision and physical-device proof`,
    );
  }
});
