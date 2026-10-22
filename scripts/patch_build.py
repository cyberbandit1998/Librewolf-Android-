#!/usr/bin/env python3
"""Small edits to Mozilla's build files so a release tarball can be bootstrapped.

Every edit must match, so a Firefox release that changes these files fails here
rather than later in a hours-long build.
"""
import argparse
import pathlib
import re
import sys


def sub(path, pattern, repl, what):
    text = path.read_text(encoding="utf-8")
    new, n = re.subn(pattern, repl, text)
    if n != 1:
        sys.exit(f"patch_build: {what}: expected 1 match in {path}, found {n}")
    path.write_text(new, encoding="utf-8")
    print(f"patch_build: {what}: patched {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", required=True, help="Firefox source root")
    args = ap.parse_args()
    src = pathlib.Path(args.src)

    # `mach bootstrap` evaluates configure for an x86_64 Android target regardless of
    # our mozconfig, and then insists on fetching a prebuilt ONNX Runtime that is not
    # always on Mozilla's CI index. We build without it (--without-onnx-runtime), so
    # never ask bootstrap to fetch it.
    sub(
        src / "toolkit/moz.configure",
        r"(?P<head>def need_boostrap_onnxruntime\(with_onnx_runtime\):\n)"
        r"(?P<ind>[ \t]+)return \(with_onnx_runtime and len\(with_onnx_runtime\) == 0\) or \(\n"
        r"[ \t]+with_onnx_runtime\.origin == \"default\"\n"
        r"[ \t]+\)",
        r"\g<head>\g<ind># Patched out: never bootstrap the prebuilt ONNX Runtime.\n"
        r"\g<ind>return False",
        "onnxruntime bootstrap",
    )


if __name__ == "__main__":
    main()
