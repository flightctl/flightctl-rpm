#!/usr/bin/env python3
"""
Creates payload-stripped stub RPMs under rpm-stubs/ for a new release and
records the real sha256, size, and GitHub Release href in rpm-manifest.json.

rpm-stubs/ mirrors the arch directory structure but is excluded from GitHub
Pages via .jekyllignore. regenerate-rpm-repo.py reads all stubs and manifests
to regenerate repodata from scratch via createrepo_c.

Usage:
  ./hack/add-release-stubs.py --rpms-dir .output/copr-rpms-temp --release-tag v1.2.0-rc1
"""

import argparse
import hashlib
import json
import urllib.request
import rpm as librpm
from pathlib import Path

GITHUB_RELEASES_BASE = "https://github.com/flightctl/flightctl-rpm/releases/download"

CHROOT_TO_REPO = {
    "epel-9-x86_64":     "epel/9/x86_64",
    "epel-9-aarch64":    "epel/9/aarch64",
    "epel-10-x86_64":    "epel/10/x86_64",
    "epel-10-aarch64":   "epel/10/aarch64",
    "fedora-41-x86_64":  "fedora/41/x86_64",
    "fedora-41-aarch64": "fedora/41/aarch64",
    "fedora-42-x86_64":  "fedora/42/x86_64",
    "fedora-42-aarch64": "fedora/42/aarch64",
    "fedora-43-x86_64":  "fedora/43/x86_64",
    "fedora-43-aarch64": "fedora/43/aarch64",
}

MANIFEST_FILE = "rpm-manifest.json"

_rpm_ts = librpm.TransactionSet()
_rpm_ts.setVSFlags(
    librpm._RPMVSF_NOSIGNATURES | librpm._RPMVSF_NODIGESTS | librpm.RPMVSF_NOHDRCHK
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def create_stub(rpm_path: Path, stub_path: Path) -> None:
    """Write a payload-stripped RPM containing only lead + headers."""
    with open(rpm_path, "rb") as f:
        _rpm_ts.hdrFromFdno(f)
        payload_offset = f.tell()
    stub_path.write_bytes(rpm_path.read_bytes()[:payload_offset])


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rpms-dir", type=Path, required=True, metavar="DIR",
                        help="COPR download directory containing chroot subdirectories")
    parser.add_argument("--release-tag", required=True, metavar="TAG",
                        help="GitHub release tag (e.g. v1.2.0 or v1.2.0-rc1)")
    parser.add_argument("--repo-root", type=Path,
                        default=Path(__file__).parent.parent)
    args = parser.parse_args()

    stubs_root = args.repo_root / "rpm-stubs"

    for chroot_dir in sorted(args.rpms_dir.iterdir()):
        if not chroot_dir.is_dir():
            continue

        chroot = chroot_dir.name
        repo_subpath = CHROOT_TO_REPO.get(chroot)
        if not repo_subpath:
            print(f"[WARN] Unknown chroot '{chroot}', skipping.")
            continue

        rpms = sorted(chroot_dir.glob("*.rpm"))
        if not rpms:
            continue

        stubs_dir = stubs_root / repo_subpath
        stubs_dir.mkdir(parents=True, exist_ok=True)

        print(f"\n{chroot} -> rpm-stubs/{repo_subpath} ({len(rpms)} RPMs)")

        manifest_path = stubs_dir / MANIFEST_FILE
        manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}

        for rpm in rpms:
            sha256 = sha256_file(rpm)
            size = rpm.stat().st_size
            # GitHub converts ~ to . in release asset filenames
            gh_filename = rpm.name.replace("~", ".")
            href = f"{GITHUB_RELEASES_BASE}/{args.release_tag}/{gh_filename}"

            stub_path = stubs_dir / rpm.name
            create_stub(rpm, stub_path)
            print(f"  stub {rpm.name} ({stub_path.stat().st_size:,} B, was {size:,} B)")

            manifest[rpm.name] = {"sha256": sha256, "size": size, "href": href}

        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"  Updated manifest ({len(manifest)} total entries).")

    # Noarch packages (e.g. flightctl-selinux) appear in multiple COPR chroot
    # directories with slightly different builds. The upload step deduplicates
    # by filename, so the asset on the release may differ from the local copy
    # we just hashed. Download each asset and correct any mismatches.
    print("\nVerifying manifests against GitHub Release assets...")
    verified = 0
    fixed = 0
    seen_urls = {}

    for manifest_path in sorted(stubs_root.rglob(MANIFEST_FILE)):
        manifest = json.loads(manifest_path.read_text())
        changed = False

        for filename, entry in sorted(manifest.items()):
            # Only verify entries from this release
            if not entry["href"].startswith(f"{GITHUB_RELEASES_BASE}/{args.release_tag}/"):
                continue

            href = entry["href"]
            if href in seen_urls:
                actual_sha, actual_size = seen_urls[href]
            else:
                with urllib.request.urlopen(href, timeout=60) as resp:
                    data = resp.read()
                actual_sha = hashlib.sha256(data).hexdigest()
                actual_size = len(data)
                seen_urls[href] = (actual_sha, actual_size)

            if entry["sha256"] != actual_sha or entry["size"] != actual_size:
                entry["sha256"] = actual_sha
                entry["size"] = actual_size
                changed = True
                fixed += 1
            verified += 1

        if changed:
            manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    print(f"  Verified {verified} entries, fixed {fixed} mismatches.")
    print("\nDone. Run regenerate-rpm-repo.py to rebuild repodata.")


if __name__ == "__main__":
    main()
