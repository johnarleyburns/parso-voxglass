#!/usr/bin/env python3
"""Probe archive.org for each GBWW author's creator strings and emit a
suggested creator-aliases.json.

This script queries the Internet Archive advancedsearch API for each
author in gbww-works.json, collects every distinct ``creator`` string in
the results, and writes a JSON mapping of canonical author names to
their observed creator strings on archive.org.

The output file (creator-aliases.json) REQUIRES HUMAN REVIEW before
Phase 1 closes.  Loose surname probes produce namesake false positives
— see commit 75850ff and the excludedCreators list for prior incidents.

Run:  python3 Tools/CuratedLists/probe_creator_aliases.py [--dry-run]

Flags:
  --dry-run   Show what queries would be made; do not contact archive.org.
  --cached    Use only cached responses (in .cache/aliases/), no network.
"""

from __future__ import annotations

import json
import time
import sys
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────

GBWW_WORKS = Path("Tools/CuratedLists/gbww-works.json")
OUT_ALIASES = Path("Tools/CuratedLists/creator-aliases.json")
CACHE_DIR = Path("Tools/CuratedLists/.cache/aliases")

# Build from existing greatBooksCreators + workbook-only authors
BYPASS_CREATORS = {
    # Compound authors: the plan is to probe individual names
    "Alexander Hamilton; James Madison; John Jay": ["Alexander Hamilton", "James Madison", "John Jay"],
    "Karl Marx; Friedrich Engels": ["Karl Marx", "Friedrich Engels"],
    "Sigmund Freud; Josef Breuer": ["Sigmund Freud", "Josef Breuer"],
    # Non-author workbook rows; these are searched by title, not creator
    "United States": [],
}

# Known variant probe strings for authors where the canonical IA creator
# string differs from the GBWW author name.  Populated from root cause 5
# and from the probe results.
KNOWN_VARIANTS: dict[str, list[str]] = {
    "Michel de Montaigne": ["Montaigne", "Michel Eyquem de Montaigne"],
    "Baruch Spinoza": ["Spinoza", "Benedict de Spinoza", "Spinoza, Benedict de"],
    "Montesquieu": ["Montesquieu", "Charles-Louis de Secondat", "Baron de Montesquieu"],
    "Molière": ["Moliere", "Molière"],
    "Saint Augustine": ["Augustine", "Saint Augustine", "Augustine of Hippo", "St. Augustine"],
    "Augustine of Hippo": ["Augustine", "Saint Augustine", "St. Augustine of Hippo"],
    "Niccolò Machiavelli": ["Machiavelli", "Niccolo Machiavelli"],
    "Thomas Aquinas": ["Aquinas", "Saint Thomas Aquinas", "St. Thomas Aquinas"],
    "G. W. F. Hegel": ["Hegel", "Georg Wilhelm Friedrich Hegel", "G. W. F. Hegel"],
    "Georg Wilhelm Friedrich Hegel": ["Hegel", "G. W. F. Hegel"],
    "Dante Alighieri": ["Dante", "Dante Alighieri"],
    "Miguel de Cervantes": ["Cervantes", "Miguel de Cervantes Saavedra"],
    "Søren Kierkegaard": ["Kierkegaard", "Soren Kierkegaard"],
    "René Descartes": ["Descartes", "Rene Descartes"],
    "François Rabelais": ["Rabelais", "Francois Rabelais"],
    "Honoré de Balzac": ["Balzac", "Honore de Balzac"],
    "Johann Wolfgang von Goethe": ["Goethe", "Johann Wolfgang von Goethe"],
    "Fyodor Dostoevsky": ["Dostoevsky", "Fyodor Dostoyevsky"],
    "Leo Tolstoy": ["Tolstoy", "Leo Tolstoi"],
    "Anton Chekhov": ["Chekhov", "Anton Chekov"],
    "Georg Wilhelm Friedrich Hegel": ["Hegel", "G. W. F. Hegel"],
    "Friedrich Nietzsche": ["Nietzsche"],
    "Eugene O'Neill": ["O'Neill", "Eugene ONeill", "Eugene O'neill"],
    "Henrik Ibsen": ["Ibsen"],
    "Jean Racine": ["Racine"],
    "Voltaire": ["Voltaire"],
}

# Known creators to exclude from aliases (namesakes per commit 75850ff):
EXCLUDED_CREATORS: list[str] = [
    "William John Locke",
    "Homer Greene",
    "Homer Eon Flint",
]


# ── API helpers ─────────────────────────────────────────────────────────

BASE = "https://archive.org/advancedsearch.php"


