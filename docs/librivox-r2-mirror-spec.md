# LibriVox → Cloudflare R2 mirror — size and design spec

Status: planning. No LibriVox audio has been mirrored.

## Measured catalog size

From the Internet Archive `collection:librivoxaudio` scrape and item metadata on
2026-11-20:

| Metric | Value |
| --- | ---: |
| LibriVox items | **21,963** |
| Recorded runtime | **~128,934 hours** |
| Average runtime | ~5.9 hours/book |
| Total `item_size` in IA (all files) | **28.4 TB** |
| Average IA item size | ~1.29 GB/book |

`item_size` includes redundant formats: 64 kbps MP3, 128 kbps MP3, VBR MP3, Ogg Vorbis,
M4B, ZIPs, spectrograms, OCR, covers, and metadata.

## What to mirror

Mirror **64 kbps MP3 section files + covers + catalog metadata** only.

| Variant | Est. audio size |
| --- | ---: |
| 64 kbps MP3 | **~3.7 TB** |
| 128 kbps MP3 | ~7.4 TB |
| 64 + 128 kbps | ~11.1 TB |
| Full IA `item_size` | ~28.4 TB |

At 64 kbps, one hour is ~28.8 MB; 128,934 hours ≈ 3.71 TB. Covers and metadata add
roughly 0.5–1 GB. Expect roughly **300k–450k section MP3 objects** plus covers.

The current iPhone app streams from Internet Archive; the mirror should expose the same
64 kbps section files rather than ZIPs so playback stays range-friendly.

## R2 cost

R2 Standard: `$0.015/GB-month`, 10 GB free, egress free.

| Mirror | Storage/month |
| --- | ---: |
| 64 kbps MP3 + covers/metadata | **~$55–$57** |
| 128 kbps MP3 | ~$111 |
| 64 + 128 kbps | ~$166 |
| Full IA item set | ~$426 |

Class A/B operations are not the main cost. Initial upload is under the 1M free Class A
tier at ~300k–450k objects. Streaming requests are large (typically 5–30 MB per
section), so 1 TB/month is only ~50k–200k Class B reads; 10M are free.

R2 Infrequent Access is cheaper per GB (`$0.01`) but adds `$0.01/GB` retrieval. For
audio users actually stream, Standard is usually the better fit.

## Architecture

```text
IA scrape: collection:librivoxaudio
        │  identifier, runtime, item_size
        ▼
batch worker (VPS/container)
        │  GET archive.org/metadata/<id>
        │  select *_64kb.mp3 + cover
        ▼
local staging (one book or a few books)
        │  PUT to R2 librivox/books/<id>/...
        ▼
R2 public custom domain
        │
        ▼
app streams sections; local catalog index searches metadata
```

### Why not a Worker-only mirror

Workers have no persistent disk or `rsync`, and Cloudflare request/CPU limits make a
one-time 3.7 TB / ~400k-object ingest impractical. LibriVox files are HTTP, so a Worker
*could* fetch a few new files and PUT them via an R2 binding, but a batch server is the
right tool for the initial ingest and for retries. A Worker is still useful later for
search/auth/signing if needed.

### Batch sizing

Average 64 kbps book is ~170 MB. On the existing IONOS VPS (~2.1 GB free), process
**one book at a time** or a very small batch:

1. fetch IA metadata;
2. download only `*_64kb.mp3` and a cover;
3. upload with `rclone move` to `librivox/books/<id>/`;
4. delete the local book;
5. record the ID in `uploaded-ids`.

Initial ingest is bandwidth-bound: 3.7 TB is ~8.5 hours at a theoretical 1 Gbps but
likely days on a small VPS/IA origin. Daily incremental work is small (LibriVox adds a
few books per day); a persistent VPS is adequate after the initial backfill. A temporary
higher-bandwidth worker or a few parallel backfill workers may be preferable for the
first pass.

### Search

Build a compact LibriVox metadata index from the API/IA catalog (title, authors,
language, genres, description, runtime, section list). Serve it as a versioned JSON
index + manifest, analogous to the Gutenberg index. The app downloads it and searches
locally; audio stays on R2. This avoids a runtime dependency on IA/LibriVox search.

### R2 layout

```text
voxglass-librivox/                # public read-only bucket; LibriVox data only
└── librivox/
    ├── books/<id>/
    │   ├── <section>_64kb.mp3
    │   ├── ...
    │   └── cover.jpg
    └── catalog/
        ├── manifest.json
        └── index-<sha>.json.zlib
```

## Legal and attribution

LibriVox recordings are generally public domain, but keep the LibriVox attribution and
each recording's metadata. Some items include music, cover art, or text with separate
terms; check the IA item metadata and LibriVox terms. Do not mirror non-public files or
strip attribution.

## Recommendation

Mirror **64 kbps MP3 only** first. That is about **3.7 TB** and roughly
**$55–$57/month** in R2 Standard storage, with free egress. Add 128 kbps only if the app
needs it; mirroring the full IA item set (28.4 TB) is not recommended.
