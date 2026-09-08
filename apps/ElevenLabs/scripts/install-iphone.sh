#!/bin/sh
# Build, sign, and install the iPhone app and its keyboard on a physical device.
# This is an exceptional local-development operation, not the release path.
# Production ships through the guarded Expo/EAS workflow. Installing this build
# replaces the app and its extensions and can interrupt active dictation.
#
# The repo ships generic `com.example` identifiers on purpose. A real device
# needs identifiers owned by a developer account, so this script supplies local
# values through overridable build settings. It never edits tracked files. Put
# your own values in scripts/local-identity.env, which is untracked. When
# running from a Git worktree, point
# ELEVENLABS_IDENTITY_ENV at the main checkout's copy:
#
#   APP_BUNDLE_ID=com.you.ElevenLabs
#   APP_GROUP=group.com.you.ElevenLabs
#   DEVELOPMENT_TEAM=ABCDE12345
#   SIGNING_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)"
#   DEVICE=00000000-0000000000000000        # xcrun devicectl list devices
#   BUILD_NUMBER=2                          # optional; defaults to 1
#   ELEVENLABS_SENTRY_DSN=https://...       # optional; observability stays off
#                                           # without it
#
# Two Xcode constraints shape the steps below:
#
#   1. `-scheme` + `-destination` needs the full iOS *platform* installed, not
#      just the SDK. Building the target directly with `-sdk` does not.
#   2. Xcode 26's `actool` refuses to run at all without a simulator runtime
#      ("No available simulator runtimes"), even for a device-only build. The
#      asset catalog is therefore skipped and the app icon is installed the
#      pre-asset-catalog way, with plain PNGs and CFBundleIconFiles.

set -eu

launch_after_install=false
device_replacement_confirmed=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --confirm-device-replacement)
            device_replacement_confirmed=true
            ;;
        --launch-after-install)
            launch_after_install=true
            ;;
        --no-launch)
            launch_after_install=false
            ;;
        --help|-h)
            echo "usage: $0 --confirm-device-replacement [--launch-after-install]"
            echo
            echo "Production releases use Expo/EAS CI. This local tool replaces the"
            echo "installed app and keyboard and requires an interactive confirmation."
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "usage: $0 --confirm-device-replacement [--launch-after-install]" >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$device_replacement_confirmed" != true ]; then
    echo "error: manual device replacement was not explicitly authorized" >&2
    echo "Ship through Expo/EAS CI. Only after the user explicitly requests a manual" >&2
    echo "iPhone replacement in the current conversation, rerun with" >&2
    echo "--confirm-device-replacement." >&2
    exit 64
fi
if [ ! -t 0 ]; then
    echo "error: refusing device replacement without an interactive terminal" >&2
    exit 64
fi

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

env_file=${ELEVENLABS_IDENTITY_ENV:-scripts/local-identity.env}
if [ ! -f "$env_file" ]; then
    echo "error: $env_file not found. See the header of $0 for its contents." >&2
    exit 1