def search_creator(creator: str, dry_run: bool = False) -> list[dict]:
    """Return up to 100 docs matching a creator query.  Caches responses."""
    cache_key = f"creator_{creator.replace(' ', '_')}.json"
    cache_path = CACHE_DIR / cache_key

    if cache_path.exists():
        return json.loads(cache_path.read_text(encoding="utf-8"))

    if dry_run:
        print(f"  [dry-run] would query: creator:\"{creator}\"")
        return []

    query = f'collection:(librivoxaudio) AND creator:"{creator}"'
    params = urllib.parse.urlencode({
        "q": query,
        "fl[]": ["identifier", "creator", "title", "language"].__class__,
        "rows": "100",
        "output": "json",
    })
    # Actually build the URL properly — multi-valued fl[]
    url = (
        f"{BASE}?q={urllib.parse.quote(query, safe='')}"
        f"&fl[]=identifier&fl[]=creator&fl[]=title&fl[]=language"
        f"&rows=100&output=json"
    )

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Voxglass/1.0 (creator-alias-probe)"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        docs = data.get("response", {}).get("docs", [])
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(docs, indent=2), encoding="utf-8")
        return docs
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code} for creator:{creator}")
        return []
    except Exception as e:
        print(f"  Error for creator:{creator}: {e}")
        return []


def collect_creator_strings(author: str, dry_run: bool = False) -> list[str]:
    """Probe archive.org for all distinct creator strings for an author."""
    seen: set[str] = set()

    # 1. Exact match
    docs = search_creator(author, dry_run=dry_run)
    if docs:
        for d in docs:
            c = (d.get("creator") or "")
            if isinstance(c, list):
                seen.update(c)
            elif c:
                seen.add(c)

    # 2. Variants
    for variant in KNOWN_VARIANTS.get(author, []):
        if variant == author:
            continue
        docs = search_creator(variant, dry_run=dry_run)
        for d in docs:
            c = (d.get("creator") or "")
            if isinstance(c, list):
                seen.update(c)
            elif c:
                seen.add(c)

    # 3. Surname-only probe (if no results yet and author isn't compound)
    if not seen and ";" not in author:
        surname = author.split()[-1].strip(".,")
        if len(surname) > 3 and surname != author:
            docs = search_creator(surname, dry_run=dry_run)
            for d in docs:
                c = (d.get("creator") or "")
                if isinstance(c, list):
                    seen.update(c)
                elif c:
                    seen.add(c)

    return sorted(seen)


# ── main ────────────────────────────────────────────────────────────────

def main() -> None:
    dry_run = "--dry-run" in sys.argv
    cached_only = "--cached" in sys.argv

    works = json.loads(GBWW_WORKS.read_text(encoding="utf-8"))
    authors_raw = sorted(set(w["author"] for w in works))

    # Resolve compound authors
    authors: list[str] = []
    for a in authors_raw:
        if a in BYPASS_CREATORS:
            authors.extend(BYPASS_CREATORS[a])
        else:
            authors.append(a)

    # Deduplicate after resolving compounds
    authors = sorted(set(authors))
    print(f"Probing {len(authors)} authors...")

    aliases: dict[str, dict] = {}
    for i, author in enumerate(authors):
        if cached_only and not any(
            (CACHE_DIR / f"creator_{v.replace(' ', '_')}.json").exists()
            for v in [author] + KNOWN_VARIANTS.get(author, [])
        ):
            continue

        print(f"[{i+1}/{len(authors)}] {author}")
        strings = collect_creator_strings(author, dry_run=dry_run)
        entry: dict = {"observed": strings}
        if strings:
            print(f"  → {len(strings)} creator string(s): {', '.join(strings[:5])}")
            if len(strings) > 5:
                print(f"    ... and {len(strings) - 5} more")
        else:
            print("  → no results")

        aliases[author] = entry
        if not dry_run and strings:
            time.sleep(1.0)  # rate limit

    # Add excluded creators list
    output = {
        "_note": "This file requires human review before Phase 1 completes. "
                 "Loose surname probes produce namesake false positives. "
                 "Populate the 'excluded' array with confirmed false positives.",
        "_excluded": EXCLUDED_CREATORS,
        "authors": dict(sorted(aliases.items())),
    }

    OUT_ALIASES.parent.mkdir(parents=True, exist_ok=True)
    OUT_ALIASES.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"\nWrote {OUT_ALIASES}")
    print("REMINDER: review 'excluded' array for namesake false positives before Phase 1 closes.")


if __name__ == "__main__":
    main()
