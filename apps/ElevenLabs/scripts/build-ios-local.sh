#!/usr/bin/env bash
set -euo pipefail

mode="build"
if [ "${1:-}" = "--check" ]; then
  mode="check"
  shift
fi

if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--check]" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(git -C "$project_root" rev-parse --show-toplevel)"
cd "$project_root"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ElevenLabs native builds must run directly on the operator's Mac." >&2
  exit 1
fi

if [ -n "$(git status --porcelain=v1)" ]; then
  echo "Commit or remove local changes before checking or building ElevenLabs." >&2
  exit 1
fi

eas=(npx --yes eas-cli@22.2.0)

echo "==> Checking ElevenLabs native-build contracts"
npm test --prefix "$repo_root"
npm run export:ios
npx expo-updates configuration:syncnative --platform ios --workflow generic
git diff --exit-code -- ios

echo "==> Computing the deployed production iOS fingerprint"
fingerprint_json="$("${eas[@]}" fingerprint:generate --platform ios --build-profile production --json --non-interactive)"
fingerprint_hash="$(node -e 'let input=""; process.stdin.on("data", chunk => input += chunk); process.stdin.on("end", () => process.stdout.write(JSON.parse(input).hash));' <<<"$fingerprint_json")"
test -n "$fingerprint_hash"

echo "==> Checking for an Expo-registered binary with that fingerprint"
builds_json="$("${eas[@]}" build:list --platform ios --status finished --fingerprint-hash "$fingerprint_hash" --limit 1 --json --non-interactive)"
build_id="$(node -e 'let input=""; process.stdin.on("data", chunk => input += chunk); process.stdin.on("end", () => { const builds = JSON.parse(input); process.stdout.write(builds[0]?.id ?? ""); });' <<<"$builds_json")"

if [ -n "$build_id" ]; then
  echo "No local native build is needed. Expo already has compatible binary $build_id."
  exit 0
fi

if [ "$mode" = "check" ]; then
  echo "A local native build is required. Run npm run eas:build:local on the operator's Mac."
  exit 0
fi

if [ -z "${ELEVENLABS_SENTRY_DSN:-}" ]; then
  echo "Set ELEVENLABS_SENTRY_DSN in this local shell before building the production beta." >&2
  exit 1
fi

for tool in xcodebuild pod fastlane unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required local iOS build tool: $tool" >&2
    exit 1
  fi
done

native_root="$repo_root/.codex-artifacts/native-build"
mkdir -p "$native_root"
native_root="$(cd "$native_root" && pwd -P)"
case "$native_root" in
  "$repo_root"/*) ;;
  *) echo "Refusing native output outside this clone." >&2; exit 1 ;;
esac
echo "==> Running the native ElevenLabs suite serially"
swift test --scratch-path "$native_root/SwiftPM" --jobs 1

build_root="$native_root/release"
artifact_path="$build_root/ElevenLabs.ipa"
verification_root="$build_root/verify"
expected_root="$native_root/release"
test "$build_root" = "$expected_root"
mkdir -p "$build_root"
find "$build_root" -mindepth 1 -delete
mkdir -p "$build_root/tmp" "$build_root/archives"

build_root="$(cd "$build_root" && pwd -P)"
tmp_root="$(cd "$build_root/tmp" && pwd -P)"
archive_root="$(cd "$build_root/archives" && pwd -P)"
result_bundle_path="$build_root/result-bundle.xcresult"
for output_path in "$tmp_root" "$archive_root" "$result_bundle_path"; do
  case "$output_path" in
    "$build_root"/*) ;;
    *)
      echo "Refusing native build output outside $build_root: $output_path" >&2
      exit 1
      ;;
  esac
done

cleanup() {
  if [ -d "$build_root" ] && [ "$build_root" = "$expected_root" ]; then
    find "$build_root" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$build_root" 2>/dev/null || true
  fi
}
trap cleanup EXIT

export EAS_LOCAL_BUILD_WORKINGDIR="$build_root/work"
export EAS_LOCAL_BUILD_ARTIFACTS_DIR="$build_root/artifacts"
export TMPDIR="$tmp_root/"
export GYM_BUILD_PATH="$archive_root"
export GYM_RESULT_BUNDLE_PATH="$result_bundle_path"
export EXPO_NO_CAPABILITY_SYNC=1
export EXTRA_PACKAGER_ARGS="${EXTRA_PACKAGER_ARGS:-} --max-workers 1"

echo "==> Building the signed ElevenLabs IPA on this Mac"
"${eas[@]}" build --platform ios --profile production --local --output "$artifact_path" --non-interactive
test -s "$artifact_path"

echo "==> Verifying the IPA's embedded Expo fingerprint"
mkdir -p "$verification_root"
unzip -q "$artifact_path" -d "$verification_root"
app_plist="$(find "$verification_root/Payload" -maxdepth 2 -name Info.plist -type f -print -quit)"
test -n "$app_plist"
if /usr/libexec/PlistBuddy -c 'Print :ElevenLabsPrivateBetaAPIKey' "$app_plist" >/dev/null 2>&1; then
  echo "Refusing to submit an IPA containing a bundled speech credential." >&2
  exit 1
fi
expo_plist="$(find "$verification_root/Payload" -path '*/Expo.plist' -type f -print -quit)"
test -n "$expo_plist"
embedded_fingerprint="$(/usr/libexec/PlistBuddy -c 'Print :EXUpdatesRuntimeVersion' "$expo_plist")"
if [ "$embedded_fingerprint" != "$fingerprint_hash" ]; then
  echo "The local IPA runtime $embedded_fingerprint does not match deployed fingerprint $fingerprint_hash." >&2
  exit 1
fi

echo "==> Submitting the local IPA to TestFlight through Expo"
"${eas[@]}" submit --platform ios --profile production --path "$artifact_path" --non-interactive --wait

echo "==> Registering the submitted local binary with Expo"
"${eas[@]}" upload --platform ios --build-path "$artifact_path" --fingerprint "$fingerprint_hash" --json --non-interactive
registered_json="$("${eas[@]}" build:list --platform ios --status finished --fingerprint-hash "$fingerprint_hash" --limit 1 --json --non-interactive)"
node -e 'let input=""; process.stdin.on("data", chunk => input += chunk); process.stdin.on("end", () => { const builds = JSON.parse(input); if (!builds[0]?.id) process.exit(1); });' <<<"$registered_json"

echo "ElevenLabs was built locally, submitted to TestFlight, and registered with Expo."