fi
case "$env_file" in
    /*) ;;
    *) env_file="./$env_file" ;;
esac
# shellcheck disable=SC1090
. "$env_file"

for required in APP_BUNDLE_ID APP_GROUP DEVELOPMENT_TEAM SIGNING_IDENTITY DEVICE; do
    eval "value=\${$required:-}"
    if [ -z "$value" ]; then
        echo "error: $required is not set in $env_file" >&2
        exit 1
    fi
done

build_number=${BUILD_NUMBER:-1}
keyboard_bundle_id=${KEYBOARD_BUNDLE_ID:-$APP_BUNDLE_ID.Keyboard}
live_activity_bundle_id=${LIVE_ACTIVITY_BUNDLE_ID:-$APP_BUNDLE_ID.LiveActivity}
tests_bundle_id=${TESTS_BUNDLE_ID:-${APP_BUNDLE_ID}Tests}

validate_identifier() {
    identifier_name=$1
    identifier_value=$2
    case "$identifier_value" in
        ""|.*|*.|*..*|*[!A-Za-z0-9.-]*)
            echo "error: $identifier_name is not a valid signing identifier" >&2
            exit 1
            ;;
    esac
}

validate_identifier APP_BUNDLE_ID "$APP_BUNDLE_ID"
validate_identifier KEYBOARD_BUNDLE_ID "$keyboard_bundle_id"
validate_identifier LIVE_ACTIVITY_BUNDLE_ID "$live_activity_bundle_id"
validate_identifier TESTS_BUNDLE_ID "$tests_bundle_id"
validate_identifier APP_GROUP "$APP_GROUP"
case "$APP_GROUP" in
    group.*) ;;
    *)
        echo "error: APP_GROUP must begin with group." >&2
        exit 1
        ;;
esac

build_dir=$(mktemp -d /tmp/ElevenLabsiOS.XXXXXX)
profile_cache_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
profile_backup_dir="$build_dir/profile-backups"
build_succeeded=false

restore_profile_backups() {
    [ -d "$profile_backup_dir" ] || return 0
    [ -d "$profile_cache_dir" ] || mkdir -p "$profile_cache_dir"
    for profile in "$profile_backup_dir"/*.mobileprovision; do
        [ -f "$profile" ] || continue
        mv "$profile" "$profile_cache_dir/$(basename "$profile")"
    done
}

cleanup() {
    if [ "$build_succeeded" = true ]; then
        rm -rf "$build_dir"
    else
        restore_profile_backups
        echo "==> Preserving failed build artifacts at $build_dir" >&2
    fi
}
trap cleanup EXIT

# Personal Team profiles expire after seven days. Reinstalling an app that was
# built with a nearly expired cached profile does not extend that deadline: iOS
# leaves the icon in place and later reports that the app is no longer
# available. Move only this app family's cached profiles aside so Xcode asks
# Apple for fresh profiles on every install. A failed run restores the old
# profiles from the preserved build directory.
if [ -d "$profile_cache_dir" ]; then
    mkdir -p "$profile_backup_dir"
    for profile in "$profile_cache_dir"/*.mobileprovision; do
        [ -f "$profile" ] || continue
        profile_app_id=$(security cms -D -i "$profile" 2>/dev/null \
            | plutil -extract Entitlements.application-identifier raw -o - - \
                2>/dev/null || true)
        case "$profile_app_id" in
            *."$APP_BUNDLE_ID"|*."$keyboard_bundle_id"|*."$live_activity_bundle_id")
                mv "$profile" "$profile_backup_dir/"
                ;;
        esac
    done
fi

# Xcode's capability renewal reads literal values from the entitlements file.
# A tracked $(ELEVENLABS_APP_GROUP_IDENTIFIER) keeps the public project generic,
# but can yield a renewed profile with no App Group. Resolve exact, temporary
# entitlement files for the signed device build so the containing app and
# keyboard remain associated with the existing shared container.
app_entitlements="$build_dir/ElevenLabs.entitlements"
keyboard_entitlements="$build_dir/ElevenLabsKeyboard.entitlements"
cp ios/ElevenLabs/ElevenLabs.entitlements "$app_entitlements"
cp ios/ElevenLabsKeyboard/ElevenLabsKeyboard.entitlements "$keyboard_entitlements"
for entitlements in "$app_entitlements" "$keyboard_entitlements"; do
    /usr/libexec/PlistBuddy \
        -c "Delete :com.apple.security.application-groups" \
        "$entitlements" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.security.application-groups array" \
        "$entitlements" >/dev/null
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.security.application-groups: string $APP_GROUP" \
        "$entitlements" >/dev/null
done

if [ ! -d node_modules/expo ]; then
    echo "error: Expo dependencies are missing. Run 'npm ci' first." >&2
    exit 1
fi

echo "==> Linking Expo iOS dependencies"
(cd ios && pod install --silent)

echo "==> Building $APP_BUNDLE_ID ($build_number) for device"
xcodebuild \
    -workspace ios/ElevenLabs.xcworkspace \
    -scheme ElevenLabs \
    -configuration Debug \
    -sdk iphoneos \
    -jobs 1 \
    -derivedDataPath "$build_dir/DerivedData" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$build_number" \
    ELEVENLABS_APP_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" \
    ELEVENLABS_KEYBOARD_BUNDLE_IDENTIFIER="$keyboard_bundle_id" \
    ELEVENLABS_LIVE_ACTIVITY_BUNDLE_IDENTIFIER="$live_activity_bundle_id" \
    ELEVENLABS_TESTS_BUNDLE_IDENTIFIER="$tests_bundle_id" \
    ELEVENLABS_APP_GROUP_IDENTIFIER="$APP_GROUP" \
    ELEVENLABS_APP_ENTITLEMENTS_FILE="$app_entitlements" \
    ELEVENLABS_KEYBOARD_ENTITLEMENTS_FILE="$keyboard_entitlements" \
    ELEVENLABS_SENTRY_DSN="${ELEVENLABS_SENTRY_DSN:-}" \
    FORCE_BUNDLING=1 \
    EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets \
    ASSETCATALOG_COMPILER_APPICON_NAME= \
    ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME= \
    -packageAuthorizationProvider netrc \
    -skipPackageUpdates \
    -allowProvisioningUpdates \
    build >"$build_dir/build.log" 2>&1 || {
        echo "error: build failed. Last lines:" >&2
        tail -30 "$build_dir/build.log" >&2
        exit 1
    }

if grep -q '/usr/bin/actool' "$build_dir/build.log"; then
    echo "error: the device-only build unexpectedly invoked actool" >&2
    exit 1
fi

app="$build_dir/DerivedData/Build/Products/Debug-iphoneos/ElevenLabs.app"
icons="ios/ElevenLabs/Assets.xcassets/AppIcon.appiconset"

verify_app_group_entitlement() {
    bundle=$1
    label=$2
    extracted="$build_dir/$label.signed-entitlements.plist"
    codesign -d --entitlements "$extracted" --xml "$bundle" 2>/dev/null
    if ! /usr/libexec/PlistBuddy \
        -c "Print :com.apple.security.application-groups" \
        "$extracted" 2>/dev/null | grep -Fq "$APP_GROUP"; then
        echo "error: $label signature does not authorize $APP_GROUP" >&2
        exit 1
    fi
    if grep -Fq '$(' "$extracted"; then
        echo "error: $label signature contains an unresolved entitlement" >&2
        exit 1
    fi
}

verify_app_group_entitlement "$app" app
verify_app_group_entitlement \
    "$app/PlugIns/ElevenLabsKeyboard.appex" keyboard

profile_expiration=$(security cms -D -i "$app/embedded.mobileprovision" \
    2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)
if [ -z "$profile_expiration" ]; then
    echo "error: built app has no readable provisioning expiration" >&2
    exit 1
fi
echo "==> Provisioned through $profile_expiration"

echo "==> Installing app icon without the asset catalog"
for pair in "60@2x:AppIcon60x60@2x" "60@3x:AppIcon60x60@3x" \
            "40@2x:AppIcon40x40@2x" "40@3x:AppIcon40x40@3x" \
            "29@2x:AppIcon29x29@2x" "29@3x:AppIcon29x29@3x" \
            "20@2x:AppIcon20x20@2x" "20@3x:AppIcon20x20@3x"; do
    source_name=${pair%%:*}
    dest_name=${pair##*:}
    cp "$icons/AppIcon-${source_name}.png" "$app/${dest_name}.png"
done

if [ -e "$app/Assets.car" ]; then
    echo "error: the device-only build unexpectedly produced Assets.car" >&2
    exit 1
fi

plist="$app/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" "$plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$plist" >/dev/null
for name in AppIcon60x60 AppIcon40x40 AppIcon29x29 AppIcon20x20; do
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles: string $name" \
        "$plist" >/dev/null
done

actual_bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
actual_build_number=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
if [ "$actual_bundle_id" != "$APP_BUNDLE_ID" ] || \
   [ "$actual_build_number" != "$build_number" ]; then
    echo "error: built identity does not match the requested app" >&2
    exit 1
fi

# An unsubstituted or dropped DSN leaves the app silently uninstrumented, which
# looks identical to a healthy install until nothing ever arrives in Sentry.
actual_dsn=$(/usr/libexec/PlistBuddy -c "Print :SentryDSN" "$plist" 2>/dev/null || echo "")
if [ -n "${ELEVENLABS_SENTRY_DSN:-}" ] && \
   [ "$actual_dsn" != "$ELEVENLABS_SENTRY_DSN" ]; then
    echo "error: the configured Sentry DSN did not reach the built app" >&2
    exit 1
fi
if [ -n "$actual_dsn" ]; then
    echo "==> Observability on"
else
    echo "==> Observability off (no ELEVENLABS_SENTRY_DSN)"
fi
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFiles" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles array" "$plist" >/dev/null
for name in AppIcon60x60 AppIcon40x40 AppIcon29x29 AppIcon20x20; do
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleIconFiles: string $name" \
        "$plist" >/dev/null
done

# Editing the bundle invalidated the signature Xcode applied. Re-seal it with
# the entitlements the build already resolved, so the App Group survives.
echo "==> Re-signing"
codesign -d --entitlements "$build_dir/app.entitlements" --xml "$app" 2>/dev/null
codesign -f -s "$SIGNING_IDENTITY" \
    --entitlements "$build_dir/app.entitlements" \
    --generate-entitlement-der "$app" >/dev/null 2>&1
codesign --verify --deep --strict "$app"

echo "==> WARNING: this replaces the installed ElevenLabs app and keyboard"
echo "    and may interrupt an active dictation. Production ships through Expo/EAS."
printf "    Type REPLACE ELEVENLABS to continue: "
IFS= read -r replacement_confirmation
if [ "$replacement_confirmation" != "REPLACE ELEVENLABS" ]; then
    echo "error: device replacement cancelled" >&2
    exit 64
fi

echo "==> Installing on $DEVICE"
install_log="$build_dir/install.log"
if ! xcrun devicectl device install app \
    --device "$DEVICE" \
    "$app" >"$install_log" 2>&1; then
    echo "error: the device did not accept the app installation" >&2
    tail -20 "$install_log" >&2
    exit 1
fi
tail -5 "$install_log"

# A Mac cannot write to the device Keychain. Launch only when the separate
# --launch-after-install action was explicitly requested. DEVICECTL_CHILD_
# keeps the value out of the command line, and nothing prints it.
if [ "$launch_after_install" = false ]; then
    echo "==> Installed without launching ElevenLabs"
elif [ -n "${ELEVENLABS_API_KEY:-}" ]; then
    echo "==> Seeding the ElevenLabs key into the device Keychain"
    if DEVICECTL_CHILD_ELEVENLABS_API_KEY="$ELEVENLABS_API_KEY" \
        xcrun devicectl device process launch \
        --device "$DEVICE" \
        --terminate-existing \
        "$APP_BUNDLE_ID" >"$build_dir/launch.log" 2>&1; then
        echo "    seeded"
    else
        echo "    installed; unlock the iPhone and open ElevenLabs to finish launch"
    fi
else
    echo "==> Launching"
    if ! xcrun devicectl device process launch \
        --device "$DEVICE" \
        --terminate-existing \
        "$APP_BUNDLE_ID" >"$build_dir/launch.log" 2>&1; then
        echo "    installed; unlock the iPhone and open ElevenLabs to finish launch"
    fi
fi

echo "==> Verifying installed build"
installed_apps_log="$build_dir/installed-apps.log"
if ! xcrun devicectl device info apps \
    --device "$DEVICE" \
    --bundle-id "$APP_BUNDLE_ID" \
    --columns '*' >"$installed_apps_log" 2>&1; then
    echo "error: could not read the installed app back from the device" >&2
    tail -20 "$installed_apps_log" >&2
    exit 1
fi
tail -2 "$installed_apps_log"

build_succeeded=true
