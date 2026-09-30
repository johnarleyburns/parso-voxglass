#!/usr/bin/env python3
"""Build a reviewable String Catalog from SwiftUI's user-facing literals.

Xcode's export-localizations command currently rebuilds every platform target in
this repository before it extracts strings. This small, deterministic extractor
keeps the catalog reviewable in CI and deliberately marks machine translations
as needs_review until a native speaker signs them off.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ["de", "fr", "es", "it", "pt-BR", "nl", "ja", "zh-Hans", "ru", "pl", "he"]
LOCALIZABLE_CONTEXT = re.compile(
    r"(?:Text|Button|Label|Link|Toggle|Picker|Section|Menu|ContentUnavailableView|"
    r"confirmationDialog|navigationTitle|alert|accessibilityLabel|accessibilityHint|"
    r"accessibilityValue|String\(localized:|IntentDescription|shortTitle|description|"
    r"@Parameter\(title)|SectionTitle|FilterChip|VoxglassGroupedSection|VoxglassScreen|"
    r"NarrationPrimaryButton|NarrationSecondaryButton|title\s*:|subtitle\s*:|"
    r"label\s*:|detail\s*:|message\s*:|error|empty|placeholder|announcement|"
    r"footer|prompt|reason|caption|hint|format|copy"
)
STRING = re.compile(r'"((?:\\.|[^"\\])*)"')
SKIP = {
    "", " ", "\n", "true", "false", "utf8", "en", "de", "fr", "es", "it", "ja", "ru", "pl", "he",
}


def unescape(value: str) -> str:
    replacements = {"\\n": "\n", "\\r": "\r", "\\t": "\t", '\\"': '"', "\\\\": "\\"}
    for escaped, plain in replacements.items():
        value = value.replace(escaped, plain)
    return re.sub(
        r"\\u([0-9a-fA-F]{4})",
        lambda match: chr(int(match.group(1), 16)),
        value,
    )


def extract() -> dict[str, str]:
    values: dict[str, str] = {}
    roots = ["Voxglass", "VoxglassShared", "VoxglassWidgets", "VoxglassWatch"]
    for root_name in roots:
        for path in (ROOT / root_name).rglob("*.swift"):
            if path.parts[-2:] and "Core" in path.parts:
                continue
            source = path.read_text(encoding="utf-8")
            for line in source.splitlines():
                if '"""' in line:
                    continue
                for match in STRING.finditer(line):
                    context = line[: match.start()]
                    raw = unescape(match.group(1))
                    if raw in SKIP or "http://" in raw or "https://" in raw or "accessibilityIdentifier" in context:
                        continue
                    if "Text(verbatim:" in context:
                        continue
                    if not LOCALIZABLE_CONTEXT.search(context):
                        continue
                    if not any(character.isalpha() for character in raw):
                        continue
                    if len(raw) > 500:
                        continue
                    values.setdefault(raw, str(path.relative_to(ROOT)))
    return dict(sorted(values.items(), key=lambda item: item[0].casefold()))


def protect(value: str) -> tuple[str, list[str]]:
    """Protect Swift interpolation, including nested expressions."""
    output: list[str] = []
    placeholders: list[str] = []
    index = 0
    while index < len(value):
        if value.startswith("\\(", index):
            start = index
            depth = 1
            index += 2
            while index < len(value) and depth:
                if value[index] == "(":
                    depth += 1
                elif value[index] == ")":
                    depth -= 1
                index += 1
            if depth == 0:
                placeholders.append(value[start:index])
                output.append(f"⟪VG{len(placeholders) - 1}⟫")
                continue
            index = start
        output.append(value[index])
        index += 1
    return "".join(output), placeholders


