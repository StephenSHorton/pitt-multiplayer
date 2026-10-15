#!/usr/bin/env python3
"""Checks PittAPI's game contract (loader/core/contract.gd) against decompiled
game sources, so a new game build can be diffed right after re-decompiling.

usage: python tools/contract_check.py [decomp_dir] [contract.gd ...]

Each contract entry is "feature|target|kind|member":
  target = autoload name (resolved through decomp/project.godot [autoload],
           including uid:// paths via the *.uid files) or a res:// script path.
  kind   = method | signal | prop | const
Members are looked up in the target script and its `extends "res://..."` chain.
An optional `const GREPS := [` list of "res://path|literal" entries (mod
contracts) requires each literal to appear verbatim in that decomp script, for
values a mod mirrors from lambda-local tables. Several contract files may be given.
Exit code 0 when every entry is found, 1 otherwise. Reads only; never writes.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_entries(contract_path):
    text = open(contract_path, encoding="utf-8").read()
    m = re.search(r"const ENTRIES := \[(.*?)\n\]", text, re.S)
    if not m:
        sys.exit("could not find 'const ENTRIES := [' in %s" % contract_path)
    return re.findall(r'"([^"|]+\|[^"|]+\|[^"|]+\|[^"|]+)"', m.group(1))


def load_greps(contract_path):
    """[(res_path, literal)] from an optional const GREPS := [...] (GDScript string escapes \\" and \\\\)."""
    text = open(contract_path, encoding="utf-8").read()
    m = re.search(r"const GREPS := \[(.*?)\n\]", text, re.S)
    if not m:
        return []
    out = []
    for raw in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1)):
        s = raw.replace('\\"', '"').replace("\\\\", "\\")
        if "|" in s:
            target, literal = s.split("|", 1)
            out.append((target, literal))
    return out


def uid_map(decomp):
    out = {}
    for dirpath, _dirs, files in os.walk(decomp):
        if ".godot" in dirpath or ".autoconverted" in dirpath:
            continue
        for f in files:
            if f.endswith(".uid"):
                p = os.path.join(dirpath, f)
                uid = open(p, encoding="utf-8", errors="replace").read().strip()
                rel = os.path.relpath(p[:-4], decomp).replace("\\", "/")
                out[uid] = "res://" + rel
    return out


def autoloads(decomp, uids):
    text = open(os.path.join(decomp, "project.godot"), encoding="utf-8").read()
    sec = re.search(r"\[autoload\](.*?)(\n\[|\Z)", text, re.S)
    out = {}
    if not sec:
        return out
    for name, val in re.findall(r'^(\w+)="\*?([^"]+)"', sec.group(1), re.M):
        out[name] = uids.get(val, val)
    return out


def res_to_file(decomp, res):
    return os.path.join(decomp, res[len("res://"):].replace("/", os.sep))


def script_chain(decomp, res, seen=None):
    """Yields (res_path, source) for a script and its extends-by-path bases."""
    seen = seen or set()
    while res and res not in seen:
        seen.add(res)
        path = res_to_file(decomp, res)
        if not os.path.exists(path):
            return
        src = open(path, encoding="utf-8", errors="replace").read()
        yield res, src
        m = re.search(r'^extends\s+"(res://[^"]+)"', src, re.M)
        res = m.group(1) if m else None


PATTERNS = {
    "method": r"^\s*(?:static\s+)?func\s+{name}\s*\(",
    "signal": r"^\s*signal\s+{name}\b",
    "prop": r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*var\s+{name}\b",
    "const": r"^\s*const\s+{name}\b",
}


def find(decomp, res, kind, member):
    pat = re.compile(PATTERNS[kind].format(name=re.escape(member)), re.M)
    for script, src in script_chain(decomp, res):
        m = pat.search(src)
        if m:
            line_no = src.count("\n", 0, m.start()) + 1
            line = src.splitlines()[line_no - 1].strip()
            return "%s:%d  %s" % (script, line_no, line[:110])
    return None



def check_one(decomp, contract, al, uids):
    entries = load_entries(contract)
    missing = []
    by_feature = {}
    for e in entries:
        feature, target, kind, member = e.split("|")
        res = target if target.startswith("res://") else al.get(target)
        where = None
        if res is None:
            why = "autoload %s not in project.godot" % target
        elif kind not in PATTERNS:
            why = "unknown kind %s" % kind
        else:
            where = find(decomp, res, kind, member)
            why = "not found in %s" % res
        by_feature.setdefault(feature, [0, 0])
        by_feature[feature][1] += 1
        if where:
            by_feature[feature][0] += 1
            if "-v" in sys.argv:
                print("  ok   %-12s %s.%s -> %s" % (feature, target, member, where))
        else:
            missing.append((feature, target, kind, member, why))
    greps = load_greps(contract)
    grep_missing = []
    for target, literal in greps:
        path = res_to_file(decomp, target)
        src = open(path, encoding="utf-8", errors="replace").read() if os.path.exists(path) else ""
        if literal not in src:
            grep_missing.append((target, literal))
        elif "-v" in sys.argv:
            print("  ok   grep %s: %s" % (target, literal))
    print("contract_check: %s: %d entries, %d features, %d greps, %d autoloads in project.godot" % (
        os.path.relpath(contract, ROOT), len(entries), len(by_feature), len(greps), len(al)))
    for f in sorted(by_feature):
        ok, total = by_feature[f]
        print("  %-15s %d/%d %s" % (f, ok, total, "OK" if ok == total else "MISSING -> feature disabled at runtime"))
    if missing or grep_missing:
        print("MISSING members:")
        for feature, target, kind, member, why in missing:
            print("  [%s] %s %s.%s: %s" % (feature, kind, target, member, why))
        for target, literal in grep_missing:
            print("  [grep] %s no longer contains: %s" % (target, literal))
        return 1
    print("contract_check: all members present")
    return 0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    decomp = args[0] if args else os.path.join(ROOT, "decomp")
    contracts = args[1:] or [os.path.join(ROOT, "loader", "core", "contract.gd")]
    if not os.path.isdir(os.path.join(decomp, "scripts")):
        print("contract_check: %s has no scripts/ (decompile the game first); skipping" % decomp)
        return 0
    uids = uid_map(decomp)
    al = autoloads(decomp, uids)
    rc = 0
    for c in contracts:
        rc |= check_one(decomp, c, al, uids)
    return rc


if __name__ == "__main__":
    sys.exit(main())
