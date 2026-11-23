#!/usr/bin/env python3
"""Compare an official CalculiX ccx source release tarball with a git ref.

The official tarball (e.g. ccx_2.24.src.tar.bz2 from dhondt.de) is not a plain
export of the GitHub repository. Release packaging changes a few things in
otherwise identical files:

  * copyright years in every header ("1998-2015" -> "1998-2026")
  * the version string ("Version DEVELOPMENT" -> "Version 2.24")
  * CalculiX.c / CalculiX.h / CalculiXstep.c are renamed ccx_<ver>*.{c,h}

This script normalises exactly those differences and compares every .c/.f/.h
source file. Against the matching upstream commit it reports 0 differences;
against a fork it lists the files the fork added or modified.

Usage:
  python3 tools/verify_upstream_release.py ccx_2.24.src.tar.bz2 --ref ccx-2.24-upstream --expect-identical
  python3 tools/verify_upstream_release.py ccx_2.24.src.tar.bz2 --ref HEAD
  python3 tools/verify_upstream_release.py ccx_2.24.src.tar.bz2 --worktree
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tarfile

SRC_RE = re.compile(r"\.(c|f|h)$")


def normalise(data: bytes, version: str) -> str:
    data = data.replace(b"\r\n", b"\n")
    data = re.sub(rb"1998-20\d\d", b"1998-YYYY", data)
    for v in (b"DEVELOPMENT", version.encode()):
        data = data.replace(b"Version " + v, b"Version <VER>")
    data = data.replace(b"ccx_" + version.encode(), b"CalculiX")
    return hashlib.sha1(data).hexdigest()


def tarball_sources(path: str):
    """Return ({'src/<name>': hash}, version) for the tarball."""
    out, version, raw = {}, None, {}
    with tarfile.open(path) as tar:
        for m in tar.getmembers():
            if not m.isfile():
                continue
            parts = m.name.split("/")
            if len(parts) < 2 or parts[-2] != "src" or not SRC_RE.search(parts[-1]):
                continue
            mv = re.match(r"ccx_(\d+\.\d+)", parts[-3] if len(parts) >= 3 else "")
            if mv:
                version = mv.group(1)
            raw[parts[-1]] = tar.extractfile(m).read()
    if version is None:
        sys.exit("could not determine the release version from the tarball layout")
    ren = {f"ccx_{version}.c": "CalculiX.c", f"ccx_{version}.h": "CalculiX.h",
           f"ccx_{version}step.c": "CalculiXstep.c"}
    for name, data in raw.items():
        out["src/" + ren.get(name, name)] = normalise(data, version)
    return out, version


def git_sources(ref: str, version: str):
    listing = subprocess.check_output(["git", "ls-tree", "-r", ref, "--", "src"], text=True)
    entries = []
    for line in listing.splitlines():
        meta, path = line.split("\t", 1)
        if path.count("/") == 1 and SRC_RE.search(path):
            entries.append((meta.split()[2], path))
    proc = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE)
    out = {}
    for blob, path in entries:
        proc.stdin.write(blob.encode() + b"\n")
        proc.stdin.flush()
        size = int(proc.stdout.readline().split()[2])
        data = proc.stdout.read(size)
        proc.stdout.read(1)
        out[path] = normalise(data, version)
    proc.stdin.close()
    proc.wait()
    return out


def worktree_sources(version: str):
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    tracked = subprocess.check_output(["git", "-C", root, "ls-files", "src"], text=True).split()
    out = {}
    for path in tracked:
        full = os.path.join(root, path)
        if path.count("/") == 1 and SRC_RE.search(path) and os.path.isfile(full):
            with open(full, "rb") as fh:
                out[path] = normalise(fh.read(), version)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("tarball", help="official ccx_<ver>.src.tar.bz2")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--ref", default="HEAD", help="git ref to compare (default: HEAD)")
    g.add_argument("--worktree", action="store_true", help="compare the working tree instead of a ref")
    ap.add_argument("--expect-identical", action="store_true",
                    help="exit 1 if any source file differs")
    args = ap.parse_args()

    with open(args.tarball, "rb") as fh:
        sha = hashlib.sha256(fh.read()).hexdigest()
    tar, version = tarball_sources(args.tarball)
    ours = worktree_sources(version) if args.worktree else git_sources(args.ref, version)
    target = "working tree" if args.worktree else args.ref

    modified = sorted(k for k in tar.keys() & ours.keys() if tar[k] != ours[k])
    added = sorted(ours.keys() - tar.keys())
    removed = sorted(tar.keys() - ours.keys())

    print(f"Release : ccx {version}  ({os.path.basename(args.tarball)})")
    print(f"SHA-256 : {sha}")
    print(f"Compared: {target}")
    print(f"Sources : {len(tar)} in tarball, {len(ours)} in {target}")
    print(f"Identical: {len(tar.keys() & ours.keys()) - len(modified)}")
    for title, items in (("Modified", modified), ("Added", added), ("Missing (in tarball only)", removed)):
        print(f"\n{title}: {len(items)}")
        for p in items:
            print(f"  {p}")

    if args.expect_identical and (modified or added or removed):
        sys.exit(1)


if __name__ == "__main__":
    main()
