#!/usr/bin/env python3
"""Validates every mod.json against loader/schema/mod.schema.json.

usage: python tools/validate_manifests.py <schema.json> <dir> [<dir> ...]
Each <dir> is either a mod folder (has mod.json) or a folder of mod folders.
Uses the jsonschema package when installed, otherwise a minimal built-in check
of the same rules. Exit 0 when all are valid.
"""
import json
import os
import re
import sys


def minimal_validate(schema, data):
    errors = []
    if not isinstance(data, dict):
        return ["manifest must be an object"]
    for k in schema.get("required", []):
        if k not in data:
            errors.append("missing required field %r" % k)
    props = schema.get("properties", {})
    types = {"string": str, "integer": int, "boolean": bool, "object": dict, "array": list}
    for k, v in data.items():
        spec = props.get(k)
        if not spec:
            continue
        t = spec.get("type")
        if t and not isinstance(v, types[t]) or (t == "integer" and isinstance(v, bool)):
            errors.append("%s must be %s" % (k, t))
            continue
        if "pattern" in spec and isinstance(v, str) and not re.search(spec["pattern"], v):
            errors.append("%s=%r does not match %s" % (k, v, spec["pattern"]))
        if "enum" in spec and v not in spec["enum"]:
            errors.append("%s=%r not in %s" % (k, v, spec["enum"]))
        if t == "array" and "items" in spec:
            for item in v:
                ip = spec["items"].get("pattern")
                if not isinstance(item, str) or (ip and not re.search(ip, item)):
                    errors.append("%s item %r invalid" % (k, item))
        if t == "object" and "additionalProperties" in spec and isinstance(spec["additionalProperties"], dict):
            for dk, dv in v.items():
                pn = spec.get("propertyNames", {}).get("pattern")
                if pn and not re.search(pn, dk):
                    errors.append("%s key %r invalid" % (k, dk))
                if not isinstance(dv, str):
                    errors.append("%s[%r] must be a string" % (k, dk))
    return errors


def manifests(dirs):
    for d in dirs:
        if os.path.exists(os.path.join(d, "mod.json")):
            yield os.path.join(d, "mod.json")
            continue
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name, "mod.json")
            if os.path.exists(p):
                yield p


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    schema = json.load(open(sys.argv[1], encoding="utf-8"))
    try:
        import jsonschema  # type: ignore
        validator = jsonschema.Draft202012Validator(schema)
        check = lambda data: [e.message for e in validator.iter_errors(data)]
        engine = "jsonschema"
    except ImportError:
        check = lambda data: minimal_validate(schema, data)
        engine = "built-in"
    bad = 0
    n = 0
    for path in manifests(sys.argv[2:]):
        n += 1
        try:
            data = json.load(open(path, encoding="utf-8"))
        except ValueError as e:
            print("  FAIL %s: invalid JSON: %s" % (path, e))
            bad += 1
            continue
        errs = check(data)
        folder = os.path.basename(os.path.dirname(path))
        if isinstance(data, dict) and data.get("id") not in (folder, None) and folder != "loader":
            errs.append("id %r must equal folder name %r" % (data.get("id"), folder))
        if errs:
            bad += 1
            print("  FAIL %s: %s" % (path, "; ".join(errs)))
        else:
            print("  ok   %s" % path)
    print("validate_manifests (%s): %d manifest(s), %d invalid" % (engine, n, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
