import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path) =>
  readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("the iPhone container is an Expo app with fingerprinted updates", () => {
  const app = JSON.parse(read("apps/ElevenLabs/app.json"));
  const eas = JSON.parse(read("apps/ElevenLabs/eas.json"));
  const mobilePackage = JSON.parse(read("apps/ElevenLabs/package.json"));

  assert.equal(mobilePackage.main, "index.js");
  assert.ok(mobilePackage.dependencies.expo);
  assert.ok(mobilePackage.dependencies["expo-updates"]);
  assert.ok(mobilePackage.dependencies.react);
  assert.ok(mobilePackage.dependencies["react-native"]);
  assert.equal(app.expo.runtimeVersion.policy, "fingerprint");
  assert.equal(
    app.expo.updates.url,
    "https://u.expo.dev/33e2bdea-25eb-45b1-bd39-01c332a37820",
  );
  assert.equal(eas.build.production.channel, "production");
  assert.equal(eas.cli.appVersionSource, "remote");
  assert.equal(eas.build.production.autoIncrement, true);
  assert.equal(
    mobilePackage.expo.doctor.appConfigFieldsNotSyncedCheck.enabled,
    false,
  );
});

test("Expo is connected to the checked-in iOS app and native extensions", () => {
  const app = JSON.parse(read("apps/ElevenLabs/app.json"));
  const appDelegate = read(
    "apps/ElevenLabs/ios/ElevenLabs/AppDelegate.swift",
  );
  const project = read(
    "apps/ElevenLabs/ios/ElevenLabs.xcodeproj/project.pbxproj",
  );
  const podfile = read("apps/ElevenLabs/ios/Podfile");
  const expoPlist = read(
    "apps/ElevenLabs/ios/ElevenLabs/Supporting/Expo.plist",
  );
  const buildRecipe = read(
    "apps/ElevenLabs/.eas/build/production-ios.yml",
  );
  const infoPlist = read("apps/ElevenLabs/ios/ElevenLabs/Info.plist");
  const liveActivityInfoPlist = read(
    "apps/ElevenLabs/ios/ElevenLabsLiveActivity/Info.plist",
  );
  const liveActivityEntitlements = read(
    "apps/ElevenLabs/ios/ElevenLabsLiveActivity/ElevenLabsLiveActivity.entitlements",
  );
  const liveActivityExtension =
    app.expo.extra.eas.build.experimental.ios.appExtensions.find(
      ({ targetName }) => targetName === "ElevenLabsLiveActivity",
    );

  assert.match(appDelegate, /ExpoAppDelegate/);
  assert.match(appDelegate, /ExpoReactNativeFactory/);
  assert.match(project, /Bundle React Native code and images/);
  assert.match(project, /ElevenLabsNative\.swift in Sources/);
  assert.match(project, /Expo\.plist in Resources/);
  assert.match(podfile, /use_expo_modules!/);
  assert.match(podfile, /use_react_native!/);
  assert.match(expoPlist, /file:fingerprint/);
  assert.match(expoPlist, /EXUpdatesEnableBsdiffPatchSupport/);
  assert.doesNotMatch(expoPlist, /expo-channel-name/);
  assert.match(buildRecipe, /command: pod install/);
  assert.match(buildRecipe, /eas\/configure_eas_update/);
  assert.match(infoPlist, /<string>elevenlabs<\/string>/);
  assert.match(infoPlist, /<string>UIInterfaceOrientationPortrait<\/string>/);
  assert.match(infoPlist, /<key>ITSAppUsesNonExemptEncryption<\/key>\s*<false\/>/);
  assert.match(project, /ELEVENLABS_APP_BUNDLE_IDENTIFIER = com\.pedro\.ElevenLabs;/);
  assert.match(project, /TARGETED_DEVICE_FAMILY = 1;/);
  assert.deepEqual(
    liveActivityExtension.entitlements["com.apple.security.application-groups"],
    ["group.com.pedro.ElevenLabs"],
  );
  assert.match(
    liveActivityInfoPlist,
    /<key>ElevenLabsAppGroupIdentifier<\/key>\s*<string>\$\(ELEVENLABS_APP_GROUP_IDENTIFIER\)<\/string>/,
  );
  assert.match(
    liveActivityEntitlements,
    /<string>\$\(ELEVENLABS_APP_GROUP_IDENTIFIER\)<\/string>/,
  );
  assert.match(
    project,
    /CODE_SIGN_ENTITLEMENTS = ElevenLabsLiveActivity\/ElevenLabsLiveActivity\.entitlements;/,
  );
  assert.match(
    project,
    /SharedDictation\.swift in Sources/,
  );
});

