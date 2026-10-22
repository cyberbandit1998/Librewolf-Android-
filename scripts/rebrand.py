#!/usr/bin/env python3
"""Give the Fenix build its own application id and name, then apply branding/overlay.

Every edit must match at least once, so a Firefox release that moves things around
fails loudly here instead of producing an APK that replaces the real Firefox.
"""
import argparse
import pathlib
import re
import shutil
import sys


def sub(path, pattern, repl, what):
    text = path.read_text(encoding="utf-8")
    new, n = re.subn(pattern, repl, text)
    if n == 0:
        sys.exit(f"rebrand: {what}: pattern not found in {path}")
    path.write_text(new, encoding="utf-8")
    print(f"rebrand: {what}: {n} replacement(s) in {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", required=True, help="Firefox source root")
    ap.add_argument("--name", required=True)
    ap.add_argument("--app-id", required=True)
    ap.add_argument("--scheme", default="librewolf", help="release deep link scheme")
    ap.add_argument("--overlay", required=True, help="directory copied over fenix/")
    args = ap.parse_args()

    if not re.fullmatch(r"[A-Za-z]\w*(\.[A-Za-z]\w*)+", args.app_id):
        sys.exit(f"rebrand: invalid application id '{args.app_id}'")
    if not re.fullmatch(r"[a-z][a-z0-9+.-]*", args.scheme):
        sys.exit(f"rebrand: invalid deep link scheme '{args.scheme}'")

    fenix = pathlib.Path(args.src) / "mobile/android/fenix"
    gradle = fenix / "app/build.gradle"
    if not gradle.is_file():
        sys.exit(f"rebrand: {gradle} not found")

    # Release is "org.mozilla" + ".firefox"; collapse it to a single id of our own.
    sub(gradle, r"applicationId(\s*=?\s*)([\"'])org\.mozilla\2",
        rf'applicationId\1"{args.app_id}"', "applicationId")
    sub(gradle, r"applicationIdSuffix(\s*=?\s*)([\"'])\.firefox\2",
        r'applicationIdSuffix\1""', "release applicationIdSuffix")

    # Release declares Firefox's sharedUserId; Android refuses to install a second app
    # with it next to real Firefox unless both are signed with the same key.
    sub(gradle, r"(\"sharedUserId\":\s*)\"org\.mozilla\.firefox\.sharedID\"",
        rf'\1"{args.app_id}.sharedID"', "sharedUserId")
    sub(gradle, r"(def deepLinkSchemeValue = )\"fenix\"",
        rf'\1"{args.scheme}"', "deep link scheme")

    app_name = re.compile(r"(<string\s+name=\"app_name\"[^>]*>)[^<]*(</string>)")
    total = 0
    for xml in (fenix / "app/src").glob("*/res/values/*.xml"):
        text = xml.read_text(encoding="utf-8")
        new, n = app_name.subn(rf"\g<1>{args.name}\g<2>", text)
        if n:
            xml.write_text(new, encoding="utf-8")
            total += n
    if total == 0:
        sys.exit("rebrand: no app_name string found under fenix/app/src")
    print(f"rebrand: app_name: {total} replacement(s)")

    overlay = pathlib.Path(args.overlay)
    for f in sorted(p for p in overlay.rglob("*") if p.is_file()):
        if f.name == "README.md":
            continue
        dest = fenix / f.relative_to(overlay)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, dest)
        print(f"rebrand: overlay {f.relative_to(overlay)}")


if __name__ == "__main__":
    main()
