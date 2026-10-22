#!/usr/bin/env python3
"""Convert LibreWolf's librewolf.cfg (AutoConfig) into plain Gecko pref() lines.

AutoConfig is a desktop mechanism. GeckoView reads default prefs from mobile.js, so
only calls with literal values (defaultPref/pref/lockPref/sticky_pref) are carried
over. Anything else (JS logic, computed values) is reported and skipped.
"""
import argparse
import re
import sys

CALL_START = re.compile(r"\b(defaultPref|pref|lockPref|sticky_pref)\s*\(")
CALL = re.compile(
    r"^\s*(?:defaultPref|pref|lockPref|sticky_pref)\(\s*"
    r"(?P<q>[\"'])(?P<name>[^\"']+)(?P=q)\s*,\s*"
    r"(?P<value>true|false|-?\d+|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')\s*\)\s*;"
)


def load_denylist(path):
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                entries.append(line)
    return entries


def denied(name, entries):
    return any(
        name.startswith(e[:-1]) if e.endswith("*") else name == e for e in entries
    )


def normalise(value):
    if value.startswith("'"):
        inner = value[1:-1].replace("\\'", "'").replace('"', '\\"')
        return f'"{inner}"'
    return value


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cfg", required=True, help="path to librewolf.cfg")
    ap.add_argument("--denylist", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.cfg, encoding="utf-8") as f:
        text = re.sub(r"/\*.*?\*/", "", f.read(), flags=re.S)
    deny = load_denylist(args.denylist)

    prefs = {}
    skipped, dropped = [], []
    for line in text.splitlines():
        if line.lstrip().startswith("//") or not CALL_START.search(line):
            continue
        m = CALL.match(line)
        if not m:
            skipped.append(line.strip())
        elif denied(m["name"], deny):
            dropped.append(m["name"])
        elif re.search(r"@\w+@", m["value"]):
            # geckoview-prefs.js goes through the preprocessor's substitution filter.
            skipped.append(line.strip())
        else:
            prefs[m["name"]] = normalise(m["value"])

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("// Generated from LibreWolf's librewolf.cfg by librewolf_prefs.py.\n")
        for name, value in prefs.items():
            f.write(f'pref("{name}", {value});\n')

    print(
        f"librewolf_prefs: {len(prefs)} prefs kept, {len(dropped)} denied, "
        f"{len(skipped)} lines skipped",
        file=sys.stderr,
    )
    for name in dropped:
        print(f"  denied:  {name}", file=sys.stderr)
    for line in skipped:
        print(f"  skipped: {line}", file=sys.stderr)
    if not prefs:
        sys.exit("librewolf_prefs: no prefs found, is this really librewolf.cfg?")


if __name__ == "__main__":
    main()