test("CI publishes OTA while the operator separately owns native builds", () => {
  const updateWorkflow = read(
    ".github/workflows/elevenlabs-testflight.yml",
  );
  const updateScript = read(
    "apps/ElevenLabs/scripts/publish-ios-update.sh",
  );
  const localBuildScript = read(
    "apps/ElevenLabs/scripts/build-ios-local.sh",
  );
  const localBuildWorkflow = read(
    "apps/ElevenLabs/.eas/build/production-ios.yml",
  );
  const mobilePackage = JSON.parse(read("apps/ElevenLabs/package.json"));
  const easIgnore = read("apps/ElevenLabs/.easignore");
  const fingerprintConfig = read(
    "apps/ElevenLabs/fingerprint.config.cjs",
  );
  assert.match(
    localBuildScript,
    /fingerprint:generate --platform ios --build-profile production --json --non-interactive/,
  );
  assert.equal(
    localBuildScript.match(
      /expo-updates configuration:syncnative --platform ios --workflow generic/g,
    )?.length,
    1,
    "the local release command must normalize Expo configuration once",
  );
  assert.match(localBuildScript, /build:list[^\n]+--fingerprint-hash/);
  assert.match(
    localBuildWorkflow,
    /eas\/calculate_eas_update_runtime_version:\n\s+id: calculate_eas_update_runtime_version/,
  );
  assert.equal(
    localBuildWorkflow.match(
      /resolved_eas_update_runtime_version: \$\{ steps\.calculate_eas_update_runtime_version\.resolved_eas_update_runtime_version \}/g,
    )?.length,
    2,
    "Expo configuration and Fastlane must receive the calculated fingerprint",
  );
  assert.match(
    localBuildScript,
    /A local native build is required\. Run npm run eas:build:local/,
  );
  assert.doesNotMatch(
    localBuildScript,
    /update --channel production|npm run eas:update/,
  );
  assert.equal(
    localBuildScript.match(
      /build --platform ios --profile production --local --output/g,
    )?.length,
    1,
    "there must be exactly one local native build command",
  );
  assert.match(localBuildScript, /export TMPDIR="\$tmp_root\/"/);
  assert.match(localBuildScript, /export GYM_BUILD_PATH="\$archive_root"/);
  assert.match(
    localBuildScript,
    /export GYM_RESULT_BUNDLE_PATH="\$result_bundle_path"/,
  );
  assert.match(
    localBuildScript,
    /export EXPO_NO_CAPABILITY_SYNC=1/,
    "the local archive must preserve the checked-in App Group capabilities",
  );
  assert.ok(
    localBuildScript.indexOf('export GYM_BUILD_PATH="$archive_root"') <
      localBuildScript.indexOf('"${eas[@]}" build --platform ios'),
    "Fastlane archive output must be clone-local before the build starts",
  );
  assert.match(
    localBuildScript,
    /submit --platform ios --profile production --path "\$artifact_path" --non-interactive --wait/,
  );
  assert.match(
    localBuildScript,
    /upload --platform ios --build-path "\$artifact_path" --fingerprint/,
  );
  assert.ok(
    localBuildScript.indexOf('"${eas[@]}" submit --platform ios') <
      localBuildScript.indexOf('"${eas[@]}" upload --platform ios'),
    "TestFlight submission must succeed before Expo records compatibility",
  );
  assert.doesNotMatch(
    localBuildScript,
    /workflow:run|type: build|build:cancel|submit:cancel/,
  );
  assert.doesNotMatch(localBuildScript, /ELEVENLABS_PRIVATE_BETA_API_KEY/);
  assert.match(localBuildScript, /ELEVENLABS_SENTRY_DSN/);
  for (const buildListLine of localBuildScript.match(/^.*build:list.*$/gm) ?? []) {
    assert.doesNotMatch(
      buildListLine,
      /--build-profile|--distribution|--channel/,
      "uploaded local builds do not carry cloud-build profile metadata",
    );
  }
  assert.match(updateWorkflow, /runs-on: ubuntu-latest/);
  assert.doesNotMatch(updateWorkflow, /runs-on: \[self-hosted/);
  assert.match(updateWorkflow, /EXPO_TOKEN/);
  assert.match(updateWorkflow, /^\s{2}push:/m);
  assert.match(updateWorkflow, /npm run eas:update/);
  assert.match(updateWorkflow, /cancel-in-progress: false/);
  assert.doesNotMatch(updateWorkflow, /\beas (?:build|submit|upload)\b/);
  assert.match(updateScript, /update \\/);
  assert.match(updateScript, /--channel production/);
  assert.match(updateScript, /--platform ios/);
  assert.match(updateScript, /--environment production/);
  assert.doesNotMatch(updateScript, /fingerprint:generate|build:list/);
  assert.doesNotMatch(updateScript, /\beas\[@\].*(?:build|submit|upload)/);
  assert.match(fingerprintConfig, /PackageJsonScriptsAll/);
  assert.match(fingerprintConfig, /scripts\/publish-ios-update\.sh/);
  assert.match(fingerprintConfig, /scripts\/build-ios-local\.sh/);
  assert.match(fingerprintConfig, /ios\/\*\.xcworkspace\/\*\*/);
  assert.match(fingerprintConfig, /ios\/Pods\/\*\*/);
  assert.match(fingerprintConfig, /ios\/ElevenLabsMac\/\*\*/);

  assert.equal(
    existsSync(
      new URL(
        "../.github/workflows/elevenlabs-testflight.yml",
        import.meta.url,
      ),
    ),
    true,
    "GitHub Actions must own the OTA-only deployment",
  );
  assert.equal(
    existsSync(
      new URL(
        "../apps/ElevenLabs/.eas/workflows/testflight.yml",
        import.meta.url,
      ),
    ),
    false,
    "the paid EAS cloud-build workflow must stay removed",
  );
  assert.match(mobilePackage.scripts["eas:update"], /publish-ios-update\.sh/);
  assert.match(mobilePackage.scripts["eas:release"], /eas:update/);
  assert.match(mobilePackage.scripts["eas:plan"], /eas:native:check/);
  assert.match(
    mobilePackage.scripts["eas:native:check"],
    /build-ios-local\.sh --check/,
  );
  assert.match(mobilePackage.scripts["eas:build:local"], /build-ios-local\.sh/);
  assert.match(easIgnore, /^\.eas-local-build$/m);
});

test("public iPhone release cannot bundle the operator's speech credential", () => {
  const info = read("apps/ElevenLabs/ios/ElevenLabs/Info.plist");
  const launch = read("apps/ElevenLabs/ios/ElevenLabs/AppDelegate.swift");
  const metadata = read("apps/ElevenLabs/scripts/sync-eas-ios-metadata.mjs");
  const build = read("apps/ElevenLabs/scripts/build-ios-local.sh");
  assert.doesNotMatch(info, /ElevenLabsPrivateBetaAPIKey|PRIVATE_BETA_API_KEY/);
  assert.doesNotMatch(launch, /PrivateBetaAPIKeyBootstrap/);
  assert.doesNotMatch(metadata, /PRIVATE_BETA_API_KEY|privateBetaApiKey/);
  assert.match(build, /Refusing to submit an IPA containing a bundled speech credential/);
  assert.ok(build.indexOf('Refusing to submit an IPA containing') < build.indexOf('"${eas[@]}" submit --platform ios'));
});

test("new users can reach their own credential setup before Control Center onboarding", () => {
  const app = read("apps/ElevenLabs/App.js");
  const onboarding = app.slice(app.indexOf('function Onboarding'), app.indexOf('function useReducedMotion'));
  assert.ok(onboarding.indexOf('!state.hasAPIKey') < onboarding.indexOf('!state.practicedControlCenterStart'));
  assert.match(onboarding, /<Button onPress={openSettings}>Add API key<\/Button>/);
  assert.match(app, /including live drafts while recording/);
  assert.match(app, /dictation\/privacy\//);
});

test("the public keyboard excludes private host capture and uses public local editing", () => {
  const project = read("apps/ElevenLabs/ios/ElevenLabs.xcodeproj/project.pbxproj");
  const controller = read("apps/ElevenLabs/ios/ElevenLabsKeyboard/KeyboardViewController.swift");
  const view = read("apps/ElevenLabs/ios/ElevenLabsKeyboard/KeyboardView.swift");
  assert.doesNotMatch(project, /HostApplicationCapture\.m in Sources|HostApplicationResolver\.swift in Sources/);
  assert.doesNotMatch(controller, /HostApplicationResolver|LSApplicationWorkspace|NSClassFromString|unsafeBitCast|openUsingResponderChain/);
  assert.match(controller, /textDocumentProxy\.insertText\(text\)/);
  assert.match(controller, /textDocumentProxy\.deleteBackward\(\)/);
  assert.match(controller, /advanceToNextInputMode\(\)/);
  assert.match(view, /if !model\.hasFullAccess \{\s+localKeyboard/);
  assert.match(view, /label: "Next keyboard", action: model\.nextKeyboard/);
});
