#!/usr/bin/env python3
"""Plan incremental Project Gutenberg mirror refreshes.

The mirror has two jobs beyond the first full copy:

1. Pick up new catalog IDs.
2. Pick up upstream revisions to books that were already mirrored.

A full rsync every night would re-list and re-compare the entire corpus. This
planner instead consumes a read-only ``rsync --list-only`` snapshot of the
upstream EPUB/cover files, compares it with the previous snapshot, and emits a
queue containing:

* newly catalogued IDs that have not been uploaded yet,
* IDs whose upstream file size or modification time changed,
* a small rotating slice of already-mirrored IDs (defence in depth against an
  upstream revision that preserves both size and mtime).

The shell script commits the pending snapshot/cursor only after every queued
book has uploaded successfully. A crash therefore re-plans the same work
instead of silently losing a revision.
"""

from __future__ import annotations

import argparse
import bisect
import os
import re
import sys
from pathlib import Path

# Example (rsync --list-only without -h):
# -rw-r--r--          2,942,05 2026/11/20 22:08:43 84/pg84.epub
LISTING_LINE = re.compile(
    r"^[-dl][rwxStTs-]{9}\s+([0-9,]+)\s+(\d{4}/\d{2}/\d{2})\s+"
    r"(\d{2}:\d{2}:\d{2})\s+(.+?)\s*$"
)
EPUB_NAME = re.compile(r"^(?P<id>\d+)/pg(?P=id)\.epub$")
COVER_NAME = re.compile(r"^(?P<id>\d+)/pg(?P=id)\.cover\.medium\.jpg$")
ILLUSTRATED_NAME = re.compile(r"^(?P<id>\d+)/pg(?P=id)-images(?:-\d+)?\.epub$")


def read_ids(path: Path) -> set[int]:
    if not path.is_file():
        return set()
    ids: set[int] = set()
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            value = line.strip()
            if value.isdigit():
                ids.add(int(value))
    return ids


def classify(path: str) -> tuple[int, str] | None:
    path = path.removeprefix("./")
    for kind, pattern in (
        ("epub", EPUB_NAME),
        ("cover", COVER_NAME),
        ("illustrated", ILLUSTRATED_NAME),
    ):
        match = pattern.match(path)
        if match:
            return int(match.group("id")), kind
    return None


def parse_listing(lines: list[str]) -> dict[tuple[int, str], tuple[str, str]]:
    snapshot: dict[tuple[int, str], tuple[str, str]] = {}
    for line in lines:
        match = LISTING_LINE.match(line.rstrip("\r\n"))
        if not match:
            continue
        size, date, clock, path = match.groups()
        classified = classify(path)
        if classified is None:
            continue
        snapshot[classified] = (size.replace(",", ""), f"{date} {clock}")
    return snapshot


def read_snapshot(path: Path) -> dict[tuple[int, str], tuple[str, str]]:
    if not path.is_file():
        return {}
    snapshot: dict[tuple[int, str], tuple[str, str]] = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t", 3)
            if len(parts) != 4 or not parts[0].isdigit():
                continue
            snapshot[(int(parts[0]), parts[1])] = (parts[2], parts[3])
    return snapshot


def group_by_id(
    snapshot: dict[tuple[int, str], tuple[str, str]],
) -> dict[int, dict[str, tuple[str, str]]]:
    grouped: dict[int, dict[str, tuple[str, str]]] = {}
    for (book_id, kind), value in snapshot.items():
        grouped.setdefault(book_id, {})[kind] = value
    return grouped


def changed_ids(
    previous: dict[tuple[int, str], tuple[str, str]],
    current: dict[tuple[int, str], tuple[str, str]],
) -> set[int]:
    if not previous:
        # First snapshot is the baseline. Re-downloading the whole corpus to
        # establish it would defeat incremental sync; the rotating refresh and
        # --refresh-all cover the migration case explicitly.
        return set()
    old = group_by_id(previous)
    new = group_by_id(current)
    return {book_id for book_id, signature in new.items() if old.get(book_id) != signature}


