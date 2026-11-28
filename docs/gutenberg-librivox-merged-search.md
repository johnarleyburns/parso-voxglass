# Merging LibriVox and Gutenberg “Read with AI” search results

## Goal

Find should behave like one catalog: a user searching “Frankenstein” should see the best
human-narrated audiobook first, with the Read with AI edition available as an alternate. But a
tight Gutenberg match must not disappear under a loose LibriVox match just because LibriVox is
human-voiced.

The ranking contract is therefore:

1. Prefer a human-narrated LibriVox recording when it is a **credible match** for the query/work.
2. Prefer a materially tighter Gutenberg match when LibriVox only has loose subject/description
   matches.
3. Always keep a Gutenberg result when no credible LibriVox equivalent exists.
4. Group duplicate recordings/editions instead of showing every volume as a separate search hit.

## Current building blocks

- `FindSourceFilter` is exclusive today: `.librivox`, `.collections`, `.gutenberg`.
- LibriVox results are `InternetArchiveSearchResult` values from `CatalogStore.searchLibriVox`:
  title, creators, languages, subjects, downloads, narrators, `narrationKind`, `sourceKind`,
  `isStrictLibriVoxCatalogCandidate`, and the Internet Archive identifier.
- Gutenberg results are `GutenbergBook` values from the local mirror index: title, authors,
  languages, subjects, and a deterministic mirror EPUB/cover URL.
- `FindSearchLifecycle` already separates the draft from the submitted query; `DiscoverView`
  already cancels stale searches with task IDs.
- The Gutenberg index now folds searchable fields once and applies a preferred-language boost.

## Recommended UX

Add a combined `.all` source (or make it the default while retaining the three source filters).
Use **one ranked list with source badges**, not two disconnected sections:

```text
Frankenstein
Mary Shelley
LIBRIVOX · READ BY …                    [human badge]
Also available: 3 LibriVox recordings · Read with AI

Frankenstein; or, The Modern Prometheus
Mary Shelley
READ WITH AI                           [AI badge]
```

Grouping is important: LibriVox often has several versions of the same work, and Gutenberg often
has several editions or volumes. A search for “War and Peace” should not be dominated by five
LibriVox volume records plus fifty Gutenberg volumes.

## Pipeline

### 1. Run both sources concurrently

- Start the local mirror search immediately.
- Start the LibriVox search in parallel.
- Render mirror results as soon as they are ready; append LibriVox results when the network
  returns. A LibriVox timeout must leave the Gutenberg results visible.
- Cancel both when the query changes; keep the existing search-generation/task-ID guard.

### 2. Normalize each candidate

Create a source-neutral candidate:

```text
titleCore          title without leading article, subtitle, volume marker, or edition words
authorKey          primary author surname + first initial (when present)
tokens             folded title/author/subject tokens
relevance          0…100 query/work relevance
isTight            all query tokens in the title, or an exact author match
languageCodes      normalized ISO-639-1/2 codes
source             .libriVox(recording) or .readByAI(gutenbergBook)
```

Normalization examples:

- “Frankenstein; or, The Modern Prometheus” and “Frankenstein, ou le Prométhée moderne” share the
  work key `frankenstein + shelley`.
- “War and Peace, Book 01: 1805” and “War and Peace Vol. 1” share `war and peace + tolstoy` and are
  merged as volumes of one work.
- “The Law” must not merge Bastiat’s work with an unrelated law anthology; require a credible
  author match before merging an ambiguous title.

### 3. Score relevance before applying source preference

Suggested relevance bands (tune with fixtures, not ad-hoc source bonuses):

| Band | Match |
| ---: | --- |
| 100 | exact title core + author |
| 90 | exact title core |
| 80 | title starts with the complete query |
| 70 | every query token appears in the title |
| 60 | exact author |
| 50 | subject / bookshelf / description match only |

Source preference is a **tie-break inside a relevance band**, not a large additive score. A large
fixed LibriVox bonus would reproduce the failure mode we measured: searching “Gothic Architecture”
returns three loose LibriVox subject matches (“The Stones of Venice”) while Gutenberg has five tight
title matches.

### 4. Cluster by work, then choose the primary

For each work cluster:

