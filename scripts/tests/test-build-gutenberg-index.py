#!/usr/bin/env python3
"""Regression tests for the on-device Gutenberg catalog index builder."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "build-gutenberg-index.py"
HEADER = "Type,Text#,Title,Authors,Language,Subjects,Bookshelves,Issued\n"


def catalog(rows: list[tuple[str, str, str, str]]) -> str:
    return HEADER + "".join(
        f'Text,{book_id},"{title}","{author}","{language}",Subject,Shelf,2020-01-01\n'
        for book_id, title, author, language in rows
    )


class BuildGutenbergIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.catalog = self.root / "pg_catalog.csv"
        self.output = self.root / "catalog"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_builder(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--catalog",
                str(self.catalog),
                "--output-dir",
                str(self.output),
                *arguments,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def manifest(self) -> dict:
        return json.loads((self.output / "manifest.json").read_text(encoding="utf-8"))

    def index(self, manifest: dict) -> dict:
        compressed = (self.output / manifest["index"]).read_bytes()
        return json.loads(zlib.decompress(compressed))

    def test_default_includes_every_language(self) -> None:
        self.catalog.write_text(
            catalog(
                [
                    ("1", "English", "Doe, Jane", "en"),
                    ("2", "Français", "Roe, Jean", "fr"),
                    ("3", "Deutsch; Englisch", "Muster, Max", "de; en"),
                ]
            ),
            encoding="utf-8",
        )
        result = self.run_builder()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.manifest()
        payload = self.index(manifest)
        self.assertEqual(manifest["bookCount"], 3)
        self.assertEqual([book["id"] for book in payload["books"]], [1, 2, 3])
        self.assertEqual(payload["books"][2]["languages"], ["de", "en"])

    def test_explicit_language_still_filters(self) -> None:
        self.catalog.write_text(
            catalog(
                [
                    ("1", "English", "Doe, Jane", "en"),
                    ("2", "Français", "Roe, Jean", "fr"),
                ]
            ),
            encoding="utf-8",
        )
        result = self.run_builder("--language", "fr")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([book["id"] for book in self.index(self.manifest())["books"]], [2])

    def test_non_text_and_invalid_rows_are_excluded(self) -> None:
        self.catalog.write_text(
            HEADER
            + 'Text,1,"Book",Author,en,Subject,Shelf,2020-01-01\n'
            + 'Audio,2,"Audio",Author,en,Subject,Shelf,2020-01-01\n'
            + 'Text,not-an-id,"Bad",Author,en,Subject,Shelf,2020-01-01\n'
            + 'Text,3,"",Author,en,Subject,Shelf,2020-01-01\n',
            encoding="utf-8",
        )
        result = self.run_builder()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([book["id"] for book in self.index(self.manifest())["books"]], [1])

    def test_manifest_matches_index_bytes(self) -> None:
        self.catalog.write_text(
            catalog([("42", "Book", "Author", "en")]), encoding="utf-8"
        )
        result = self.run_builder()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.manifest()
        compressed = (self.output / manifest["index"]).read_bytes()
        self.assertEqual(manifest["bytes"], len(compressed))
        self.assertEqual(manifest["sha256"], hashlib.sha256(compressed).hexdigest())
        self.assertTrue(manifest["index"].startswith("index-"))
        self.assertEqual(manifest["sha256"][:16], manifest["index"][6:-10])

    def test_only_one_index_version_is_kept_locally(self) -> None:
        self.catalog.write_text(
            catalog([("1", "First", "Author", "en")]), encoding="utf-8"
        )
        self.assertEqual(self.run_builder().returncode, 0)
        first = self.manifest()["index"]
        self.catalog.write_text(
            catalog([("1", "First", "Author", "en"), ("2", "Second", "Author", "fr")]),
            encoding="utf-8",
        )
        self.assertEqual(self.run_builder().returncode, 0)
        indexes = sorted(path.name for path in self.output.glob("index-*.json.zlib"))
        self.assertEqual(len(indexes), 1)
        self.assertNotEqual(indexes[0], first)


if __name__ == "__main__":
    unittest.main()