def removed_ids(
    previous: dict[tuple[int, str], tuple[str, str]],
    current: dict[tuple[int, str], tuple[str, str]],
) -> set[int]:
    if not previous:
        return set()
    return set(group_by_id(previous)) - set(group_by_id(current))


def rotating_refresh(ids: list[int], cursor: int, count: int) -> tuple[list[int], int]:
    if count <= 0 or not ids:
        return [], cursor
    start = bisect.bisect_right(ids, cursor)
    rotated = ids[start:] + ids[:start]
    selected = rotated[:count]
    return selected, selected[-1] if selected else cursor


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def write_snapshot(path: Path, snapshot: dict[tuple[int, str], tuple[str, str]]) -> None:
    lines = [
        f"{book_id}\t{kind}\t{size}\t{mtime}\n"
        for (book_id, kind), (size, mtime) in sorted(snapshot.items())
    ]
    atomic_write(path, "".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rsync-listing", required=True, type=Path,
                        help="raw `rsync --list-only -r` output")
    parser.add_argument("--snapshot-out", required=True, type=Path,
                        help="pending normalized upstream snapshot")
    parser.add_argument("--previous-snapshot", type=Path,
                        help="last committed normalized snapshot")
    parser.add_argument("--all-ids", required=True, type=Path,
                        help="catalog Text IDs, one per line")
    parser.add_argument("--uploaded-ids", type=Path,
                        help="IDs already uploaded, one per line")
    parser.add_argument("--cursor-file", type=Path,
                        help="last ID visited by the rotating refresh")
    parser.add_argument("--cursor-out", type=Path,
                        help="pending rotating-refresh cursor")
    parser.add_argument("--refresh-batch-size", type=int, default=0,
                        help="already-mirrored IDs to re-fetch this cycle")
    parser.add_argument("--refresh-all", action="store_true",
                        help="queue every catalog ID once (migration/audit)")
    parser.add_argument("--queue", required=True, type=Path,
                        help="IDs to rsync/upload this cycle")
    parser.add_argument("--removed-out", type=Path,
                        help="IDs present in the previous snapshot but absent now")
    args = parser.parse_args()

    if args.refresh_batch_size < 0:
        parser.error("--refresh-batch-size must be non-negative")

    current = parse_listing(
        args.rsync_listing.read_text(encoding="utf-8", errors="replace").splitlines()
    )
    previous = read_snapshot(args.previous_snapshot) if args.previous_snapshot else {}
    catalog_ids = read_ids(args.all_ids)
    uploaded_ids = read_ids(args.uploaded_ids) if args.uploaded_ids else set()

    current_ids = set(group_by_id(current))
    catalog_current = sorted(catalog_ids & current_ids)

    new_ids = catalog_ids - uploaded_ids
    changed = changed_ids(previous, current) & catalog_ids
    removed = removed_ids(previous, current) & catalog_ids

    cursor = 0
    if args.cursor_file and args.cursor_file.is_file():
        raw_cursor = args.cursor_file.read_text(encoding="utf-8").strip()
        if raw_cursor.isdigit():
            cursor = int(raw_cursor)

    if args.refresh_all:
        refresh = catalog_current
        cursor_out = refresh[-1] if refresh else cursor
    else:
        refresh, cursor_out = rotating_refresh(
            catalog_current, cursor, args.refresh_batch_size
        )

    queue = sorted(new_ids | changed | set(refresh))
    atomic_write(args.queue, "".join(f"{book_id}\n" for book_id in queue))
    write_snapshot(args.snapshot_out, current)
    if args.cursor_out:
        atomic_write(args.cursor_out, f"{cursor_out}\n")
    if args.removed_out:
        atomic_write(
            args.removed_out,
            "".join(f"{book_id}\n" for book_id in sorted(removed)),
        )

    print(
        f"refresh plan: new={len(new_ids)} changed={len(changed)} "
        f"refresh={len(refresh)} removed={len(removed)} queue={len(queue)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