- Pick the best LibriVox candidate and the best Gutenberg candidate.
- If only one source has a candidate, use it.
- If both are tight, choose LibriVox (human preference).
- If LibriVox is loose and Gutenberg is tight, choose Gutenberg.
- If both are loose, choose the higher relevance; LibriVox wins ties.
- If relevance differs by more than a small margin (for example 10–15 points), prefer the
  materially tighter result even if LibriVox is human-voiced.

This directly expresses the product rule: human preference is strong, but not stronger than
relevance when the content only or primarily exists as text.

### 5. Keep alternates

The primary row opens the best edition. A secondary “Also available” row/disclosure lists:

- other LibriVox recordings (sorted by downloads/completeness, with version labels),
- the Read with AI EPUB,
- other Gutenberg editions/volumes when their titles differ.

Alternates should not consume top-level search slots unless the user expands them.

### 6. Language preference

Apply the same language-code normalization and preferred-language boost now used by the Gutenberg
index. Do not hard-filter: a French-only result must remain visible to an English-preferring user
when it is the only/tightest match. When LibriVox has multiple language editions of the same work,
prefer the selected language for the primary recording and list the others as alternates.

## Research evidence from the live catalogs

Sampled against the live mirror index and the LibriVox collection on Internet Archive:

| Query | Gutenberg | LibriVox | Merge behavior |
| --- | ---: | ---: | --- |
| Frankenstein | 6 | multiple English + Spanish recordings | Human first, editions grouped |
| Sherlock Holmes | 40 | many recordings, several versions | Human canonical first, AI alternate |
| Pride and Prejudice | 3 | 5+ recordings | Human first |
| Kalevala | 20 | 2 English translations | Human first |
| War and Peace | 50 | many volumes | Group volumes under one work |
| Les Misérables | 1+ | English and French volumes | Language preference chooses primary |
| Gothic Architecture | tight title matches | 3 loose “Stones of Venice” matches | Gutenberg tight result first |
| Tolstoy on Art | tight Gutenberg result | 0 | Gutenberg only |
| Dickens’s Children | tight Gutenberg result | 0 | Gutenberg only |
| Bibliography of D. H. Lawrence | tight Gutenberg result | 0 | Gutenberg only |

These examples define the regression fixtures for the ranker.

## API shape

Keep ranking pure and testable, separate from networking and SwiftUI:

```swift
struct MergedSearchRanker {
    func rank(
        query: String,
        libriVox: [InternetArchiveSearchResult],
        gutenberg: [GutenbergBook],
        selectedLanguages: Set<String>
    ) -> [MergedSearchResult]
}

struct MergedSearchResult: Identifiable {
    enum Primary { case libriVox(InternetArchiveSearchResult), readByAI(GutenbergBook) }
    let primary: Primary
    let alternates: [Primary]
    let workKey: WorkKey
}
```

Implementation location: `Voxglass/Core/Catalog/` for the pure ranker, with the UI in
`DiscoverView`. Avoid putting merge logic in a SwiftUI view so it can be exercised without a
simulator.

## Tests

- Both sources have a tight match → LibriVox primary.
- Gutenberg is tight and LibriVox is only a subject/description match → Gutenberg primary.
- Gutenberg-only work → Gutenberg primary.
- LibriVox-only work → LibriVox primary.
- Same title, different author → not merged.
- Multi-volume/version works → one primary, alternates retained.
- Duplicate LibriVox versions → highest-downloads/completeness primary.
- Selected-language recording → primary; other-language recording → alternate.
- LibriVox network failure/timeout → Gutenberg results still render.
- Query change/cancellation → no stale merged result replaces the current one.
- “Gothic Architecture”, “Tolstoy on Art”, “Frankenstein”, “War and Peace”, and “The Law” become
  named fixtures.

## Rollout

1. Add the combined source and result model behind a feature flag; keep existing filters.
2. Ship progressive rendering (mirror first, LibriVox appended) and grouping.
3. Enable the merge ranker after fixture relevance is stable; keep an “All / LibriVox / Read with AI”
   filter for users who want one source.
4. Measure: top-1 relevance, duplicate rate, human-first rate when both are tight, Gutenberg-only
   coverage, and search latency. A fast local mirror plus one LibriVox request should remain well
   below the current 8-second interactive timeout in the normal case.
