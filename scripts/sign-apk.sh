#!/usr/bin/env bash
# usage: sign-apk.sh <in.apk> <out.apk>
# Signs with SIGNING_KEYSTORE_B64 (+ _PASSWORD, KEY_ALIAS, KEY_PASSWORD) if set,
# otherwise with a throwaway key. Updates only install over a build signed with the
# same key, so set the secrets if you intend to keep updating.
set -euo pipefail

in=$1 out=$2
mozbuild="${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}"

find_tool() {
  find "$mozbuild" "${ANDROID_HOME:-/nonexistent}" -type f -name "$1" 2>/dev/null |
    sort -V | tail -n1
}
apksigner=$(find_tool apksigner)
zipalign=$(find_tool zipalign)
[[ -n $apksigner && -n $zipalign ]] || {
  echo "sign-apk: apksigner/zipalign not found under $mozbuild" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ -n ${SIGNING_KEYSTORE_B64:-} ]]; then
  base64 -d <<<"$SIGNING_KEYSTORE_B64" >"$tmp/release.jks"
  export KS_PASS=${SIGNING_KEYSTORE_PASSWORD:?SIGNING_KEYSTORE_PASSWORD is required}
  alias=${SIGNING_KEY_ALIAS:?SIGNING_KEY_ALIAS is required}
  export KEY_PASS=${SIGNING_KEY_PASSWORD:-$KS_PASS}
else
  echo "::warning::No signing key configured; using a throwaway key. This APK cannot be updated by a later build."
  export KS_PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
  export KEY_PASS=$KS_PASS
  alias=throwaway
  keytool -genkeypair -keystore "$tmp/release.jks" -storepass:env KS_PASS \
    -keypass:env KEY_PASS -alias "$alias" -keyalg RSA -keysize 4096 \
    -validity 10000 -dname "CN=Unofficial LibreWolf Android build"
fi

"$zipalign" -p -f 4 "$in" "$tmp/aligned.apk"
"$apksigner" sign --ks "$tmp/release.jks" --ks-key-alias "$alias" \
  --ks-pass env:KS_PASS --key-pass env:KEY_PASS --out "$out" "$tmp/aligned.apk"
"$apksigner" verify --verbose "$out"
