#!/usr/bin/env python3
"""
Regenerates repodata for all arch directories from stubs in rpm-stubs/.

For each arch (e.g. epel/9/x86_64):
  1. Run createrepo_c on rpm-stubs/{arch}/ to produce fresh metadata.
  2. Post-process primary.xml: apply correct sha256, size, and href from
     rpm-manifest.json (createrepo_c computes these from stubs and gets them wrong).
  3. Write the corrected repodata into {arch}/repodata/, replacing old files.

Can be run at any time — it always produces a fully consistent repodata from
whatever stubs and manifests are currently in rpm-stubs/.

Usage:
  ./hack/regenerate-rpm-repo.py
"""

import argparse
import gzip
import hashlib
import json
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

PRIMARY_NS = "http://linux.duke.edu/metadata/common"
REPOMD_NS = "http://linux.duke.edu/metadata/repo"
RPM_NS = "http://linux.duke.edu/metadata/rpm"

ET.register_namespace("", PRIMARY_NS)
ET.register_namespace("rpm", RPM_NS)

MANIFEST_FILE = "rpm-manifest.json"
STUBS_ROOT = "rpm-stubs"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def sha256_gz_content(path: Path) -> str:
    h = hashlib.sha256()
    with gzip.open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def find_stubs_dirs(repo_root: Path) -> list[tuple[Path, Path]]:
    """Return (stubs_dir, arch_dir) pairs for each arch that has stubs."""
    stubs_root = repo_root / STUBS_ROOT
    if not stubs_root.exists():
        return []

    pairs = []
    for stubs_dir in sorted(stubs_root.rglob("*")):
        if not stubs_dir.is_dir():
            continue
        if not any(stubs_dir.glob("*.rpm")):
            continue
        rel = stubs_dir.relative_to(stubs_root)
        arch_dir = repo_root / rel
        if not (arch_dir / "repodata").exists():
            print(f"[WARN] No repodata dir for {rel}, skipping.")
            continue
        pairs.append((stubs_dir, arch_dir))
    return pairs


def save_primary_xml(tree: ET.ElementTree, repodata_dir: Path) -> tuple[Path, int]:
    tmp_xml = repodata_dir / "_primary.xml.tmp"
    tree.write(str(tmp_xml), xml_declaration=True, encoding="UTF-8")

    # Strip the ns0: prefix that Python's ElementTree adds; libdnf (RHEL 9) requires
    # the default namespace form that createrepo_c generates.
    content = tmp_xml.read_text(encoding="UTF-8")
    content = content.replace('xmlns:ns0="http://linux.duke.edu/metadata/common"',
                              'xmlns="http://linux.duke.edu/metadata/common"')
    content = content.replace("<ns0:", "<").replace("</ns0:", "</")
    tmp_xml.write_text(content, encoding="UTF-8")

    xml_size = tmp_xml.stat().st_size

    tmp_gz = repodata_dir / "_primary.xml.gz.tmp"
    with open(tmp_xml, "rb") as f_in, gzip.open(tmp_gz, "wb") as f_out:
        f_out.write(f_in.read())
    tmp_xml.unlink()

    final_gz = repodata_dir / f"{sha256_file(tmp_gz)}-primary.xml.gz"
    shutil.move(tmp_gz, final_gz)
    return final_gz, xml_size


def update_repomd_primary(repodata_dir: Path, primary_gz: Path, xml_size: int):
    ET.register_namespace("", REPOMD_NS)
    repomd_path = repodata_dir / "repomd.xml"
    repomd = ET.parse(repomd_path)
    root = repomd.getroot()
    ts = str(int(datetime.now().timestamp()))

    rev = root.find(f"{{{REPOMD_NS}}}revision")
    if rev is not None:
        rev.text = ts

    for data in root.findall(f"{{{REPOMD_NS}}}data"):
        if data.get("type") != "primary":
            continue
        data.find(f"{{{REPOMD_NS}}}checksum").text = sha256_file(primary_gz)
        data.find(f"{{{REPOMD_NS}}}open-checksum").text = sha256_gz_content(primary_gz)
        data.find(f"{{{REPOMD_NS}}}location").set("href", f"repodata/{primary_gz.name}")
        data.find(f"{{{REPOMD_NS}}}timestamp").text = ts
        data.find(f"{{{REPOMD_NS}}}size").text = str(primary_gz.stat().st_size)
        data.find(f"{{{REPOMD_NS}}}open-size").text = str(xml_size)
        break

    repomd.write(str(repomd_path), xml_declaration=True, encoding="UTF-8")


def process(stubs_dir: Path, arch_dir: Path, repo_root: Path):
    rel = arch_dir.relative_to(repo_root)
    stubs = sorted(stubs_dir.glob("*.rpm"))

    manifest_path = stubs_dir / MANIFEST_FILE
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}

    print(f"\n{rel} ({len(stubs)} stubs, {len(manifest)} manifest entries)")

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)

        for stub in stubs:
            (tmp_path / stub.name).symlink_to(stub.resolve())

        subprocess.run(
            ["createrepo_c", "--quiet", "--general-compress-type", "gz", str(tmp_path)],
            check=True,
        )

        tmp_repodata = tmp_path / "repodata"

        # Post-process primary.xml: fix the three fields createrepo_c got wrong from stubs
        tmp_primary_gz = next(tmp_repodata.glob("*-primary.xml.gz"))
        with gzip.open(tmp_primary_gz, "rb") as f:
            root = ET.parse(f).getroot()

        overridden = 0
        for pkg in root.findall(f"{{{PRIMARY_NS}}}package"):
            loc = pkg.find(f"{{{PRIMARY_NS}}}location")
            filename = Path(loc.get("href")).name
            entry = manifest.get(filename)
            if entry is None:
                continue
            loc.set("href", entry["href"])
            pkg.find(f"{{{PRIMARY_NS}}}checksum").text = entry["sha256"]
            pkg.find(f"{{{PRIMARY_NS}}}size").set("package", str(entry["size"]))
            overridden += 1

        print(f"  Overrode {overridden}/{root.get('packages')} package(s) from manifest.")

        # Replace the createrepo_c-generated primary.xml.gz with our corrected version
        tmp_primary_gz.unlink()
        corrected_gz, xml_size = save_primary_xml(ET.ElementTree(root), tmp_repodata)
        update_repomd_primary(tmp_repodata, corrected_gz, xml_size)

        # Atomically replace arch repodata with the freshly generated set
        repodata_dir = arch_dir / "repodata"
        repodata_dir.mkdir(exist_ok=True)
        for old_file in repodata_dir.iterdir():
            old_file.unlink()
        for new_file in tmp_repodata.iterdir():
            shutil.copy2(new_file, repodata_dir / new_file.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", type=Path,
                        default=Path(__file__).parent.parent)
    args = parser.parse_args()

    pairs = find_stubs_dirs(args.repo_root)
    if not pairs:
        print(f"No stubs found under {args.repo_root / STUBS_ROOT}.")
        return

    print(f"Found {len(pairs)} arch directories to process.")

    for stubs_dir, arch_dir in pairs:
        process(stubs_dir, arch_dir, args.repo_root)

    print("\nDone.")


if __name__ == "__main__":
    main()
