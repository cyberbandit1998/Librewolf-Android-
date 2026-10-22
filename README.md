# LibreWolf for Android (unofficial)

LibreWolf has no Android release. This repo builds **Firefox for Android (Fenix/GeckoView)
from Mozilla's source tarball** with **LibreWolf's default prefs** applied, on GitHub Actions,
and produces a signed arm64-v8a APK.

It is not affiliated with LibreWolf or Mozilla.

## What it does

| Step | Source |
| --- | --- |
| Firefox version | pinned by [`librewolf/source`](https://codeberg.org/librewolf/source)'s `version` file (override with `firefox_version`) |
| Firefox source | `archive.mozilla.org` release tarball, SHA-512 checked |
| Prefs | `librewolf.cfg` from LibreWolf's settings submodule, literal `defaultPref/pref/lockPref` calls converted to `pref()` lines appended to `mobile/android/app/geckoview-prefs.js` (`config/pref-denylist.txt` filters out a few) |
| Identity | own application id and app name (`scripts/rebrand.py`), so it installs next to Firefox; icons via `branding/overlay/` |
| Build | `config/mozconfig.arm64`, then `./mach build` and `./mach gradle fenix:assembleRelease` |
| Signing | `apksigner`; your key if the secrets below are set, otherwise a throwaway key |

## Running it

Actions → **Build Android** → *Run workflow*. `stop_after` picks the last stage:
`prepare`, `bootstrap`, `configure`, `gradle-check` are cheap checks;
`build` takes hours (arm64, no LTO, on a 4-core runner); `package` (default) produces the APK
as the `librewolf-android` artifact, or as a release with `publish_release`.

Pushes to non-`main` branches run the cheap stages up to `gradle-check` only.

To keep updating the same install, add these repository secrets so every build is signed with
the same key: `SIGNING_KEYSTORE_B64` (base64 of your `.jks`), `SIGNING_KEYSTORE_PASSWORD`,
`SIGNING_KEY_ALIAS`, optionally `SIGNING_KEY_PASSWORD`.
Without them each build gets a new throwaway key and must be uninstalled before the next one.

`scripts/build.sh` also runs on a Linux machine with ~60 GB free disk and 16 GB RAM
(`STOP_AFTER=... scripts/build.sh`).

## Limitations

- **Not LibreWolf's patch set.** The patches in LibreWolf's repo target desktop `browser/`.
  Only the prefs carry over. Fenix-layer telemetry (Glean, Nimbus experiments, Sentry),
  Pocket/sponsored content and similar are not removed in code; the prefs only cover what
  Gecko itself reads. Removing those needs Fenix-specific patches (IronFox does this).
- **Enterprise policies / uBlock Origin bundling** (`policies.json`) are not applied; install
  uBlock Origin from the add-on menu.
- Fenix sets some prefs at runtime from app settings, which override the defaults here.
- Rebranding is by name and id only. Replace the Firefox icons via `branding/overlay/` before
  sharing builds; Mozilla's trademark policy does not allow its name and logo on modified builds.
- arm64-v8a only.