def translate_batch(values: list[str], language: str) -> list[str]:
    protected: list[str] = []
    all_placeholders: list[list[str]] = []
    for value in values:
        item, placeholders = protect(value)
        protected.append(item)
        all_placeholders.append(placeholders)
    joined = "\n⟦VOXGLASS_BREAK⟧\n".join(protected)
    query = urllib.parse.urlencode(
        {"client": "gtx", "sl": "en", "tl": language, "dt": "t", "q": joined}
    )
    request = urllib.request.Request(
        f"https://translate.googleapis.com/translate_a/single?{query}",
        headers={"User-Agent": "Voxglass-localization-draft/1.0"},
    )
    try:
        payload = json.loads(urllib.request.urlopen(request, timeout=5).read())
        translated = "".join(item[0] for item in payload[0] if item and item[0])
        pieces = translated.split("⟦VOXGLASS_BREAK⟧")
        if len(pieces) != len(values):
            raise ValueError("translation service dropped the batch delimiter")
        result: list[str] = []
        for source, piece, placeholders in zip(values, pieces, all_placeholders):
            for index, original in enumerate(placeholders):
                for marker in (
                    f"⟪VG{index}⟫",
                    f"⟪ВГ{index}⟫",  # Google sometimes transliterates the marker in Russian.
                    f"⟦VG{index}⟧",
                    f"【VG{index}】",
                ):
                    piece = piece.replace(marker, original)
            # Never ship a translation that drops or leaks a Swift interpolation.
            if placeholders and not all(original in piece for original in placeholders):
                piece = source
            result.append(piece.strip())
        return result
    except Exception as error:  # pragma: no cover - network is intentionally optional
        print(f"warning: {language} translation batch failed: {error}", file=sys.stderr)
        return values


def translations(values: list[str], language: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for offset in range(0, len(values), 20):
        batch = values[offset : offset + 20]
        for source, translated in zip(batch, translate_batch(batch, language)):
            result[source] = translated
    return result


def translate_all(values: list[str]) -> dict[str, dict[str, str]]:
    batches = [
        (language, offset, values[offset : offset + 20])
        for language in LANGUAGES
        for offset in range(0, len(values), 20)
    ]
    result = {language: {} for language in LANGUAGES}
    with ThreadPoolExecutor(max_workers=24) as executor:
        futures = {
            executor.submit(translate_batch, batch, language): (language, batch)
            for language, _, batch in batches
        }
        for future in as_completed(futures):
            language, batch = futures[future]
            try:
                translated = future.result()
            except Exception as error:  # pragma: no cover - network is optional
                print(f"warning: {language} translation batch failed: {error}", file=sys.stderr)
                translated = batch
            result[language].update(zip(batch, translated))
    return result


def catalog(values: dict[str, str], translated: dict[str, dict[str, str]]) -> dict:
    strings = {}
    for key, source in values.items():
        localizations = {
            "en": {"stringUnit": {"state": "translated", "value": key}}
        }
        for language in LANGUAGES:
            localizations[language] = {
                "stringUnit": {
                    "state": "needs_review",
                    "value": translated[language].get(key, key),
                }
            }
        strings[key] = {
            "comment": f"UI copy extracted from {source}; preserve Voxglass brand names and placeholders.",
            "localizations": localizations,
        }
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def main() -> None:
    output = ROOT / "Voxglass/Resources/Localizable.xcstrings"
    values = extract()
    if not values:
        raise SystemExit("no user-facing Swift literals found")
    print(f"extracting {len(values)} source strings")
    translated = translate_all(list(values))
    output.write_text(json.dumps(catalog(values, translated), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {output} with {len(values)} keys and {len(LANGUAGES)} reviewable translations")

    shortcuts = ROOT / "Voxglass/Resources/AppShortcuts.xcstrings"
    if shortcuts.is_file():
        payload = json.loads(shortcuts.read_text(encoding="utf-8"))
        for key, entry in payload.get("strings", {}).items():
            localizations = entry.setdefault("localizations", {})
            localizations.setdefault("en", {"stringUnit": {"state": "translated", "value": key}})
            for language in LANGUAGES:
                localizations.setdefault(
                    language,
                    {"stringUnit": {"state": "needs_review", "value": key}},
                )
        shortcuts.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"completed AppShortcuts.xcstrings for {len(payload.get('strings', {}))} phrases")

    core_catalog = ROOT / "Voxglass/Core/Resources/Localizable.xcstrings"
    if core_catalog.is_file():
        payload = json.loads(core_catalog.read_text(encoding="utf-8"))
        for key, entry in payload.get("strings", {}).items():
            localizations = entry.setdefault("localizations", {})
            localizations.setdefault("en", {"stringUnit": {"state": "translated", "value": key}})
            for language in LANGUAGES:
                localizations.setdefault(
                    language,
                    {"stringUnit": {"state": "needs_review", "value": key}},
                )
        core_catalog.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"completed Core Localizable.xcstrings for {len(payload.get('strings', {}))} keys")


if __name__ == "__main__":
    main()
