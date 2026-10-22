#!/usr/bin/env bash
# Build an unofficial LibreWolf-flavoured Firefox for Android (arm64-v8a).
#
# Stages run in order up to $STOP_AFTER:
#   prepare      fetch LibreWolf settings + Firefox source, apply prefs/branding
#   bootstrap    mach bootstrap (clang, Android SDK/NDK, JDK, ...)
#   check        frontend-only configure + build + Gradle dry run (minutes): catches broken
#                build.gradle edits before the long build; uses its own objdir
#   configure    mach configure for the real build
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

STAGES=(prepare bootstrap check configure build package)
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

# Bootstrap runs its own configure pass; make every mach call use our mozconfig.
enter_src() {
  cd "$(src_dir)"
  export MOZCONFIG="$PWD/${1:-mozconfig}"
}

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
  echo "--- build/mozconfig.no-compile and artifact mozconfigs"
  local f
  for f in build/mozconfig.no-compile build/mozconfig.artifact build/mozconfig.artifact.automation; do
    echo "=== $f"
    cat "$src/$f" 2>/dev/null || echo "(missing)"
  done
  echo "--- root build.gradle: required objdir files"
  sed -n '190,260p' "$src/build.gradle"
  echo "--- who produces buildid.h"
  grep -rIn 'buildid\.h' "$src/config" "$src/build" --include='*.build' --include='Makefile.in' \
    --include='*.mk' --include='*.py' 2>/dev/null | sed "s#^$src/##" | head -n 15 || true
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
  # Diagnostics only: never let them abort the build (greps into `head` can SIGPIPE).
  inspect_tree "$src" || echo "(inspection failed; continuing)"
  apply_librewolf_prefs "$src"
  group "Rebrand"
  python3 -I "$REPO_ROOT/scripts/rebrand.py" --src "$src" --name "$APP_NAME" \
    --app-id "$APP_ID" --scheme "$APP_SCHEME" --overlay "$REPO_ROOT/branding/overlay"
  group "Build file patches"
  python3 -I "$REPO_ROOT/scripts/patch_build.py" --src "$src"
  cp "$REPO_ROOT/config/mozconfig.arm64" "$src/mozconfig"
  cp "$REPO_ROOT/config/mozconfig.check" "$src/mozconfig.check"
}

bootstrap() {
  enter_src
  # Sample the process list while bootstrap runs, to see which command asks for
  # which toolchain (the failing request is made by a subprocess of mach).
  local tracer=0 trace="$WORK/bootstrap-ps.log" rc=0
  if [[ -n ${TRACE_BOOTSTRAP:-} ]]; then
    (
      set +e
      while sleep 1; do
        ps -eo pid,ppid,args | grep -E '[m]ach|[c]onfigure|[a]rtifact' | cut -c1-400
        for pid in $(pgrep -f 'artifact toolchain' || true); do
          echo "env[$pid]: $(tr '\0' ' ' <"/proc/$pid/environ" 2>/dev/null |
            grep -oE '(MOZCONFIG|MOZ_OBJDIR|MOZBUILD_STATE_PATH)=[^ ]*' | tr '\n' ' ')"
        done
      done
    ) >"$trace" 2>&1 &
    tracer=$!
  fi
  # No --no-system-changes: that flag skips the Android SDK/NDK install and only
  # fetches the JDK and emulator image. Fine to let it touch a disposable runner.
  ./mach --no-interactive bootstrap \
    --application-choice="GeckoView/Firefox for Android" || rc=$?
  if ((tracer)); then
    kill "$tracer" 2>/dev/null || true
    group "bootstrap process trace"
    awk '!seen[$0]++' "$trace" | head -n 120
  fi
  if ((rc)); then
    echo "bootstrap failed with exit code $rc"
    [[ -n ${BOOTSTRAP_NONFATAL:-} ]] || return "$rc"
    echo "BOOTSTRAP_NONFATAL set: continuing so later stages show what is still missing"
  fi
}

configure() {
  enter_src
  ./mach configure
}

check() {
  enter_src mozconfig.check
  ./mach configure
  ./mach build
  ./mach gradle fenix:assembleRelease --dry-run
}

build() {
  enter_src
  ./mach build
}

package() {
  local src apk
  src=$(src_dir)
  enter_src
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
