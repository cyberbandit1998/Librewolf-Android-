#!/usr/bin/env bash
# Build an unofficial LibreWolf-flavoured Firefox for Android (arm64-v8a).
#
# Stages run in order up to $STOP_AFTER:
#   prepare      fetch LibreWolf settings + Firefox source, apply prefs/branding
#   bootstrap    mach bootstrap (Rust, clang, Android SDK/NDK, ...)
#   configure    mach configure
#   gradle-check Gradle configuration phase only (catches broken build.gradle edits)
#   build        mach build (hours)
#   package      assemble, zipalign and sign the APK into dist/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$HOME/librewolf-android-work}"
DIST="$REPO_ROOT/dist"
STOP_AFTER="${STOP_AFTER:-package}"
FIREFOX_VERSION="${FIREFOX_VERSION:-}"
LIBREWOLF_SOURCE_URL="${LIBREWOLF_SOURCE_URL:-https://codeberg.org/librewolf/source.git}"
LIBREWOLF_SOURCE_REF="${LIBREWOLF_SOURCE_REF:-}"
APP_NAME="${APP_NAME:-LibreWolf}"
APP_ID="${APP_ID:-io.github.cyberbandit1998.librewolf}"
APP_SCHEME="${APP_SCHEME:-librewolf}"
export MOZBUILD_STATE_PATH="${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}"

STAGES=(prepare bootstrap configure gradle-check build package)
LW="$WORK/librewolf-source"
GROUP_OPEN=0

die() { echo "build: $*" >&2; exit 1; }

group() {
  ((GROUP_OPEN)) && echo "::endgroup::"
  echo "::group::$*"
  GROUP_OPEN=1
}

on_exit() {
  ((GROUP_OPEN)) && echo "::endgroup::"
  mkdir -p "$DIST/logs"
  cp "$WORK"/firefox-*/obj-*/config.log "$DIST/logs/" 2>/dev/null || true
}
trap on_exit EXIT

printf '%s\n' "${STAGES[@]}" | grep -qx -- "$STOP_AFTER" ||
  die "unknown STOP_AFTER '$STOP_AFTER' (expected one of: ${STAGES[*]})"

stage_enabled() {
  local s
  for s in "${STAGES[@]}"; do
    [[ $s == "$1" ]] && return 0
    [[ $s == "$STOP_AFTER" ]] && return 1
  done
  return 1
}

src_dir() { echo "$WORK/firefox-$(<"$WORK/version")"; }

