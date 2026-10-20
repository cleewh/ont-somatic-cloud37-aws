#!/usr/bin/env python3
"""Build the HealthOmics workflow ZIP that bootstrap.sh registers (cloud37-variant-rs3).

The workflow HealthOmics runs is ONT's wf-somatic-variation v1.5.1 plus the cloud-adapted
files in this directory. This script rebuilds it from the original sources:

  1. wf-somatic-variation v1.5.1, downloaded from ONT's GitHub
  2. its lib/ folder, from the wf-human-variation commit v1.5.1 pins as a git submodule
     (upstream ships lib/ as a symlink into that submodule)
  3. every workflow file in this directory, copied over the top (the "overlay")

It then checks the result against the workflow that was validated on HealthOmics
(cloud37-variant-rs3). Only python3 and access to github.com are needed.

Usage:
    python3 production/cloud-pipeline/build_workflow_zip.py [OUTPUT_ZIP]

Default output: cloud37-variant-workflow.zip in the current directory. Pass the path to
bootstrap.sh as its WORKFLOW_ZIP argument.

The ONT code is licensed under the Oxford Nanopore Technologies PLC. Public License v1.0
(see LICENSE in this directory), which permits use for research purposes only.
"""
import hashlib
import io
import os
import sys
import tarfile
import urllib.request
import zipfile

UPSTREAM_URL = "https://github.com/epi2me-labs/wf-somatic-variation/archive/refs/tags/v1.5.1.tar.gz"
SUBMODULE_COMMIT = "ffb4e89c94e517d03d7d07389c92bed1f8662123"
SUBMODULE_URL = f"https://github.com/epi2me-labs/wf-human-variation/archive/{SUBMODULE_COMMIT}.tar.gz"

# Upstream top-level entries that are repository plumbing, not part of the workflow.
SKIP_TOP = {".github", ".gitignore", ".gitlab-ci.yml", ".gitmodules",
            ".pre-commit-config.yaml", "wf-human-variation", "lib"}
# Files in this directory that are not workflow code.
NOT_OVERLAY = {"build_workflow_zip.py", "LICENSE", "README.md"}

# Content digest of the cloud37-variant-rs3 definition validated on HealthOmics
# (sha256 over sorted "path\0sha256(file)\n" lines; independent of ZIP metadata).
VALIDATED_RS3_DIGEST = "b9ea55cd215f0f8ebd13fe955bbb6d4f9ee60cb102c1c534596f1ee1abe32da0"


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def tar_files(blob):
    """Yield (path below the archive's root folder, bytes, executable) for regular files."""
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for m in tar.getmembers():
            if not m.isfile():
                continue
            rel = m.name.split("/", 1)[1] if "/" in m.name else m.name
            yield rel, tar.extractfile(m).read(), bool(m.mode & 0o111)


def content_digest(files):
    h = hashlib.sha256()
    for path in sorted(files):
        h.update(path.encode() + b"\0" + hashlib.sha256(files[path][0]).hexdigest().encode() + b"\n")
    return h.hexdigest()


def main():
    out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "cloud37-variant-workflow.zip")
    here = os.path.dirname(os.path.abspath(__file__))
    files = {}  # path -> (bytes, executable)

    print(f"downloading {UPSTREAM_URL}")
    for rel, data, ex in tar_files(fetch(UPSTREAM_URL)):
        if rel.split("/", 1)[0] not in SKIP_TOP:
            files[rel] = (data, ex)

    print(f"downloading {SUBMODULE_URL}")
    for rel, data, ex in tar_files(fetch(SUBMODULE_URL)):
        if rel.startswith("lib/"):
            files[rel] = (data, ex)

    overlay = []
    for root, dirs, names in os.walk(here):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d != "__pycache__")
        for name in sorted(names):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, here).replace(os.sep, "/")
            if name.startswith(".") or rel in NOT_OVERLAY:
                continue
            with open(path, "rb") as f:
                files[rel] = (f.read(), bool(os.stat(path).st_mode & 0o111))
            overlay.append(rel)
    print(f"overlay ({len(overlay)} files): " + ", ".join(overlay))

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in sorted(files):
            data, ex = files[rel]
            info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3  # Unix, so the permission bits below are honoured
            info.external_attr = (0o100755 if ex else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)

    digest = content_digest(files)
    print(f"wrote {out} ({len(files)} files)")
    if digest == VALIDATED_RS3_DIGEST:
        print("content matches the validated HealthOmics workflow (cloud37-variant-rs3)")
    else:
        print("WARNING: content differs from the validated cloud37-variant-rs3 workflow "
              f"(digest {digest}); expected if you changed files in {here}")


if __name__ == "__main__":
    main()
