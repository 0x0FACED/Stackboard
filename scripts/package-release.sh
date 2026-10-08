#!/bin/bash
# Build and validate a Universal, ad-hoc signed release without Apple credentials.
set -euo pipefail
export LC_ALL=C

usage() {
    printf 'Usage: %s VERSION [DIRECTORY]\n       %s --verify-existing VERSION DIRECTORY\n' "$0" "$0" >&2
}

fail() {
    printf 'package-release: %s\n' "$*" >&2
    exit 1
}

mode=build
if [[ "${1-}" == --help ]]; then
    usage
    exit 0
elif [[ "${1-}" == --verify-existing ]]; then
    mode=verify
    shift
    [[ $# -eq 2 ]] || { usage; exit 1; }
else
    [[ $# -ge 1 && $# -le 2 ]] || { usage; exit 1; }
fi

version=${1#v}
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$version" =~ $version_pattern ]] || fail 'VERSION must be a stable canonical X.Y.Z version (optionally prefixed with v).'
build_number=${BUILD_NUMBER-1}
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_NUMBER must be a positive decimal integer without leading zeroes.'

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
helper="$script_dir/verify_release.py"
output=${2-"$repo_root/dist/$version"}
[[ -n "$output" ]] || fail 'DIRECTORY must not be empty.'
case "$output" in
    /*) ;;
    *) output="$PWD/$output" ;;
esac
[[ "$(uname -s)" == Darwin ]] || fail 'Packaging and signature verification require macOS.'
for tool in python3 ditto codesign lipo; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool is missing: $tool"
done
if [[ "$mode" == build ]]; then
    for tool in xcodebuild shasum; do
        command -v "$tool" >/dev/null 2>&1 || fail "Required tool is missing: $tool"
    done
fi
[[ -f "$helper" ]] || fail "Verification helper is missing: $helper"
[[ ! -L "$output" ]] || fail 'DIRECTORY must not be a symbolic link.'
if [[ -e "$output" ]]; then
    [[ -d "$output" ]] || fail 'DIRECTORY already exists and is not a directory.'
elif [[ "$mode" == verify ]]; then
    fail 'DIRECTORY must already contain Stackboard.zip and SHA256SUMS.'
else
    mkdir -p "$output"
fi
output=$(cd "$output" && pwd -P)

# Include dotfiles in the guard; no existing file is ever silently replaced.
shopt -s nullglob dotglob
for entry in "$output"/*; do
    [[ "$mode" != build ]] || fail 'Build DIRECTORY must be empty; refusing to overwrite existing contents.'
    case "${entry##*/}" in
        Stackboard.zip|SHA256SUMS|release.json)
            [[ -f "$entry" && ! -L "$entry" ]] || fail "Expected a regular, non-symlink file: $entry"
            ;;
        Stackboard.app)
            [[ -d "$entry" && ! -L "$entry" ]] || fail "Expected a non-symlink app directory: $entry"
            ;;
        *) fail "Unexpected contents in verification DIRECTORY: $entry" ;;
    esac
done
shopt -u nullglob dotglob
if [[ "$mode" == verify ]]; then
    [[ -f "$output/Stackboard.zip" && -f "$output/SHA256SUMS" ]] || fail 'Both Stackboard.zip and SHA256SUMS are required.'
fi

workspace=$(mktemp -d "${TMPDIR:-/tmp}/stackboard-release.XXXXXX")
cleanup() {
    # This directory was created exclusively by mktemp, never supplied by a caller.
    rm -rf "$workspace"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
stage="$workspace/package"
mkdir "$stage"

if [[ "$mode" == build ]]; then
    # Disable Xcode's Automatic/Apple Development signing; sign explicitly below.
    xcodebuild \
        -project "$repo_root/Stackboard.xcodeproj" \
        -scheme Stackboard \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$workspace/DerivedData" \
        ARCHS='arm64 x86_64' \
        ONLY_ACTIVE_ARCH=NO \
        CONFIGURATION_BUILD_DIR="$workspace/products" \
        MARKETING_VERSION="$version" \
        CURRENT_PROJECT_VERSION="$build_number" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY= \
        DEVELOPMENT_TEAM= \
        CODE_SIGN_ENTITLEMENTS= \
        build
    [[ -d "$workspace/products/Stackboard.app" ]] || fail 'xcodebuild did not produce Stackboard.app.'
    ditto "$workspace/products/Stackboard.app" "$stage/Stackboard.app"
    # Explicit empty entitlements prevent a debug get-task-allow entitlement.
    cat > "$workspace/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
    codesign --force --deep --sign - --timestamp=none \
        --entitlements "$workspace/entitlements.plist" "$stage/Stackboard.app"
    ditto -c -k --sequesterRsrc --keepParent "$stage/Stackboard.app" "$stage/Stackboard.zip"
    (cd "$stage" && shasum -a 256 Stackboard.zip > SHA256SUMS)
    archive="$stage/Stackboard.zip"
    checksum="$stage/SHA256SUMS"
else
    # Published archives/checksums are only read, never copied over or re-signed.
    archive="$output/Stackboard.zip"
    checksum="$output/SHA256SUMS"
fi

sha256=$(python3 "$helper" archive "$archive" "$checksum")
mkdir "$workspace/unpacked"
ditto -x -k "$archive" "$workspace/unpacked"
# Verify the extracted artifact, not merely the app before ZIP creation.
if [[ "$mode" == build ]]; then
    python3 "$helper" app "$workspace/unpacked/Stackboard.app" "$version" "$sha256" "$stage/release.json" "$build_number"
else
    # A rerun's BUILD_NUMBER is not the build number in the immutable old ZIP.
    python3 "$helper" app "$workspace/unpacked/Stackboard.app" "$version" "$sha256" "$stage/release.json"
    ditto "$workspace/unpacked/Stackboard.app" "$stage/Stackboard.app"
fi
python3 "$helper" publish "$stage" "$output"
printf 'Verified Stackboard %s (%s). Artifacts: %s\n' "$version" "$sha256" "$output"
