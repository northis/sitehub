"""Merge the incremental backup archives of one folder into a single archive.

A restore needs the manual full backup plus every increment taken since it, so the chain
grows with each run. This folds all increments of one folder into one archive: the newest
copy of every file, the newest database, and the files that were deleted later
(soundsave keeps those in deleted.txt). The full backup is never touched:

    full backup  +  merged archive  +  increments taken after the merge

Run it per project, by hand or from a weekly task:

    python squash_backups.py C:\\0github\\duosave\\data\\backups\\incremental
    python squash_backups.py C:\\0github\\soundsave\\backup --delete

Sources are only deleted with --delete, and only after the merged archive passed a CRC
check. Both the local folders and the share (\\\\10.77.77.21\\backup\\<project>) work.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

CHUNK = 1024 * 1024
#: duosave writes this into every archive; it describes one archive, not a merge.
ARCHIVE_MANIFEST = "backup-manifest.json"
MERGED_MANIFEST = "merge-manifest.json"
DELETE_LIST = "deleted.txt"
NOT_CONTENT = {ARCHIVE_MANIFEST, MERGED_MANIFEST, DELETE_LIST}
#: Every project stamps YYYYMMDD and HHMMSS into the archive name.
STAMP = re.compile(r"(\d{8})[-_T]?(\d{6})")


def _stamp(path: Path) -> str:
    """Order by the name, not by mtime: a copy must not reorder the chain."""
    match = STAMP.search(path.name)
    if match:
        return "".join(match.groups())
    return datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y%m%d%H%M%S")


def archives_in(folder: Path) -> list[Path]:
    """Increment archives, oldest first. An earlier merged archive takes part like any other."""
    return sorted(
        (path for path in folder.glob("*.zip") if path.is_file()),
        key=lambda path: (_stamp(path), path.name),
    )


def collect(archives: list[Path]) -> tuple[dict[str, tuple[Path, zipfile.ZipInfo]], list[str]]:
    """Newest copy of every path, plus the paths deleted after their last copy."""
    newest: dict[str, tuple[Path, zipfile.ZipInfo]] = {}
    deleted: set[str] = set()
    for archive in archives:
        with zipfile.ZipFile(archive) as bundle:
            if DELETE_LIST in bundle.namelist():
                for name in bundle.read(DELETE_LIST).decode("utf-8").split():
                    deleted.add(name)
                    newest.pop(name, None)
            for info in bundle.infolist():
                if info.is_dir() or info.filename in NOT_CONTENT:
                    continue
                newest[info.filename] = (archive, info)
                deleted.discard(info.filename)
    return newest, sorted(deleted)


def write(target: Path, newest: dict[str, tuple[Path, zipfile.ZipInfo]], deleted: list[str],
          sources: list[Path]) -> None:
    """Copy the picked entries without recompressing them more than the source did."""
    grouped: dict[Path, list[tuple[str, zipfile.ZipInfo]]] = {}
    for name, (source, info) in sorted(newest.items()):
        grouped.setdefault(source, []).append((name, info))

    temporary = target.with_name(f".{target.name}.part")
    try:
        with zipfile.ZipFile(temporary, "w", allowZip64=True) as merged:
            for source, entries in grouped.items():
                with zipfile.ZipFile(source) as bundle:
                    for name, info in entries:
                        entry = zipfile.ZipInfo(name, date_time=info.date_time)
                        entry.compress_type = info.compress_type
                        with bundle.open(info) as reader, \
                                merged.open(entry, "w", force_zip64=True) as writer:
                            shutil.copyfileobj(reader, writer, CHUNK)
            if deleted:
                merged.writestr(DELETE_LIST, "\n".join(deleted) + "\n")
            merged.writestr(MERGED_MANIFEST, json.dumps({
                "format": "sitehub-merged-backup",
                "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "sources": [source.name for source in sources],
                "files": len(newest),
                "deleted": len(deleted),
            }, ensure_ascii=False, indent=2))
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def verify(target: Path) -> None:
    """Every entry has to pass its CRC before the sources may go."""
    with zipfile.ZipFile(target) as merged:
        broken = merged.testzip()
    if broken is not None:
        raise SystemExit(f"{target}: {broken} is corrupt, sources left in place")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("folder", type=Path, help="folder with the incremental *.zip archives")
    parser.add_argument("--delete", action="store_true",
                        help="delete the merged archives once the result verifies")
    args = parser.parse_args(argv)

    sources = archives_in(args.folder)
    if len(sources) < 2:
        print(f"{args.folder}: {len(sources)} archive(s), nothing to merge")
        return 0

    newest, deleted = collect(sources)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = args.folder / f"merged-{stamp}.zip"
    for index in range(2, 1000):
        if not target.exists():
            break
        target = args.folder / f"merged-{stamp}-{index}.zip"

    write(target, newest, deleted, sources)
    verify(target)
    print(f"{target}: {len(newest)} files, {len(deleted)} deleted, "
          f"{target.stat().st_size / CHUNK:.1f} MiB from {len(sources)} archives")

    if args.delete:
        for source in sources:
            if source != target:
                source.unlink()
        print(f"{args.folder}: {len(sources)} merged archives deleted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
