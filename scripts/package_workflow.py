#!/usr/bin/env python3
"""Package the /tmp/wf-inspect workflow tree into a HealthOmics ZIP.
Follows symlinks (materialize lib/), excludes VCS/junk/nested zips."""
import os, sys, zipfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wf-cloud15.zip"
SRC = sys.argv[2] if len(sys.argv) > 2 else "/tmp/wf-inspect"

EXCLUDE_DIRS = {".git", ".github", "wf-human-variation"}
EXCLUDE_EXT = {".zip", ".bak", ".pyc"}
EXCLUDE_NAMES = {".gitignore", ".gitlab-ci.yml", ".gitmodules",
                 ".pre-commit-config.yaml", ".DS_Store"}

count = 0
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(SRC, followlinks=True):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for fn in files:
            if fn in EXCLUDE_NAMES:
                continue
            if os.path.splitext(fn)[1] in EXCLUDE_EXT:
                continue
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, SRC)
            # skip 0-byte stray files at top level
            try:
                if os.path.getsize(full) == 0 and os.path.dirname(rel) == "":
                    continue
            except OSError:
                continue
            z.write(full, rel)
            count += 1
print(f"wrote {OUT} with {count} entries")
