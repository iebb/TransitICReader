#!/usr/bin/env bash
# Shared paths and build steps for the iOS developer commands.

ios_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ios_project="$ios_repo_root/CardBal.xcodeproj"
ios_build_root="$ios_repo_root/build/ios"
ios_derived_data="$ios_build_root/DerivedData"

ios_error() {
    printf 'Error: %s\n' "$*" >&2
    exit 2
}

ios_require_command() {
    command -v "$1" >/dev/null 2>&1 || ios_error "Required command not found: $1"
}

ios_select_device() {
    DEVICE_ID="${1:-${DEVICE_ID:-}}"
    [[ -n "$DEVICE_ID" ]] || ios_error 'Supply a device UDID argument or set DEVICE_ID.'
    [[ "$DEVICE_ID" =~ ^[[:alnum:]-]+$ ]] || ios_error 'DEVICE_ID must be a device UDID.'
}

ios_xcodebuild() {
    local arguments=(
        -project "$ios_project"
        -scheme "${SCHEME:-CardBal}"
        -configuration "$CONFIGURATION"
        -derivedDataPath "$ios_derived_data"
    )
    # Omit signing overrides by default so the project remains authoritative.
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
        arguments+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    fi
    if [[ -n "${PRODUCT_BUNDLE_IDENTIFIER:-}" ]]; then
        arguments+=("PRODUCT_BUNDLE_IDENTIFIER=$PRODUCT_BUNDLE_IDENTIFIER")
    fi
    xcodebuild "${arguments[@]}" "$@"
}

ios_build_and_launch() {
    ios_require_command xcodebuild
    ios_require_command xcrun
    [[ -x /usr/libexec/PlistBuddy ]] || ios_error 'PlistBuddy is required on macOS.'
    mkdir -p "$ios_build_root"

    printf 'Building for device %s...\n' "$DEVICE_ID"
    ios_xcodebuild -destination "platform=iOS,id=$DEVICE_ID" \
        -allowProvisioningUpdates build

    local applications=("$ios_derived_data/Build/Products/$CONFIGURATION-iphoneos/"*.app)
    [[ ${#applications[@]} -eq 1 && -d "${applications[0]}" ]] \
        || ios_error 'Expected one built app in this checkout’s DerivedData products.'
    ios_app_path="${applications[0]}"
    ios_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ios_app_path/Info.plist")"
    ios_process_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ios_app_path/Info.plist")"
    [[ -n "$ios_bundle_id" && -n "$ios_process_name" ]] \
        || ios_error 'The built app must declare its bundle identifier and executable.'

    printf 'Installing %s...\n' "$ios_bundle_id"
    xcrun devicectl device install app --device "$DEVICE_ID" "$ios_app_path"
    # This replaces only this app on the selected device.
    xcrun devicectl device process launch --device "$DEVICE_ID" \
        --terminate-existing "$ios_bundle_id"
}