resolve_version() {
  if [[ -z $FIREFOX_VERSION && -f $LW/version ]]; then
    FIREFOX_VERSION=$(tr -d '[:space:]' <"$LW/version")
    echo "Using Firefox $FIREFOX_VERSION from LibreWolf's version file"
  fi
  if [[ -z $FIREFOX_VERSION ]]; then
    FIREFOX_VERSION=$(curl -fsS https://product-details.mozilla.org/1.0/firefox_versions.json |
      python3 -I -c 'import json,sys; print(json.load(sys.stdin)["LATEST_FIREFOX_VERSION"])')
    echo "No LibreWolf version file; using latest release $FIREFOX_VERSION"
  fi
  [[ $FIREFOX_VERSION =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
    die "'$FIREFOX_VERSION' is not a Firefox release version"
  echo "$FIREFOX_VERSION" >"$WORK/version"
}

fetch_librewolf() {
  group "LibreWolf source"
  [[ $LIBREWOLF_SOURCE_URL == https://* ]] || die "LIBREWOLF_SOURCE_URL must be an https:// URL"
  echo "Cloning $LIBREWOLF_SOURCE_URL"
  local args=(--depth 1)
  [[ -n $LIBREWOLF_SOURCE_REF ]] && args+=(--branch "$LIBREWOLF_SOURCE_REF")
  git clone "${args[@]}" "$LIBREWOLF_SOURCE_URL" "$LW"
  git -C "$LW" log -1 --format='%H %s'
  # Only the settings submodule is needed; skip translations and the rest.
  local path
  while read -r _ path; do
    case $path in *settings*) git -C "$LW" submodule update --init --depth 1 -- "$path" ;; esac
  done < <(git -C "$LW" config -f .gitmodules --get-regexp '^submodule\..*\.path$' || true)
  echo "--- LibreWolf source tree"
  ls -A "$LW"
}

fetch_firefox() {
  group "Firefox $FIREFOX_VERSION source"
  local base="https://archive.mozilla.org/pub/firefox/releases/$FIREFOX_VERSION"
  local tarball="firefox-$FIREFOX_VERSION.source.tar.xz"
  curl -fSL --retry 5 --retry-delay 5 -o "$WORK/$tarball" "$base/source/$tarball"
  curl -fSL --retry 5 --retry-delay 5 -o "$WORK/SHA512SUMS" "$base/SHA512SUMS"
  local expected
  expected=$(awk -v f="source/$tarball" '$2 == f { print $1 }' "$WORK/SHA512SUMS")
  [[ -n $expected ]] || { grep source "$WORK/SHA512SUMS" || true; die "no checksum listed for $tarball"; }
  (cd "$WORK" && echo "$expected  $tarball" | sha512sum -c -)
  tar -xf "$WORK/$tarball" -C "$WORK"
  rm -f "$WORK/$tarball"
  [[ -d $(src_dir) ]] || die "tarball did not extract to $(src_dir)"
}

# Print what this Firefox release looks like so the edits below can be checked
# against the real tree (and fixed from the log when a release moves things).
inspect_tree() {
  local src=$1
  group "Inspect Firefox tree"
  ls "$src/mobile/android"
  echo "--- mobile/android/app"
  ls "$src/mobile/android/app"
  echo "--- mobile/android/branding"
  ls "$src/mobile/android/branding" 2>/dev/null || true
  echo "--- applicationId in fenix/app/build.gradle"
  grep -n 'applicationId' "$src/mobile/android/fenix/app/build.gradle" || true
  echo "--- app_name strings"
  grep -rn 'name="app_name"' "$src/mobile/android/fenix/app/src" --include='*.xml' || true
  echo "--- Google / Firebase dependencies in the build files"
  grep -rnE 'play[-.]services|firebase|com\.google\.android\.gms|installreferrer|google-services' \
    "$src/mobile/android" "$src/gradle" --include='*.gradle' --include='*.kts' --include='*.toml' |
    sed "s#^$src/##" | head -n 80 || true
  echo "--- onnxruntime in bootstrap / toolchain definitions"
  grep -rIn onnxruntime "$src/python/mozboot" "$src/taskcluster/kinds/toolchain" 2>/dev/null |
    sed "s#^$src/##" | head -n 40 || true
  grep -rIln onnxruntime "$src/mobile/android" "$src/toolkit/moz.configure" "$src/build" 2>/dev/null |
    sed "s#^$src/##" | head -n 20 || true
  echo "--- where bootstrap installs Android packages"
  grep -n 'def install_mobile_android_packages' -A45 \
    "$src/python/mozboot/mozboot/linux_common.py" "$src/python/mozboot/mozboot/base.py" 2>/dev/null |
    sed "s#^$src/##" | head -n 120 || true
}

apply_librewolf_prefs() {
  local src=$1 cfg target
  cfg=$(find "$LW" -name librewolf.cfg -not -path '*/.git/*' | head -n1)
  [[ -n $cfg ]] || die "librewolf.cfg not found under $LW"
  target="$src/mobile/android/app/geckoview-prefs.js"
  [[ -f $target ]] || die "$target not found"
  group "LibreWolf prefs from ${cfg#"$LW"/}"
  python3 -I "$REPO_ROOT/scripts/librewolf_prefs.py" --cfg "$cfg" \
    --denylist "$REPO_ROOT/config/pref-denylist.txt" --out "$WORK/librewolf-prefs.js"
  { echo; cat "$WORK/librewolf-prefs.js"; } >>"$target"
}

prepare() {
  [[ -n $WORK && $WORK != / && $WORK != "$HOME" ]] || die "refusing to wipe WORK='$WORK'"
  rm -rf "$WORK"
  mkdir -p "$WORK" "$DIST"
  fetch_librewolf
  resolve_version
  fetch_firefox
  local src
  src=$(src_dir)
  inspect_tree "$src"
  apply_librewolf_prefs "$src"
  group "Rebrand"
  python3 -I "$REPO_ROOT/scripts/rebrand.py" --src "$src" --name "$APP_NAME" \
    --app-id "$APP_ID" --scheme "$APP_SCHEME" --overlay "$REPO_ROOT/branding/overlay"
  cp "$REPO_ROOT/config/mozconfig.arm64" "$src/mozconfig"
}

bootstrap() {
  cd "$(src_dir)"
  ./mach --no-interactive bootstrap \
    --application-choice="GeckoView/Firefox for Android" --no-system-changes
}

configure() {
  cd "$(src_dir)"
  ./mach configure
}

gradle_check() {
  cd "$(src_dir)"
  ./mach gradle fenix:assembleRelease --dry-run
}

build() {
  cd "$(src_dir)"
  ./mach build
}

package() {
  local src apk
  src=$(src_dir)
  cd "$src"
  ./mach gradle fenix:assembleRelease
  group "APK outputs"
  find "$src"/obj-* -name '*.apk' -not -name '*androidTest*' | sort
  apk=$(find "$src"/obj-* -name '*.apk' -not -name '*androidTest*' |
    grep -i release | grep -iE 'arm64|aarch64' | head -n1)
  [[ -n $apk ]] || die "no arm64 release APK found"
  local out="$DIST/librewolf-android-$FIREFOX_VERSION-arm64-v8a.apk"
  group "Sign $apk"
  "$REPO_ROOT/scripts/sign-apk.sh" "$apk" "$out"
  (cd "$DIST" && sha256sum "$(basename "$out")" >SHA256SUMS)
  echo "$FIREFOX_VERSION" >"$DIST/VERSION"
  ls -l "$DIST"
}

run_stage() {
  local name=$1 fn=${1//-/_}
  if stage_enabled "$name"; then
    group "stage: $name"
    "$fn"
  else
    echo "Skipping stage: $name"
  fi
}

for s in "${STAGES[@]}"; do run_stage "$s"; done
