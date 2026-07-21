#!/usr/bin/env python3
"""Generate the Greater Books LibriVox manifest from greaterbooks.com.

The app consumes ``Voxglass/Core/Resources/CuratedLists/greater-books.json``.
The richer generated source and audit artifacts live under ``Tools/CuratedLists``.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import re
import time
import unicodedata
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
TOOL_DIR = ROOT / "Tools" / "CuratedLists"
CACHE_DIR = TOOL_DIR / ".cache"
OUT_DIR = TOOL_DIR / "out"
APP_MANIFEST = ROOT / "Voxglass" / "Core" / "Resources" / "CuratedLists" / "greater-books.json"
WORKS_FILE = TOOL_DIR / "greater-books-works.json"
ALIASES_FILE = TOOL_DIR / "greater-books-creator-aliases.json"
SOURCE_CSV = TOOL_DIR / "greater-books-source.csv"
REPORT_FILE = OUT_DIR / "greater-books-report.json"
RICH_MANIFEST = OUT_DIR / "greater-books-eng.json"
SHORTLIST_URL = "http://www.greaterbooks.com/shortlist.html"

EXPECTED_PERIOD_COUNTS = {
    "Prehistory to 700 A. D.": 94,
    "700 to 1650": 85,
    "1650 to 1900": 239,
    "1900 to present": 122,
}
EXPECTED_TOTAL = sum(EXPECTED_PERIOD_COUNTS.values())

LANGUAGE_TOKENS = {
    "eng": {"eng", "english"},
    "deu": {"deu", "ger", "german"},
    "fre": {"fre", "fra", "french"},
    "nld": {"nld", "dut", "dutch"},
    "spa": {"spa", "spanish"},
    "ita": {"ita", "italian"},
    "por": {"por", "portuguese"},
    "rus": {"rus", "russian"},
    "zho": {"zho", "chi", "chinese"},
    "jpn": {"jpn", "japanese"},
    "lat": {"lat", "latin"},
    "grc": {"grc", "gre", "greek"},
    "pol": {"pol", "polish"},
    "fin": {"fin", "finnish"},
    "heb": {"heb", "hebrew"},
}

EXCLUDED_CREATORS = {
    "William John Locke",
    "Homer Greene",
    "Homer Eon Flint",
}

AUTHOR_FIXES = {
    "Dante": ["Dante Alighieri", "Dante"],
    "Galileo": ["Galileo Galilei", "Galileo"],
    "Tacitus": ["Tacitus", "Cornelius Tacitus"],
    "Cornelius Tacitus": ["Tacitus", "Cornelius Tacitus"],
    "F Scott Fitzgerald": ["F. Scott Fitzgerald", "F Scott Fitzgerald"],
    "D H Lawrence": ["D. H. Lawrence", "D H Lawrence"],
    "E M Forster": ["E. M. Forster", "E M Forster"],
    "H G Wells": ["H. G. Wells", "H G Wells"],
    "J D Salinger": ["J. D. Salinger", "J D Salinger"],
    "J K Rowling": ["J. K. Rowling", "J K Rowling"],
    "J R R Tolkien": ["J. R. R. Tolkien", "J R R Tolkien"],
    "T S Eliot": ["T. S. Eliot", "T S Eliot", "Thomas Stearns Eliot"],
    "Thomas S Kuhn": ["Thomas S. Kuhn", "Thomas S Kuhn"],
    "Henry Dead Thoreau": ["Henry David Thoreau"],
    "Henry David Thoreau": ["Henry David Thoreau"],
    "George Wilhelm Friedrich Hegel": ["Georg Wilhelm Friedrich Hegel", "George Wilhelm Friedrich Hegel"],
    "Simone Beauvoir": ["Simone de Beauvoir", "Simone Beauvoir"],
    "Andre Malraux": ["Andre Malraux", "André Malraux"],
    "Emile Zola": ["Emile Zola", "Émile Zola"],
    "Honore de Balzac": ["Honore de Balzac", "Honoré de Balzac"],
    "Moliere": ["Molière", "Moliere"],
    "Niccolo Machiavelli": ["Niccolò Machiavelli", "Niccolo Machiavelli"],
    "Francois Rabelais": ["François Rabelais", "Francois Rabelais"],
    "Francois Villon": ["François Villon", "Francois Villon"],
    "Rene Descartes": ["René Descartes", "Rene Descartes"],
    "Pedro Calderon de la Barca": ["Pedro Calderón de la Barca", "Pedro Calderon de la Barca"],
    "Alexander Hamilton; John Jay; James Madison": ["Alexander Hamilton", "John Jay", "James Madison"],
    "Karl Marx and Friedrich Engels": ["Karl Marx", "Friedrich Engels"],
    "William Wordsworth; Samuel Taylor Coleridge": ["William Wordsworth", "Samuel Taylor Coleridge"],
    "Denis Diderot et al.": ["Denis Diderot"],
    "Lucretius": ["Lucretius", "Titus Lucretius Carus"],
    "Ovid": ["Ovid", "Publius Ovidius Naso", "Publius (Ovid) Ovidius Naso", "Publius Ovidius Naso (Ovid)"],
    "Plutarch": ["Plutarch", "Lucius Mestrius Plutarchus"],
    "Cicero": ["Cicero", "Marcus Tullius Cicero"],
    "Horace": ["Horace", "Quintus Horatius Flaccus"],
    "Aesop": ["Aesop", "Æsop"],
    "Lăozĭ": ["Laozi", "Lao Tzu", "Lăozĭ"],
    "Mencius": ["Mencius", "Mengzi"],
}

AUTHORLESS_QUERY_TITLES = {
    "The Bible",
    "The Epic of Gilgamesh",
    "The Quran",
    "The Book of Job",
    "The Book of Genesis",
    "Ecclesiastes",
    "The Arabian Nights",
    "Beowulf",
    "The Song of Roland",
    "Nibelungenlied",
    "Sir Gawain and the Green Knight",
    "Njals Saga",
}

TITLE_ALIASES = {
    ("Herodotus", "History"): ["the histories", "histories", "the history of herodotus", "history of herodotus"],
    ("Thucydides", "The Peloponnesian War"): ["the history of the peloponnesian war", "history of the peloponnesian war"],
    ("Sophocles", "Oedipus the King"): ["oedipus rex", "oedipus king"],
    ("Aeschylus", "Oresteia"): ["the oresteia", "oresteia"],
    ("Lucretius", "On the Nature of Things"): ["de rerum natura", "on the nature of things"],
    ("Plutarch", "Parallel Lives"): ["plutarch's lives", "lives", "parallel lives"],
    ("Thomas Aquinas", "Summa Theologiae"): ["summa theologica", "summa theologiae"],
    ("Boethius", "Consolatio Philosophiae"): ["consolation of philosophy", "consolatio philosophiae"],
    ("Dante", "The Divine Commedy"): ["divine comedy", "the divine comedy"],
    ("William Shakespeare", "The First Part of Henry IV"): ["henry iv part 1", "henry iv, part 1", "king henry iv part 1"],
    ("William Shakespeare", "The Second Part of Henry IV"): ["henry iv part 2", "henry iv, part 2", "king henry iv part 2"],
    ("Christopher Marlowe", "Doctor Faustus"): ["dr faustus", "doctor faustus", "tragical history of doctor faustus"],
    ("Thomas Malory", "Le Morte d'Arthur"): ["morte d'arthur", "le morte d'arthur"],
    ("John Bunyan", "The Pilgrim's Progress"): ["pilgrim's progress", "the pilgrim's progress"],
    ("Blaise Pascal", "Thoughts"): ["pensees", "pensées", "thoughts"],
    ("Mark Twain", "Huckleberry Finn"): ["adventures of huckleberry finn", "huckleberry finn"],
    ("Honoré de Balzac", "Father Goriot"): ["father goriot", "pere goriot", "père goriot"],
    ("Fyodor Dostoevsky", "The Brothers Karamozov"): ["the brothers karamazov", "brothers karamazov"],
    ("Fyodor Dostoevsky", "Idiot"): ["the idiot", "idiot"],
    ("Nikolai Gogol", "Dead Souls"): ["dead souls"],
    ("Jean Racine", "Phèdre"): ["phedre", "phèdre", "phaedra"],
    ("Oscar Wilde", "The Picture of Dorian Grey"): ["the picture of dorian gray", "picture of dorian gray"],
    ("Marcel Proust", "In Remembrance of Things Past"): ["swann's way", "remembrance of things past", "in search of lost time"],
    ("F Scott Fitzgerald", "The Great Gatsby"): ["the great gatsby", "great gatsby"],
    ("George Orwell", "Nineteen Eighty-Four"): ["nineteen eighty-four", "1984"],
    ("Franz Kafka", "The Metamorphosis"): ["the metamorphosis", "metamorphosis"],
    ("H G Wells", "The Time Machine"): ["the time machine", "time machine"],
    ("The Bible", "The Bible"): ["the bible", "bible", "king james version"],
    ("", "The Bible"): ["the bible", "bible", "king james version"],
    ("", "The Epic of Gilgamesh"): ["epic of gilgamesh", "the epic of gilgamesh", "gilgamesh"],
    ("", "The Quran"): ["quran", "koran", "the quran", "the koran"],
    ("", "The Song of Roland"): ["song of roland", "the song of roland"],
    ("", "Njals Saga"): ["njal's saga", "njals saga", "burnt njal"],
}

GENERIC_TITLES = {
    "history",
    "essays",
    "poems",
    "stories",
    "plays",
    "complete works",
    "dialogues",
    "thoughts",
}


@dataclass
class Work:
    rank: int
    period: str
    period_rank: int
    author: str
    title: str
    score: int
    work_id: str
    search_authors: list[str] = field(default_factory=list)
    title_keys: list[str] = field(default_factory=list)


class ShortlistParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[dict[str, Any]] = []
        self.period = ""
        self.capture: str | None = None
        self.in_li = False
        self.current: dict[str, str] = {}
        self.period_counts: dict[str, int] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrs_dict = dict(attrs)
        if tag == "span" and attrs_dict.get("id", "").startswith("heading"):
            self.capture = "heading"
            return
        if tag == "li":
            self.in_li = True
            self.current = {"author": "", "title": "", "score": ""}
            return
        if self.in_li and tag == "span":
            klass = attrs_dict.get("class")
            if klass in {"author", "title", "score"}:
                self.capture = klass

    def handle_endtag(self, tag: str) -> None:
        if tag == "span":
            self.capture = None
        elif tag == "li" and self.in_li:
            self.in_li = False
            period_rank = self.period_counts.get(self.period, 0) + 1
            self.period_counts[self.period] = period_rank
            self.rows.append(
                {
                    "rank": len(self.rows) + 1,
                    "period": self.period,
                    "periodRank": period_rank,
                    "author": clean_text(self.current["author"]),
                    "title": clean_text(self.current["title"]),
                    "score": int(clean_text(self.current["score"]) or "0"),
                }
            )
            self.current = {}

    def handle_data(self, data: str) -> None:
        if not self.capture:
            return
        text = clean_text(data)
        if not text:
            return
        if self.capture == "heading":
            self.period = text
        elif self.in_li:
            self.current[self.capture] = clean_text(self.current.get(self.capture, "") + " " + text)


def clean_text(value: str) -> str:
    value = html.unescape(value)
    value = value.replace("\xa0", " ")
    return re.sub(r"\s+", " ", value).strip()


def ascii_fold(value: str) -> str:
    return unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")


def normalize_name(value: str) -> str:
    value = clean_text(value)
    value = ascii_fold(value).replace(".", "")
    value = value.replace("’", "'")
    value = re.sub(r"[^A-Za-z0-9'\s]+", " ", value)
    return re.sub(r"\s+", " ", value).strip()


def normalize_title(value: str) -> str:
    value = clean_text(value).lower().replace("’", "'")
    value = re.sub(r"\[[^\]]+\]$", "", value)
    value = re.sub(r"\([^)]*(?:version|translation|translator|vol|volume|book|part)[^)]*\)$", "", value)
    value = re.sub(r"\b(version|vol|volume|book|part)\s+[ivxlcdm0-9]+$", "", value, flags=re.I)
    value = ascii_fold(value)
    value = value.replace("&", " and ")
    value = re.sub(r"[^a-z0-9]+", " ", value)
    value = re.sub(r"\b(the|a|an)\b", " ", value)
    return re.sub(r"\s+", " ", value).strip()


def slug(value: str) -> str:
    value = ascii_fold(value.lower())
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-") or "anonymous"


def author_key(author: str) -> str:
    return normalize_name(author).lower()


def work_key(author: str, title: str) -> tuple[str, str]:
    return (normalize_name(author), clean_text(title))


def load_existing_aliases() -> dict[str, list[str]]:
    path = TOOL_DIR / "creator-aliases.json"
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    aliases: dict[str, list[str]] = {}
    for author, entry in data.get("authors", {}).items():
        aliases[author_key(author)] = [clean_text(a) for a in entry.get("observed", [])]
    return aliases


def split_author(author: str) -> list[str]:
    author = clean_text(author)
    if not author:
        return []
    if author in AUTHOR_FIXES:
        return AUTHOR_FIXES[author]
    pieces = re.split(r"\s*;\s*", author)
    if len(pieces) > 1:
        return [p for p in pieces if p]
    if " and " in author and author not in {"Jane Austen"}:
        return [p.strip() for p in author.split(" and ") if p.strip()]
    return [author]


def search_authors_for(author: str, existing_aliases: dict[str, list[str]]) -> list[str]:
    values: list[str] = []
    for part in split_author(author):
        fixed = AUTHOR_FIXES.get(part, [part])
        for name in fixed:
            values.append(clean_text(name))
            values.extend(existing_aliases.get(author_key(name), []))
    values.extend(existing_aliases.get(author_key(author), []))
    return sorted({v for v in values if v and v not in EXCLUDED_CREATORS})


def title_keys_for(work: Work) -> list[str]:
    aliases = [work.title]
    aliases.extend(TITLE_ALIASES.get(work_key(work.author, work.title), []))
    aliases.extend(TITLE_ALIASES.get(("", work.title), []))
    keys = [normalize_title(t) for t in aliases]
    return sorted({k for k in keys if k})


def title_matches(item_title: str, keys: list[str]) -> bool:
    item_key = normalize_title(item_title)
    if not item_key:
        return False
    for key in keys:
        if item_key == key:
            return True
        if len(key) >= 8 and len(item_key) >= 8 and (item_key.startswith(key) or key.startswith(item_key)):
            return True
        if key not in GENERIC_TITLES and len(key) >= 5 and key in item_key:
            return True
        if key not in GENERIC_TITLES and len(key) >= 10 and len(item_key) >= 8 and item_key in key:
            return True
    return False


def work_allows_item(work: Work, item: dict[str, Any]) -> bool:
    key = normalize_title(item["title"])
    if work.work_id in {"the-book-of-job", "the-book-of-genesis", "ecclesiastes"}:
        banned = {"commentary", "note", "notes", "morals", "homilies", "sermons"}
        if any(term in key for term in banned):
            return False
        work_title = normalize_title(work.title)
        return key == work_title or key.startswith(work_title) or f" {work_title}" in f" {key}"

    if work.work_id != "the-bible":
        return True

    banned = {
        "story",
        "stories",
        "history",
        "introduction",
        "claims",
        "science",
        "where we got",
        "juvenile",
        "children",
        "young people",
        "young folks",
        "wee ones",
        "worth reading",
        "defence",
        "trial",
        "book by book",
        "lessons",
        "shakespeare",
        "shakspeare",
        "making",
        "period",
        "great sinners",
        "captivating",
        "hurlbut",
        "on reading",
        "ingersoll",
    }
    if any(term in key for term in banned):
        return False
    allowed = {
        "bible kjv",
        "bible asv",
        "bible dra",
        "bible drv",
        "bible dby",
        "bible ylt",
        "bible web",
        "bible wnt",
        "bible bbe",
        "bible erv",
        "bible fenton",
        "bible complete",
        "holy bible",
        "world english bible",
        "douay rheims",
        "king james version",
        "old testament",
        "new testament",
    }
    return any(term in key for term in allowed)


def classify_language(values: Any) -> str | None:
    if values is None:
        return None
    if isinstance(values, str):
        raw = values.split(";")
    else:
        raw = []
        for value in values:
            raw.extend(str(value).split(";"))
    found = set()
    for lang in raw:
        token = clean_text(lang).lower()
        for lang_id, tokens in LANGUAGE_TOKENS.items():
            if token in tokens:
                found.add(lang_id)
    if len(found) == 1:
        return next(iter(found))
    return None


def fetch_url(url: str, cache_name: str, cache_only: bool) -> bytes:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_DIR / cache_name
    if cache_path.exists():
        return cache_path.read_bytes()
    if cache_only:
        raise RuntimeError(f"cache miss: {cache_path}")
    request = urllib.request.Request(url, headers={"User-Agent": "Voxglass curated list generator"})
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read()
    cache_path.write_bytes(payload)
    return payload


def ia_cache_name(query: str, page: int, rows: int) -> str:
    key = hashlib.sha256(f"{query}|{page}|{rows}".encode("utf-8")).hexdigest()[:24]
    return f"greater_books_ia_{key}_p{page}.json"


def ia_search(query: str, page: int, rows: int, cache_only: bool) -> dict[str, Any]:
    params = [
        ("q", query),
        ("fl[]", "identifier"),
        ("fl[]", "title"),
        ("fl[]", "creator"),
        ("fl[]", "language"),
        ("fl[]", "downloads"),
        ("fl[]", "date"),
        ("fl[]", "subject"),
        ("rows", str(rows)),
        ("output", "json"),
    ]
    if page > 0:
        params.append(("page", str(page)))
    url = "https://archive.org/advancedsearch.php?" + urllib.parse.urlencode(params)
    payload = fetch_url(url, ia_cache_name(query, page, rows), cache_only)
    return json.loads(payload.decode("utf-8"))


def enumerate_query(query: str, cache_only: bool, throttle: float, rows: int = 100) -> list[dict[str, Any]]:
    docs: list[dict[str, Any]] = []
    page = 1
    while True:
        data = ia_search(query, page, rows, cache_only)
        response = data["response"]
        docs.extend(response.get("docs", []))
        total = int(response.get("numFound", 0))
        if page * rows >= total:
            break
        page += 1
        if throttle > 0:
            time.sleep(throttle)
    return docs


def parse_shortlist(cache_only: bool) -> list[Work]:
    payload = fetch_url(SHORTLIST_URL, "greaterbooks_shortlist.html", cache_only)
    text = payload.decode("utf-8", errors="replace")
    rows: list[dict[str, Any]] = []
    period = ""
    period_counts: dict[str, int] = {}
    tokens = re.split(r'(?=<span id="heading[1-4]">|<li>)', text, flags=re.S)
    for token in tokens:
        if token.startswith('<span id="heading'):
            match = re.search(r'<span id="heading[1-4]">(.*?)</span>', token, flags=re.S)
            if match:
                period = clean_text(re.sub(r"<[^>]+>", " ", match.group(1)))
        elif token.startswith("<li>"):
            author_match = re.search(r'<span class="author">(.*?)</span>', token, flags=re.S)
            title_match = re.search(r'<span class="title">(.*?)</span>', token, flags=re.S)
            score_match = re.search(r'<span class="score">(.*?)</span>', token, flags=re.S)
            if not title_match or not score_match:
                continue
            period_rank = period_counts.get(period, 0) + 1
            period_counts[period] = period_rank
            rows.append(
                {
                    "rank": len(rows) + 1,
                    "period": period,
                    "periodRank": period_rank,
                    "author": clean_text(re.sub(r"<[^>]+>", " ", author_match.group(1))) if author_match else "",
                    "title": clean_text(re.sub(r"<[^>]+>", " ", title_match.group(1))),
                    "score": int(clean_text(re.sub(r"<[^>]+>", " ", score_match.group(1))) or "0"),
                }
            )

    if len(rows) != EXPECTED_TOTAL:
        raise RuntimeError(f"expected {EXPECTED_TOTAL} shortlist rows, got {len(rows)}")
    if period_counts != EXPECTED_PERIOD_COUNTS:
        raise RuntimeError(f"period counts changed: {period_counts}")

    seen: dict[str, int] = {}
    works: list[Work] = []
    existing_aliases = load_existing_aliases()
    for row in rows:
        base_id = f"{slug(row['author'])}-{slug(row['title'])}" if row["author"] else slug(row["title"])
        seen[base_id] = seen.get(base_id, 0) + 1
        work_id = base_id if seen[base_id] == 1 else f"{base_id}-{row['rank']}"
        work = Work(
            rank=row["rank"],
            period=row["period"],
            period_rank=row["periodRank"],
            author=row["author"],
            title=row["title"],
            score=row["score"],
            work_id=work_id,
            search_authors=search_authors_for(row["author"], existing_aliases),
        )
        work.title_keys = title_keys_for(work)
        works.append(work)
    return works


def write_source_files(works: list[Work]) -> None:
    WORKS_FILE.write_text(
        json.dumps(
            [
                {
                    "workID": work.work_id,
                    "rank": work.rank,
                    "period": work.period,
                    "periodRank": work.period_rank,
                    "author": work.author,
                    "title": work.title,
                    "score": work.score,
                    "sourceURL": SHORTLIST_URL,
                    "searchAuthors": work.search_authors,
                    "titleKeys": work.title_keys,
                }
                for work in works
            ],
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    with SOURCE_CSV.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["rank", "period", "period_rank", "author", "title", "score"],
            lineterminator="\n",
        )
        writer.writeheader()
        for work in works:
            writer.writerow(
                {
                    "rank": work.rank,
                    "period": work.period,
                    "period_rank": work.period_rank,
                    "author": work.author,
                    "title": work.title,
                    "score": work.score,
                }
            )

    aliases = {
        work.author: {"observed": work.search_authors}
        for work in works
        if work.author and work.search_authors
    }
    ALIASES_FILE.write_text(
        json.dumps(
            {
                "_note": "Generated from the Greater Books shortlist and reused Great Books IA creator aliases. Review before widening matching rules.",
                "_excluded": sorted(EXCLUDED_CREATORS),
                "authors": dict(sorted(aliases.items())),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def values_as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [clean_text(str(v)) for v in value if clean_text(str(v))]
    text = clean_text(str(value))
    return [text] if text else []


def add_doc(items: dict[str, dict[str, Any]], doc: dict[str, Any], label: str) -> None:
    identifier = clean_text(doc.get("identifier", ""))
    if not identifier:
        return
    item = items.setdefault(
        identifier,
        {
            "identifier": identifier,
            "title": clean_text(doc.get("title", "")),
            "creators": values_as_list(doc.get("creator")),
            "languages": values_as_list(doc.get("language")),
            "downloads": int(doc.get("downloads") or 0),
            "date": clean_text(str(doc.get("date", ""))) or None,
            "subjects": values_as_list(doc.get("subject")),
            "queryLabels": [],
        },
    )
    item["queryLabels"].append(label)


def enumerate_librivox_bulk(cache_only: bool, throttle: float) -> tuple[dict[str, dict[str, Any]], dict[str, int]]:
    query = "collection:(librivoxaudio) AND mediatype:audio"
    print("Bulk fetching LibriVox collection from archive.org")
    data = ia_search(query, page=0, rows=25000, cache_only=cache_only)
    response = data["response"]
    docs = response.get("docs", [])
    total = int(response.get("numFound", 0))
    if len(docs) < total:
        raise RuntimeError(f"bulk fetch returned {len(docs)} of {total} LibriVox items")
    items: dict[str, dict[str, Any]] = {}
    for doc in docs:
        add_doc(items, doc, "bulk:librivoxaudio")
    return items, {"bulk:librivoxaudio": len(docs)}


def enumerate_catalog_by_creator(works: list[Work], cache_only: bool, throttle: float) -> tuple[dict[str, dict[str, Any]], dict[str, int]]:
    queries: dict[str, str] = {}
    for work in works:
        for author in work.search_authors:
            queries[f"creator:{author}"] = f'collection:(librivoxaudio) AND mediatype:audio AND creator:"{author}"'
        if not work.author or work.title in AUTHORLESS_QUERY_TITLES:
            for title in {work.title, *TITLE_ALIASES.get(("", work.title), [])}:
                queries[f"title:{title}"] = f'collection:(librivoxaudio) AND mediatype:audio AND title:"{title}"'

    items: dict[str, dict[str, Any]] = {}
    query_counts: dict[str, int] = {}
    for index, (label, query) in enumerate(sorted(queries.items()), start=1):
        print(f"[{index}/{len(queries)}] {label}")
        docs = enumerate_query(query, cache_only=cache_only, throttle=throttle)
        query_counts[label] = len(docs)
        for doc in docs:
            add_doc(items, doc, label)
        if throttle > 0:
            time.sleep(throttle)
    return items, query_counts


def build_author_index(works: list[Work]) -> dict[str, set[str]]:
    index: dict[str, set[str]] = {}
    for work in works:
        for author in work.search_authors:
            index.setdefault(author_key(author), set()).add(work.work_id)
        if work.author:
            index.setdefault(author_key(work.author), set()).add(work.work_id)
    return index


def candidate_work_ids(item: dict[str, Any], works_by_id: dict[str, Work], author_index: dict[str, set[str]]) -> set[str]:
    candidates: set[str] = set()
    for creator in item["creators"]:
        if creator in EXCLUDED_CREATORS:
            continue
        key = author_key(creator)
        candidates.update(author_index.get(key, set()))
        parts = key.split()
        if parts:
            last = parts[-1]
            for alias_key, work_ids in author_index.items():
                if alias_key.split()[-1:] == [last]:
                    candidates.update(work_ids)
    if not candidates:
        for work in works_by_id.values():
            if not work.author and title_matches(item["title"], work.title_keys):
                candidates.add(work.work_id)
    return candidates


def build_manifests(works: list[Work], items: dict[str, dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    works_by_id = {work.work_id: work for work in works}
    author_index = build_author_index(works)
    matches_by_work: dict[str, list[dict[str, Any]]] = {work.work_id: [] for work in works}
    matched_languages: dict[str, int] = {}
    unmatched_eng: list[dict[str, Any]] = []

    for item in items.values():
        if item["creators"] and all(creator in EXCLUDED_CREATORS for creator in item["creators"]):
            continue
        lang = classify_language(item["languages"])
        if lang:
            matched_languages[lang] = matched_languages.get(lang, 0) + 1
        candidates = candidate_work_ids(item, works_by_id, author_index)
        matched_ids = [
            work_id for work_id in candidates
            if title_matches(item["title"], works_by_id[work_id].title_keys)
            and work_allows_item(works_by_id[work_id], item)
        ]
        if matched_ids:
            for work_id in matched_ids:
                matches_by_work[work_id].append(item)
        elif lang == "eng":
            unmatched_eng.append(item)

    seen_identifiers: set[str] = set()
    manifest: list[dict[str, Any]] = []
    coverage_rows: list[dict[str, Any]] = []

    for work in sorted(works, key=lambda w: w.rank):
        items_for_work = sorted(
            matches_by_work[work.work_id],
            key=lambda item: (-item["downloads"], normalize_title(item["title"]), item["identifier"]),
        )
        english_items = [item for item in items_for_work if classify_language(item["languages"]) == "eng"]
        coverage_rows.append(
            {
                "workID": work.work_id,
                "rank": work.rank,
                "period": work.period,
                "author": work.author,
                "title": work.title,
                "score": work.score,
                "covered": bool(english_items),
                "recordingCount": len(english_items),
                "identifiers": [item["identifier"] for item in english_items],
            }
        )
        for item in english_items:
            if item["identifier"] in seen_identifiers:
                continue
            seen_identifiers.add(item["identifier"])
            manifest.append(
                {
                    "rank": len(manifest) + 1,
                    "sourceRank": work.rank,
                    "period": work.period,
                    "workID": work.work_id,
                    "title": item["title"],
                    "author": work.author or "Anonymous",
                    "identifier": item["identifier"],
                    "language": "eng",
                    "downloads": item["downloads"],
                }
            )

    covered = [row for row in coverage_rows if row["covered"]]
    report = {
        "sourceURL": SHORTLIST_URL,
        "totalWorks": len(works),
        "manifestCount": len(manifest),
        "coveredWorks": len(covered),
        "coveragePercent": round((len(covered) / len(works)) * 100, 1),
        "languageDistribution": dict(sorted(matched_languages.items())),
        "coverage": coverage_rows,
        "zeroCoverageWorks": [row for row in coverage_rows if not row["covered"]],
        "unmatchedEnglishItemCount": len(unmatched_eng),
        "unmatchedEnglishItems": sorted(
            [
                {
                    "identifier": item["identifier"],
                    "title": item["title"],
                    "creators": item["creators"],
                    "downloads": item["downloads"],
                }
                for item in unmatched_eng
            ],
            key=lambda row: (-row["downloads"], row["title"]),
        )[:250],
    }
    return manifest, report


def write_outputs(manifest: list[dict[str, Any]], report: dict[str, Any]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rich = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    RICH_MANIFEST.write_text(rich, encoding="utf-8")
    app_manifest = [
        {
            "rank": entry["rank"],
            "title": entry["title"],
            "author": entry["author"],
            "identifier": entry["identifier"],
        }
        for entry in manifest
    ]
    APP_MANIFEST.write_text(json.dumps(app_manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    REPORT_FILE.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-only", action="store_true")
    parser.add_argument("--per-creator", action="store_true", help="Use the slower creator/title query path")
    parser.add_argument("--throttle", type=float, default=0.05)
    args = parser.parse_args()

    works = parse_shortlist(cache_only=args.cache_only)
    write_source_files(works)
    print(f"Parsed {len(works)} Greater Books shortlist rows")

    if args.per_creator:
        items, query_counts = enumerate_catalog_by_creator(works, cache_only=args.cache_only, throttle=args.throttle)
    else:
        items, query_counts = enumerate_librivox_bulk(cache_only=args.cache_only, throttle=args.throttle)
    print(f"Enumerated {len(items)} unique LibriVox items")

    manifest, report = build_manifests(works, items)
    report["queryCount"] = len(query_counts)
    report["queriesWithHits"] = sum(1 for count in query_counts.values() if count > 0)
    write_outputs(manifest, report)

    if len(manifest) < 250:
        raise RuntimeError(f"generated manifest is suspiciously small: {len(manifest)}")
    if manifest[0]["author"] != "Homer" or "Odyssey" not in manifest[0]["title"]:
        raise RuntimeError(f"rank 1 is not Homer Odyssey: {manifest[0]}")
    if len({entry["identifier"] for entry in manifest}) != len(manifest):
        raise RuntimeError("manifest contains duplicate identifiers")

    print(
        "Wrote "
        f"{APP_MANIFEST.relative_to(ROOT)} ({len(manifest)} entries), "
        f"{REPORT_FILE.relative_to(ROOT)} ({report['coveredWorks']}/{report['totalWorks']} covered)"
    )


if __name__ == "__main__":
    main()
