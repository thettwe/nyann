#!/usr/bin/env python3
# _precommit-merge.py — merge nyann's pre-commit template into an existing
# user .pre-commit-config.yaml without overwriting their entries.
#
# Usage: _precommit-merge.py <dst-config> <template>
#
# Behaviour:
#   - Both files must parse as a YAML mapping with a `repos` list.
#   - Merge key: `repo` URL for remote entries; `('local', sorted(hook ids))`
#     for `repo: local` entries (so the same set of local hook IDs is
#     considered the same entry regardless of order).
#   - Existing entries win — nyann never edits them. Only entries whose
#     key isn't already present in dst are appended.
#   - If PyYAML is missing, exit 0 with a warning so the caller can fall
#     back to a copy-only path.
#
# Extracted from install-hooks.sh where the same block was inlined twice
# (Python phase + shared pre-commit installer for go/rust). Kept as a
# standalone script rather than a function in _lib.sh because the merger
# is Python — _lib.sh is bash.

import sys


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: _precommit-merge.py <dst-config> <template>\n")
        return 2

    try:
        import yaml
    except ImportError:
        sys.stderr.write("[nyann] PyYAML missing; skipping merge (template copy only)\n")
        return 0

    dst_path, tmpl_path = sys.argv[1], sys.argv[2]

    def load(p: str) -> dict:
        with open(p) as f:
            d = yaml.safe_load(f) or {}
        if not isinstance(d, dict):
            sys.stderr.write(
                f"[nyann] unexpected YAML shape in {p}: root is {type(d).__name__}\n"
            )
            sys.exit(1)
        # `repos: null` is legal YAML and parses to None — setdefault would
        # leave it as None and the iteration below would TypeError. Coerce
        # to [] explicitly. Same hazard if `repos` is a scalar/string.
        if not isinstance(d.get("repos"), list):
            d["repos"] = []
        return d

    dst = load(dst_path)
    tmpl = load(tmpl_path)

    def repo_key(r):
        # A list with a bare `- ` line in YAML produces None entries;
        # custom mappings that aren't dicts also slip through here. Treat
        # them as opaque and key on object identity so they're preserved
        # but never collide with our remote/local keys.
        if not isinstance(r, dict):
            return ("opaque", id(r))
        if r.get("repo") == "local":
            hooks = r.get("hooks") or []
            ids = tuple(
                sorted(
                    h.get("id")
                    for h in hooks
                    if isinstance(h, dict) and h.get("id")
                )
            )
            return ("local", ids)
        return ("remote", r.get("repo"))

    existing = {repo_key(r): r for r in dst["repos"]}
    added = 0
    for r in tmpl["repos"]:
        # Skip malformed template entries rather than aborting the whole
        # merge — the user's existing config is the source of truth and
        # should not be left half-merged on a template error.
        if not isinstance(r, dict):
            sys.stderr.write(
                "[nyann] template contains a non-mapping repo entry; skipping\n"
            )
            continue
        k = repo_key(r)
        if k in existing:
            continue
        dst["repos"].append(r)
        existing[k] = r
        added += 1

    if added:
        with open(dst_path, "w") as f:
            yaml.safe_dump(dst, f, sort_keys=False)
        print(f"[nyann] merged {added} nyann repo(s) into .pre-commit-config.yaml")
    else:
        print("[nyann] .pre-commit-config.yaml already has all nyann repos; no change")
    return 0


if __name__ == "__main__":
    sys.exit(main())
