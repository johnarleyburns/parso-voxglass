# Codex Handoff: Great Books ↔ LibriVox ↔ Internet Archive Audit

## Objective
Continue and complete an authoritative spreadsheet audit of the **Great Books of the Western World, 1990 second edition** against the **official LibriVox catalog** and the **Internet Archive**.

The output must identify every completed LibriVox recording/version for each Great Books entry, preserve separate versions/translations/readings as separate rows, and calculate coverage without double counting multiple versions.

## Starting file
Use this workbook as the source of truth:

`great_books_librivox_batch_10_completed_through_row13.xlsx`

Place it in the Codex working directory before starting.

## Current checkpoint
Completed underlying Great Books rows:

- Row 2: Homer — The Iliad
- Row 3: Homer — The Odyssey
- Rows 4–13: Aeschylus through Hippocrates

Resume at:

- **Underlying work row 14 — Galen, On the Natural Faculties**

Process **10 underlying Great Books rows per batch**. After every batch:

1. Save a new versioned workbook.
2. Update the `Research Progress` sheet.
3. Report the last completed underlying row and next resume row.
4. Do not overwrite the previous batch file.

Suggested output naming:

`great_books_librivox_completed_through_rowNN.xlsx`

## Mandatory research method
Do not use guessed identifiers or infer Internet Archive identifiers from naming patterns.

For each underlying Great Books work:

1. Search the web for the official LibriVox catalog page using title and author.
2. Restrict authoritative recording evidence to pages on `librivox.org`.
3. Open each matching official LibriVox catalog page.
4. Follow the catalog page's official Internet Archive link.
5. Extract the exact IA identifier from the final Archive URL:
   `https://archive.org/details/<IA_IDENTIFIER>`
6. Record the exact LibriVox URL, exact IA URL, and exact IA identifier.
7. Search for alternate versions, translations, solo readings, collaborative readings, and dramatic readings.
8. Continue until reasonable title/author/version searches produce no additional completed LibriVox recordings.

Never treat Google snippets, generated slugs, search-engine snippets, Wikipedia, or IA naming conventions as sufficient verification.

## Version handling
Create **one row per distinct completed LibriVox recording/version** in the `Recording Versions` sheet.

Examples of distinct versions:

- Different translation
- Different solo reader
- Solo versus collaborative reading
- Dramatic reading versus ordinary reading
- LibriVox “Version 2,” “Version 3,” etc.
- A complete multipart recording split across multiple LibriVox projects

For multipart projects:

- Use one row per official LibriVox project/volume.
- Mark the first part `Yes` for coverage only when it establishes coverage.
- Mark continuation volumes `No — continuation`.

## Corpus-entry handling
Some Great Books rows are broad entries such as:

- Plays
- Dialogues
- Works
- Essays

For these:

1. Search the actual constituent works included in the Great Books entry.
2. Add one recording row per verified constituent recording/version.
3. Use `Match class = Exact constituent`.
4. Count the underlying Great Books corpus row as covered once if at least one required constituent work has an exact LibriVox recording.
5. Do not count every constituent or version as a separate covered Great Books work.
6. Add notes explaining which constituent work established coverage.

Where the Great Books entry requires a specific subset, do not substitute an unrelated work by the same author as exact coverage.

## Same-author fallback handling
If no exact recording exists for an underlying Great Books work:

1. Search for completed LibriVox recordings by the same author.
2. List useful same-author fallback recordings separately.
3. Set `Match class = Same-author fallback`.
4. Set `Counts toward work coverage? = No`.
5. Same-author fallback must not increase exact-work coverage.
6. A work can be counted in the fallback metric only if it has no exact recording.

## No-match handling
If no exact recording is found after reasonable searches:

- Add a row stating `No exact completed recording located`.
- Leave IA identifier and IA URL blank.
- Set `Match class = No exact match`.
- Set `Counts toward work coverage? = No`.
- State the searches performed in the research note.

Do not use `NA` for a work until the official LibriVox catalog and reasonable alternate-title searches have been checked.

## Spreadsheet structure
Preserve existing sheets and formatting.

### `Audited Matches`
One row per underlying Great Books entry.

Update at least:

- IA identifier field
- status field
- IA URL field
- notes field

If multiple versions exist, the IA identifier field may contain a semicolon-separated summary, but the authoritative detailed list belongs in `Recording Versions`.

### `Recording Versions`
One row per distinct recording/project/version.

Required columns:

1. Great Books work
2. Author
3. Underlying work row
4. Recording version
5. Translation / edition
6. Reader type
7. Catalog date
8. LibriVox catalog URL
9. IA identifier
10. IA URL
11. Match class
12. Counts toward work coverage?
13. Verification status
14. Research note

Use these coverage values consistently:

- `Yes`
- `No — duplicate version`
- `No — duplicate corpus`
- `No — continuation`
- `No`

Use verification status such as:

- `Verified official LibriVox → IA`
- `Verified official LibriVox catalog; IA link followed`
- `Official catalog searched; no exact completed recording found`

Do not write `verified` unless the official catalog page and its published IA link were actually opened.

### `Research Progress`
Update:

- Requested batch
- Completed underlying rows
- Last completed work
- Next underlying work
- Number of version rows added
- Any unresolved ambiguity
- Date of research

## Coverage counting rules
Coverage must be calculated from distinct underlying Great Books works, not recording rows.

### Exact-work coverage
Numerator:

Number of distinct underlying Great Books entries with at least one exact recording, exact constituent recording, or complete multipart recording.

Denominator:

Total number of underlying Great Books entries.

A work with 12 LibriVox versions contributes **1**, not 12.

### Same-author fallback coverage
Numerator:

Number of distinct underlying Great Books entries with no exact recording but at least one verified same-author fallback.

Do not count a work in both exact coverage and fallback coverage.

### Author coverage
Numerator:

Number of distinct Great Books authors with at least one verified LibriVox recording.

Multiple works or versions by one author count once.

## Duplicate detection
Before inserting a recording row, check for duplicates using at least:

- IA identifier
- Official LibriVox URL
- Underlying work row

The IA identifier is the strongest unique key.

Do not add the same LibriVox project twice merely because it appears under alternate search results.

## Research quality rules
- Prefer official LibriVox catalog pages over wiki pages.
- The LibriVox wiki may be used to discover titles, but not as final IA-identifier verification.
- Do not invent catalog dates, translators, readers, or identifiers.
- If a field cannot be verified, leave it blank and explain why.
- Distinguish publication date of the ancient/original work from LibriVox catalog date.
- Preserve non-English recordings only if they are relevant to the requested coverage definition; otherwise note them separately.
- Include only completed LibriVox projects, not “in progress” forum projects.

## Web-search approach
Useful searches include:

- `site:librivox.org "TITLE" "AUTHOR"`
- `site:librivox.org TITLE AUTHOR LibriVox`
- `site:librivox.org "TITLE" "Version 2"`
- `site:librivox.org AUTHOR translation TITLE`
- `site:librivox.org "alternate title" AUTHOR`

Also search common alternate English titles and translated titles.

For broad corpus entries, first identify the constituent works represented in the Great Books edition, then search each constituent title.

## Rate limiting and politeness
Use ordinary web searches and page loads at a conservative pace.

- No more than one new search/page request per second.
- Add a delay between requests when automating browser actions.
- Cache fetched pages locally during the run to avoid repeated requests.

## Batch workflow
For each 10-work batch:

1. Load the latest workbook.
2. Read the next 10 underlying rows from `Audited Matches`.
3. Research each work fully.
4. Add all verified recordings to `Recording Versions`.
5. Update each corresponding `Audited Matches` row.
6. Update `Research Progress`.
7. Recalculate work-level and author-level coverage summaries.
8. Validate formulas and workbook integrity.
9. Save to a new filename.
10. Produce a concise batch report.

## Validation checklist before saving
- No duplicate IA identifiers.
- No guessed IA identifiers.
- Every populated IA identifier has a matching IA URL.
- Every verified version has an official LibriVox catalog URL.
- Multiple versions do not inflate exact-work coverage.
- Multipart continuations do not inflate coverage.
- Same-author fallbacks do not count as exact coverage.
- No spreadsheet errors such as `#REF!`, `#DIV/0!`, `#VALUE!`, or `#NAME?`.
- Existing workbook sheets and prior research remain intact.
- The next resume row is explicit.

## Immediate task
Start with the next batch:

- Rows 14–23 inclusive
- Beginning with Galen — `On the Natural Faculties`

Research all ten underlying entries, list every verified completed LibriVox version, update the workbook, recalculate coverage correctly, and save as:

`great_books_librivox_completed_through_row23.xlsx`

At completion, report:

- Underlying rows completed
- Number of version rows added
- Exact matches
- Same-author fallbacks
- No-match entries
- Corrections to prior data, if any
- Next resume row
