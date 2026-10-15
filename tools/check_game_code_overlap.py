"""Guard: report tracked lines that match the decompiled game's GDScript verbatim.

The game's code is not ours to publish. This compares every tracked text file
against decomp/ (local, gitignored) and fails if any file contains copied game
*logic*. Matching declarations (signal/var/func signatures we must mirror to
interoperate) are reported but allowed up to --max-decl per file.

    python -I tools/check_game_code_overlap.py [--max-decl N] [--verbose]
"""
import argparse
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DECL = re.compile(r"^(signal|var|const|@export|@onready|func|static func|class_name|extends|enum)\b")
MIN_LEN = 25
TEXT_EXT = (".gd", ".md", ".json", ".ps1", ".py", ".txt", ".cfg", ".tscn")
# Generic engine idioms that merely happen to also appear in the game (one per line).
ALLOW_FILE = os.path.join(ROOT, "tools", "game_overlap_allow.txt")


def allowlist():
    if not os.path.exists(ALLOW_FILE):
        return set()
    with open(ALLOW_FILE, encoding="utf-8") as fh:
        return {l.strip() for l in fh if l.strip() and not l.startswith("#")}


def game_lines():
    lines = set()
    for f in glob.glob(os.path.join(ROOT, "decomp", "**", "*.gd"), recursive=True):
        if os.sep + "addons" + os.sep in f:
            continue
        with open(f, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                s = line.strip()
                if len(s) >= MIN_LEN:
                    lines.add(s)
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-decl", type=int, default=40)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    if not os.path.isdir(os.path.join(ROOT, "decomp")):
        print("decomp/ not found; nothing to compare against (skipped)")
        return 0
    game = game_lines() - allowlist()
    files = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True).stdout.split()
    bad = 0
    for rel in files:
        if not rel.endswith(TEXT_EXT) or rel.startswith(("tools/check_game_code_overlap", "tools/game_overlap_allow")):
            continue
        with open(os.path.join(ROOT, rel), encoding="utf-8", errors="ignore") as fh:
            hits = [(i + 1, l.strip()) for i, l in enumerate(fh) if l.strip() in game]
        logic = [h for h in hits if not DECL.match(h[1])]
        decl = len(hits) - len(logic)
        if logic or decl > args.max_decl:
            bad += 1
            print(f"FAIL {rel}: {len(logic)} logic line(s), {decl} declaration(s)")
            for n, s in logic if args.verbose else logic[:3]:
                print(f"     {n}: {s[:110]}")
        elif hits and args.verbose:
            print(f"ok   {rel}: {decl} declaration(s)")
    print(f"{'FAILED' if bad else 'PASSED'}: {bad} file(s) over the limit")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
