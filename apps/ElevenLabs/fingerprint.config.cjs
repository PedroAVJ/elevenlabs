module.exports = {
  sourceSkips: ["PackageJsonScriptsAll"],
  ignorePaths: [
    "scripts/publish-ios-update.sh",
    "scripts/build-ios-local.sh",
    "ios/*.xcworkspace/**",
    "ios/Pods/**",
    "ios/build/**",
    "ios/.xcode.env.local",
    "ios/ElevenLabsMac/**",
    "ios/ElevenLabsMacTests/**",
    "ios/ElevenLabsTests/**",
    "ios/ElevenLabs.xcodeproj/xcshareddata/xcschemes/ElevenLabsMac.xcscheme",
  ],
};
