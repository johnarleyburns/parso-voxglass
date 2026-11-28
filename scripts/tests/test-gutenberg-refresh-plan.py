#!/usr/bin/env python3
"""Regression tests for incremental Gutenberg upstream refresh planning."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "gutenberg-refresh-plan.py"


def listing_line(path: str, size: int, modified: str = "2026/11/20 22:08:43") -> str:
    return f"-rw-r--r-- {size:>12} {modified} {path}\n"


def snapshot_line(book_id: int, kind: str, size: int, modified: str) -> str:
    return f"{book_id}\t{kind}\t{size}\t{modified}\n"


class GutenbergRefreshPlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.all_ids = self.root / "all-ids"
        self.uploaded = self.root / "uploaded-ids"
        self.listing = self.root / "listing"
        self.snapshot = self.root / "upstream.pending"
        self.previous = self.root / "upstream-files"
        self.cursor = self.root / "cursor"
        self.cursor_out = self.root / "cursor.pending"
        self.queue = self.root / "queue"
        self.removed = self.root / "removed"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_ids(self, path: Path, values: list[int]) -> None:
        path.write_text("".join(f"{value}\n" for value in values), encoding="utf-8")

    def run_plan(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--rsync-listing",
                str(self.listing),
                "--snapshot-out",
                str(self.snapshot),
                "--previous-snapshot",
                str(self.previous),
                "--all-ids",
                str(self.all_ids),
                "--uploaded-ids",
                str(self.uploaded),
                "--cursor-file",
                str(self.cursor),
                "--cursor-out",
                str(self.cursor_out),
                "--queue",
                str(self.queue),
                "--removed-out",
                str(self.removed),
                *arguments,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def queued_ids(self) -> list[int]:
        return [int(line) for line in self.queue.read_text(encoding="utf-8").splitlines()]

    def test_parse_listing_keeps_only_epub_and_cover_files(self) -> None:
        self.all_ids.write_text("1\n2\n", encoding="utf-8")
        self.uploaded.write_text("1\n2\n", encoding="utf-8")
        self.listing.write_text(
            "drwxr-xr-x 4096 2026/11/20 22:08:43 1/\n"
            + listing_line("1/pg1.epub", 100)
            + listing_line("1/pg1.cover.medium.jpg", 20)
            + listing_line("1/pg1-images.epub", 500)
            + listing_line("1/notes.txt", 5)
            + listing_line("2/pg2.epub", 200, "2026/11/21 01:02:03"),
            encoding="utf-8",
        )
        result = self.run_plan("--refresh-batch-size", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = self.snapshot.read_text(encoding="utf-8")
        self.assertIn("1\tepub\t100\t2026/11/20 22:08:43\n", snapshot)
        self.assertIn("1\tcover\t20\t2026/11/20 22:08:43\n", snapshot)
        self.assertIn("2\tepub\t200\t2026/11/21 01:02:03\n", snapshot)
        self.assertNotIn("images", snapshot)
        self.assertNotIn("notes", snapshot)

    def test_new_and_changed_ids_are_queued_without_refresh(self) -> None:
        self.write_ids(self.all_ids, [1, 2, 3, 4])
        self.write_ids(self.uploaded, [1, 2, 3])
        self.previous.write_text(
            snapshot_line(1, "epub", 100, "2026/11/20 22:08:43")
            + snapshot_line(2, "epub", 200, "2026/11/20 22:08:43")
            + snapshot_line(3, "epub", 300, "2026/11/20 22:08:43"),
            encoding="utf-8",
        )
        self.listing.write_text(
            listing_line("1/pg1.epub", 100)
            + listing_line("2/pg2.epub", 205, "2026/11/25 12:00:00")
            + listing_line("3/pg3.epub", 300)
            + listing_line("4/pg4.epub", 400),
            encoding="utf-8",
        )
        result = self.run_plan("--refresh-batch-size", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queued_ids(), [2, 4])

    def test_first_run_establishes_baseline_without_requeueing_everything(self) -> None:
        self.write_ids(self.all_ids, [1, 2])
        self.write_ids(self.uploaded, [1, 2])
        self.listing.write_text(
            listing_line("1/pg1.epub", 100) + listing_line("2/pg2.epub", 200),
            encoding="utf-8",
        )
        result = self.run_plan("--refresh-batch-size", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queued_ids(), [])
        self.assertTrue(self.snapshot.is_file())

    def test_rotating_refresh_wraps_and_advances_cursor(self) -> None:
        self.write_ids(self.all_ids, [1, 2, 3, 4, 5])
        self.write_ids(self.uploaded, [1, 2, 3, 4, 5])
        self.cursor.write_text("4\n", encoding="utf-8")
        self.listing.write_text(
            "".join(listing_line(f"{book_id}/pg{book_id}.epub", book_id * 100) for book_id in range(1, 6)),
            encoding="utf-8",
        )
        result = self.run_plan("--refresh-batch-size", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queued_ids(), [1, 5])
        self.assertEqual(self.cursor_out.read_text(encoding="utf-8").strip(), "1")

    def test_refresh_all_queues_the_whole_catalog_once(self) -> None:
        self.write_ids(self.all_ids, [1, 2, 3])
        self.write_ids(self.uploaded, [1, 2, 3])
        self.listing.write_text(
            "".join(listing_line(f"{book_id}/pg{book_id}.epub", book_id * 100) for book_id in (1, 2, 3)),
            encoding="utf-8",
        )
        result = self.run_plan("--refresh-all", "--refresh-batch-size", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queued_ids(), [1, 2, 3])

    def test_removed_ids_are_reported_but_not_queued(self) -> None:
        self.write_ids(self.all_ids, [1, 2])
        self.write_ids(self.uploaded, [1, 2])
        self.previous.write_text(
            snapshot_line(1, "epub", 100, "2026/11/20 22:08:43")
            + snapshot_line(2, "epub", 200, "2026/11/20 22:08:43"),
            encoding="utf-8",
        )
        self.listing.write_text(listing_line("1/pg1.epub", 100), encoding="utf-8")
        result = self.run_plan("--refresh-batch-size", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queued_ids(), [])
        self.assertEqual(self.removed.read_text(encoding="utf-8").splitlines(), ["2"])

    def test_cover_only_change_requeues_the_book(self) -> None:
        self.write_ids(self.all_ids, [1])
        self.write_ids(self.uploaded, [1])
        self.previous.write_text(
            snapshot_line(1, "epub", 100, "2026/11/20 22:08:43")
            + snapshot_line(1, "cover", 20, "2026/11/20 22:08:43"),
            encoding="utf-8",
        )
        self.listing.write_text(
            listing_line("1/pg1.epub", 100)
            + listing_line("1/pg1.cover.medium.jpg", 25, "2026/11/25 12:00:00"),
            encoding="utf-8",
        )
        result = self.run_plan("--refresh-batch-size", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queued_ids(), [1])


if __name__ == "__main__":
    unittest.main()
