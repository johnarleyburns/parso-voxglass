#!/usr/bin/env python3
"""Build the compact on-device Gutenberg catalog index from pg_catalog.csv.

The mirror keeps the CSV and this derived index under gutenberg/catalog/.
The iOS app downloads manifest.json, compares the sha256, then downloads the
versioned .json.gz. Paths are relative to the public mirror root so the app can
prefix them with its configured base URL.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import zlib
import hashlib
import json
import re
import sys
from pathlib import Path

SCHEMA_VERSION = 1
LANGUAGE_SPLIT = re.compile(r"[;,/]")


def split_field(value: str | None) -> list[str]:
    return [part.strip() for part in (value or "").split(";") if part.strip()]


def languages(value: str | None) -> list[str]:
    return [part.strip() for part in LANGUAGE_SPLIT.split(value or "") if part.strip()]


def build_records(catalog: Path, language: str | None) -> list[dict]:
    records: list[dict] = []
    with catalog.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("Type") != "Text":
                continue
            raw_id = (row.get("Text#") or "").strip()
            if not raw_id.isdigit():
                continue
            langs = languages(row.get("Language"))
            if language and language not in langs:
                continue
            book_id = int(raw_id)
            title = (row.get("Title") or "").strip()
            if not title:
                continue
            records.append(
                {
                    "id": book_id,
                    "title": title,
                    "authors": split_field(row.get("Authors")),
                    "languages": langs,
                    "subjects": split_field(row.get("Subjects")),
                    "bookshelves": split_field(row.get("Bookshelves")),
                    "issued": (row.get("Issued") or "").strip(),
                    "epub": f"books/{book_id}/pg{book_id}.epub",
                    "cover": f"books/{book_id}/pg{book_id}.cover.medium.jpg",
                }
            )
    records.sort(key=lambda record: record["id"])
    return records


def atomic_write_bytes(path: Path, payload: bytes) -> None:
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_bytes(payload)
    os.replace(temporary, path)


def write_index(records: list[dict], output_dir: Path) -> tuple[Path, Path, str, int]:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_at = (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    payload = {
        "schema": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "books": records,
    }
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    compressed = zlib.compress(raw, level=9)
    digest = hashlib.sha256(compressed).hexdigest()
    index_name = f"index-{digest[:16]}.json.zlib"
    index_path = output_dir / index_name

    manifest = {
        "schema": SCHEMA_VERSION,
        "version": generated_at,
        "index": index_name,
        "sha256": digest,
        "bytes": len(compressed),
        "bookCount": len(records),
    }
    manifest_path = output_dir / "manifest.json"

    # Publish the immutable, content-addressed index before the manifest that
    # points at it. The shell uploader preserves this order remotely too.
    atomic_write_bytes(index_path, compressed)
    atomic_write_bytes(
        manifest_path,
        (json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
    )
    for stale in output_dir.glob("index-*.json.zlib"):
        if stale != index_path:
            stale.unlink(missing_ok=True)
    return index_path, manifest_path, digest, len(compressed)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=Path, help="pg_catalog.csv")
    parser.add_argument("--output-dir", required=True, type=Path, help="where to write index + manifest")
    parser.add_argument(
        "--language",
        default=None,
        help="optional language code to include (default: every language)",
    )
    parser.add_argument("--all-languages", action="store_true", help="include every language")
    parser.add_argument("--limit", type=int, default=0, help="optional record limit for smoke tests")
    args = parser.parse_args()

    if not args.catalog.is_file():
        parser.error(f"catalog not found: {args.catalog}")

    records = build_records(args.catalog, None if args.all_languages else args.language)
    if args.limit:
        records = records[: args.limit]
    if not records:
        parser.error("no Text records matched; check the catalog header/language")

    index_path, manifest_path, digest, size = write_index(records, args.output_dir)
    print(
        f"wrote {len(records)} books -> {index_path} "
        f"({size} bytes compressed, sha256 {digest})",
        file=sys.stderr,
    )
    print(f"wrote {manifest_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
