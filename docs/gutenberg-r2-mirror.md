# Project Gutenberg → Cloudflare R2 mirror

This document covers the operator tooling, bucket layout, permissions, costs, and app-integration
plan for mirroring the useful Project Gutenberg subset to Cloudflare R2.

The implementation lives in [`scripts/gutenberg-mirror.sh`](../scripts/gutenberg-mirror.sh).

> **Current state:** the `voxglass-gutenberg` bucket is live at `https://gutenberg.parso.guru`.
> A nightly systemd timer (`04:15` local, randomized ±1h) runs `--once` on the VPS. The mirror
> contains all catalogued no-images EPUBs and medium covers, and the app searches the mirror index
> locally. See [Upstream revisions and refresh](#upstream-revisions-and-refresh) and
> [Update integrity](#update-integrity) for the guarantees added in this revision.

## What is mirrored

The default mirrors every `Text` record in `pg_catalog.csv`, in every language, using the
no-images EPUB plus its medium cover. It is deliberately smaller than an all-format Gutenberg
mirror because audio, MOBI, HTML, RDF, and illustrated EPUB variants are excluded.

| Content | Source path | R2 object |
| --- | --- | --- |
| No-images EPUB | `<id>/pg<id>.epub` | `gutenberg/books/<id>/pg<id>.epub` |
| Medium cover (optional, default on) | `<id>/pg<id>.cover.medium.jpg` | `gutenberg/books/<id>/pg<id>.cover.medium.jpg` |
| Full Gutenberg index | `GUTINDEX.ALL` | `gutenberg/catalog/GUTINDEX.ALL` |
| Catalog CSV (when reachable) | `feeds/pg_catalog.csv` | `gutenberg/catalog/pg_catalog.csv` |
| On-device search index | generated from `pg_catalog.csv` | `gutenberg/catalog/index-<sha>.json.zlib` |
| Search index manifest | generated from `pg_catalog.csv` | `gutenberg/catalog/manifest.json` |
| Illustrated EPUBs (opt-in) | `<id>/pg<id>-images*.epub` | `gutenberg/books/<id>/pg<id>-images*.epub` |

Logs, MOBI, ZIP, HTML, audio, RDF, and QR codes are **not** mirrored by default. Illustrated EPUBs
are excluded unless `--illustrated` / `GUTENBERG_INCLUDE_ILLUSTRATED=1` is used.

`books/<id>/` preserves the upstream directory layout, which keeps the rsync staging tree and the R2
prefix directly comparable. A book URL is deterministic:

```text
https://<r2-custom-domain>/gutenberg/books/84/pg84.epub
https://<r2-custom-domain>/gutenberg/books/84/pg84.cover.medium.jpg
```

## Bucket layout

```text
voxglass-gutenberg/                    # public read-only bucket; Gutenberg data only
└── gutenberg/
    ├── books/
    │   ├── 1/pg1.epub
    │   ├── 1/pg1.cover.medium.jpg
    │   └── ...
    └── catalog/
        ├── GUTINDEX.ALL
        ├── pg_catalog.csv            # best-effort; rsynced when gutenberg.org is in maintenance
        ├── index-<sha>.json.zlib       # compact on-device search index
        └── manifest.json             # index version + sha256 + byte count
```

Do **not** publish the bucket’s S3 endpoint. Publish only the custom domain, and only if it is mapped
to `voxglass-gutenberg`. Never expose or reuse `crm-backups` for public book data.

## Required Cloudflare permissions

Creating the bucket needs an **account-scoped** token:

- **Account → R2 Storage → Edit**
  (Dashboard: My Profile → API Tokens → Create Token → Account API token → R2 Storage → Edit), or
  Account Super Administrator.
- An **Account → R2 Storage → Read** token can list buckets but cannot create them.

A bucket-scoped R2 API token cannot create the bucket. Create the bucket once from the dashboard or
with an account token, then create an **R2 API token** scoped to `voxglass-gutenberg` with
**Object Read & Write** for the mirror itself.

Exact failure observed with the currently available token:

```http
POST https://api.cloudflare.com/client/v4/accounts/c589b687de910faa1e453b0c1afb4f8c/r2/buckets
{"name":"voxglass-gutenberg","locationHint":"enam"}
```

```json
{
  "result": null,
  "success": false,
  "errors": [
    { "code": 10000, "message": "Authentication error" }
  ]
}
```

The existing S3 access key is likewise not usable: `rclone lsd` returns:

```text
operation error S3: ListBuckets, https response error StatusCode: 403,
api error AccessDenied: Access Denied
```

That key is scoped to `crm-backups`; do not use that bucket for Gutenberg data.

Once the permission is fixed, create the bucket and a bucket-scoped key:

```sh
# Option A: dashboard is simplest.
# Option B: with an account token that has R2 Storage:Edit:
curl -sS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$R2_ACCOUNT_ID/r2/buckets" \
  -H "Authorization: Bearer $(cat ~/.cloudflare-api-token)" \
  -H "Content-Type: application/json" \
  --data '{"name":"voxglass-gutenberg","locationHint":"enam"}'
```

Then save the new bucket-scoped S3 credentials. Prefer a dedicated environment file
so you do not overwrite `~/.r2-access-key-id` / `~/.r2-secret-access-key` if another
project (for example `crm-backups`) already uses them:

```sh
install -d -m 700 ~/.config
umask 077
cat > ~/.config/voxglass-gutenberg.env <<'EOF'
R2_ACCOUNT_ID=c589b687de910faa1e453b0c1afb4f8c
R2_BUCKET=voxglass-gutenberg
R2_PREFIX=gutenberg
R2_ACCESS_KEY_ID=<new bucket-scoped access key id>
R2_SECRET_ACCESS_KEY=<new bucket-scoped secret access key>
EOF
chmod 600 ~/.config/voxglass-gutenberg.env
```

Load it before running the mirror:

```sh
set -a
. ~/.config/voxglass-gutenberg.env
set +a
scripts/gutenberg-mirror.sh --verify
```

If this host uses `~/.r2-*` only for this bucket, you may instead replace those files
with the new key. Never commit either file.

Recommended bucket settings:

- Keep the bucket **private**. Public access is via an R2 custom domain, not the S3 endpoint.
- Add a custom domain such as `gutenberg.example.com`; do not use an `r2.dev` URL in production.
- Optionally set a lifecycle rule for incomplete multipart uploads (EPUBs are small, so this is
  mostly hygiene).
- Add cache headers at upload or via a Worker. Book objects are effectively immutable by ID, but
  Gutenberg does revise files; a 7–30 day cache is a reasonable compromise.

## Quick start

```sh
# From the repository root.
scripts/gutenberg-mirror.sh --dry-run --only-ids 84 --no-catalog   # safe smoke test
scripts/gutenberg-mirror.sh --once                                  # one full cycle, foreground
scripts/gutenberg-mirror.sh --once --refresh-all                    # one-time full-corpus audit
scripts/gutenberg-mirror.sh                                         # start background daily loop
scripts/gutenberg-mirror.sh --status
scripts/gutenberg-mirror.sh --verify
scripts/gutenberg-mirror.sh --stop
scripts/gutenberg-mirror.sh --resume                                # continue now, one cycle
```

The first full cycle lists every Gutenberg book directory (about 80k) and downloads the no-images
EPUBs. It is intentionally resumable; see below.

### Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `R2_ACCOUNT_ID` | `c589b687de910faa1e453b0c1afb4f8c` | Cloudflare account |
| `R2_BUCKET` | `voxglass-gutenberg` | Target bucket |
| `R2_PREFIX` | `gutenberg` | Object prefix |
| `R2_ACCESS_KEY_ID` | env, then `~/.r2-access-key-id` | R2 S3 access key |
| `R2_SECRET_ACCESS_KEY` | env, then `~/.r2-secret-access-key` | R2 S3 secret |

Environment variables win over the `~/.r2-*` fallback files. On a shared host, put the
Gutenberg key in `~/.config/voxglass-gutenberg.env` and source it instead of replacing
keys used by another bucket.
| `R2_ENDPOINT` | `https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com` | S3 endpoint override |
| `GUTENBERG_RSYNC_SOURCE` | `aleph.gutenberg.org::gutenberg-epub` | EPUB/covers rsync module |
| `GUTENBERG_CATALOG_RSYNC_SOURCE` | `aleph.gutenberg.org::gutenberg` | `GUTINDEX.ALL` rsync module |
| `GUTENBERG_CATALOG_URL` | `https://www.gutenberg.org/feeds/pg_catalog.csv` | CSV HTTP source |
| `GUTENBERG_CATALOG_CSV_RSYNC_SOURCE` | `aleph.gutenberg.org::gutenberg-epub/feeds/pg_catalog.csv` | CSV rsync fallback |
| `GUTENBERG_BUILD_INDEX` | `1` | Build the on-device search index |
| `GUTENBERG_INDEX_SCRIPT` | `scripts/build-gutenberg-index.py` | Index builder |
| `GUTENBERG_INDEX_LANGUAGE` | `all` | Index language, or `all` for every Gutenberg language |
| `GUTENBERG_REFRESH_SCRIPT` | `scripts/gutenberg-refresh-plan.py` | New/changed/rotating-refresh planner |
| `GUTENBERG_REFRESH_BATCH_SIZE` | `500` | Already-mirrored IDs re-fetched per cycle; `0` disables rotation |
| `GUTENBERG_REFRESH_ALL` | `0` | Queue every catalog ID once (migration/audit) |
| `GUTENBERG_UPSTREAM_CHECK` | `1` | Compare an upstream `rsync --list-only` snapshot each cycle |
| `GUTENBERG_BATCH_SIZE` | `500` | Books per local upload batch; `0` = full tree |
| `GUTENBERG_UPLOADED_IDS_FILE` | `state/uploaded-ids` | Completed-ID progress file |
| `GUTENBERG_UPSTREAM_SNAPSHOT` | `state/upstream-files` | Last committed upstream size/mtime snapshot |
| `GUTENBERG_REFRESH_CURSOR` | `state/refresh-cursor` | Rotating-refresh cursor |
| `GUTENBERG_STAGING_DIR` | `~/.cache/voxglass/gutenberg` | Local staging |
| `GUTENBERG_STATE_DIR` | `~/.local/state/voxglass-gutenberg-mirror` | PID/lock/state/log |
| `GUTENBERG_INTERVAL` | `86400` | Seconds between loop cycles |
| `GUTENBERG_ONLY_IDS` | empty | Test/single-book subset |
| `GUTENBERG_INCLUDE_COVERS` | `1` | Mirror medium covers |
| `GUTENBERG_INCLUDE_ILLUSTRATED` | `0` | Mirror `pg<id>-images*.epub` |
| `GUTENBERG_PRUNE` | `0` | Pass `--delete` to rsync |
| `GUTENBERG_SKIP_CATALOG` | `0` | Skip index/CSV (quick tests) |
| `GUTENBERG_TRANSFERS` | `8` | rclone transfers |
| `GUTENBERG_CHECKERS` | `16` | rclone checkers |
| `RCLONE_BIN` | auto (`rclone`, `~/.local/bin/rclone`) | rclone executable |

Secrets are written only to a mode-`600` rclone config inside the state directory and are never
printed. Do not commit the state directory, staging directory, or rclone config.

## Batching (bounded local disk)

By default the mirror no longer accumulates the whole corpus on the laptop. It processes
`GUTENBERG_BATCH_SIZE` books at a time (default **500**, roughly 150–200 MB):

1. `rsync` fetches only that batch’s `pg<id>.epub` / cover files.
2. `rclone move` uploads them and deletes the local copies after a successful transfer.
3. The completed IDs are recorded in `$GUTENBERG_STATE_DIR/uploaded-ids`.
4. The next batch repeats; a stopped run resumes at the next uncompleted batch.

```sh
scripts/gutenberg-mirror.sh --batch-size 300   # lower local peak
scripts/gutenberg-mirror.sh --no-batch         # legacy full-tree mode (~20 GB local)
```

Batch mode needs `pg_catalog.csv` to enumerate IDs. If the catalog is unavailable, the script
stops rather than silently falling back to a full local tree. `--verify` reports remote-only
statistics in batch mode because local staging intentionally contains only the current batch.

`--prune` remains a full-tree/rsync option; batch mode does not delete remote objects that
disappeared upstream.

## Upstream revisions and refresh

Batch mode used to treat `uploaded-ids` as permanent, so a revised EPUB or cover for an existing ID
was never re-fetched. Each batch cycle now does three things:

1. **New IDs:** every catalog `Text#` missing from `uploaded-ids` is queued.
2. **Changed IDs:** one read-only `rsync --list-only -r` listing captures upstream size and mtime
   for every selected EPUB/cover (~18 MB and about 90 seconds for the full catalog; no book data
   is downloaded). `gutenberg-refresh-plan.py` compares it with the previous snapshot and queues
   any ID whose file signature changed. The snapshot is committed only after the queue uploads
   successfully, so a crash re-plans the same work.
3. **Rotating audit:** `GUTENBERG_REFRESH_BATCH_SIZE` (default `500`) already-mirrored IDs are
   re-fetched each cycle, wrapping at the end of the catalog. At the default rate the complete
   corpus is audited roughly twice a year. This catches the rare revision that preserves both size
   and mtime.

The first run with no prior snapshot establishes a baseline without re-downloading the corpus.
For a one-time migration/audit of an existing mirror, run `--refresh-all`; that queues every
catalog ID once. Use `--no-refresh` to disable both change detection and the rotating audit.

Batch mode still does not delete remote objects that disappeared upstream. `--status` reports the
number of removed IDs found during the latest snapshot comparison, but pruning remains an explicit
full-tree operation.

## Update integrity

Publishing a catalog is ordered so the app can never observe a torn update:

1. Books upload through `rclone move`; S3 PUTs are atomic, so a concurrent reader gets either the
   old complete EPUB/cover or the new complete object.
2. If any book batch or index build fails, the cycle does **not** publish a new catalog manifest.
   The previous manifest/index pair stays live.
3. The immutable, content-addressed `index-<sha>.json.zlib` uploads first. The small
   `manifest.json` uploads last, after every index object exists. A client therefore sees either
   the old pair or the new pair, never a manifest pointing at a missing index.
4. The app verifies the downloaded index's byte count and SHA-256 before replacing its in-memory
   snapshot, writes the index and manifest with atomic renames, and re-verifies the pair when
   loading from disk. A corrupt or mismatched local pair is discarded and repaired on the next
   refresh; search never uses a partially written index.

## Start / stop / resume semantics

- `start` (or no arguments) launches `nohup … --loop` in the background and writes its PID to
  `$GUTENBERG_STATE_DIR/pid`. A `flock` on `$GUTENBERG_STATE_DIR/lock` enforces one active runner.
- `--loop` runs in the foreground, which is what systemd/tmux should use. It runs a cycle, sleeps
  `GUTENBERG_INTERVAL`, and repeats. A failed cycle (for example a missing bucket) is logged and
  retried after the interval; it does not abort the loop.
- `--stop` verifies the PID belongs to this script, sends `SIGTERM`, waits up to 15 seconds, then
  sends `SIGKILL` if necessary. The signal handler terminates the current rsync/rclone child and
  records a resumable `stopped` state.
- `--resume` runs one cycle now. It does not erase staging, partial files, or remote objects.
- `--once` is a foreground single cycle, suitable for cron/systemd timers.
- `--dry-run` uploads/downloads no book data and writes no R2 objects. It still creates staging
  directories, run state, a log line, and the mode-`600` rclone config, and it contacts R2 for
  rclone’s dry-run, so it fails loudly when the bucket/key is not available.
- `--only-ids 84,1342` restricts the run to specific books. `--no-catalog` skips the index for
  quick tests.
- `--refresh-all` queues every catalog ID once. Use it for the initial migration to snapshot-based
  revision detection or as a full-corpus audit; subsequent cycles return to the rotating batch.
- `--no-refresh` disables upstream change detection and the rotating audit for one run.
- `--prune` adds rsync `--delete` (prunes books removed upstream). It is off by default.
- `--cleanup` removes empty `.rsync-partial` directories and stale catalog temp files.

Why a killed run resumes rather than restarting:

1. rsync is incremental and writes interrupted files into `.rsync-partial/`, which is excluded from
   the rclone upload. The next rsync reuses that partial data.
2. rclone `copy` compares size/modification time and skips objects already in R2.
3. The state file is informational only; there is no “start over” switch to trip.

A stale PID file from a killed process is detected by `--status` and cleared by `--resume`.

### Status and verification

`--status` shows the running PID/phase, local object count and size, the last result, and the last
**verified** remote count/size. `--verify` performs a live `rclone size` and compares local files,
bytes, and remote objects:

```text
Local:  79999 files, 20.1GiB
Remote: 79999 files, 20.1GiB (voxglass-gutenberg/gutenberg)
Result: match
```

For a hash-level check (more expensive, and not appropriate for every nightly run):

```sh
rclone --config "$GUTENBERG_STATE_DIR/rclone.conf" check \
  "$GUTENBERG_STAGING_DIR/books" \
  voxglass-gutenberg:voxglass-gutenberg/gutenberg/books \
  --size-only --one-way
```

`--verify` returns non-zero on a mismatch or when R2 is unavailable.

## Scheduling

### systemd service (continuous loop)

`~/.config/systemd/user/gutenberg-mirror.service`:

```ini
[Unit]
Description=Voxglass Project Gutenberg to R2 mirror
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/github/parso-voxglass
EnvironmentFile=%h/.config/voxglass-gutenberg.env
ExecStart=%h/github/parso-voxglass/scripts/gutenberg-mirror.sh --loop
Restart=on-failure
RestartSec=1h
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=default.target
```

`~/.config/voxglass-gutenberg.env` (mode `600`; use absolute paths for a system service):

```sh
R2_ACCOUNT_ID=c589b687de910faa1e453b0c1afb4f8c
R2_BUCKET=voxglass-gutenberg
R2_PREFIX=gutenberg
GUTENBERG_STAGING_DIR=/var/lib/voxglass/gutenberg
GUTENBERG_STATE_DIR=/var/lib/voxglass/gutenberg-state
GUTENBERG_INTERVAL=86400
# R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY can live here, or use ~/.r2-* files.
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now gutenberg-mirror.service
journalctl --user -u gutenberg-mirror -f
```

For a system-wide unit, create a service user, own the staging/state directories with it, and put
the credentials in a root-owned `0600` `EnvironmentFile`.

### Nightly timer (preferred for a “sync once a night” policy)

Use a `oneshot` service plus a timer instead of `--loop`:

```ini
# gutenberg-mirror.service
[Service]
Type=oneshot
ExecStart=%h/github/parso-voxglass/scripts/gutenberg-mirror.sh --once
```

```ini
# gutenberg-mirror.timer
[Unit]
Description=Nightly Gutenberg mirror

[Timer]
OnCalendar=*-*-* 03:30
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
```

`Persistent=true` runs a missed job after boot. Do not run the timer and the loop at the same time;
the lock will make one skip, but the intent is clearer with a single mechanism.

### tmux

```sh
tmux new-session -d -s gutenberg 'scripts/gutenberg-mirror.sh --loop'
tmux attach -t gutenberg
scripts/gutenberg-mirror.sh --stop
```

### cron

```cron
30 3 * * * cd /home/arley/github/parso-voxglass && \
  ./scripts/gutenberg-mirror.sh --once >> "$HOME/.local/state/voxglass-gutenberg-mirror/cron.log" 2>&1
```

## Deploying to the IONOS VPS

The mirror can run on the existing IONOS VPS (`217.76.158.90`) without putting SSH keys or R2
credentials in this repository. The deploy script streams the local credentials file to
`/etc/voxglass-gutenberg.env` (mode `600`) and installs the scripts plus a systemd oneshot service
and daily timer.

From this workstation, with SSH access already configured:

```sh
scripts/deploy-gutenberg-mirror-vps.sh
```

Defaults:

- host: `root@217.76.158.90` (override with `VOXGLASS_VPS_HOST`)
- install root: `/opt/voxglass-gutenberg`
- service user: `voxglass-gutenberg`
- env file: `/etc/voxglass-gutenberg.env`
- batch size: `500` books
- initial sync starts immediately
- timer: daily at **04:15 ± 1 hour**, `Persistent=true`
- service runs `--once`, not `--loop`; the batch lock prevents overlap

The VPS has only ~2 GB free, so batch mode is important: local staging peaks around 150–200 MB.
The service is `Nice=10` with idle I/O priority so it does not compete with Bigcapital.

Useful commands:

```sh
ssh root@217.76.158.90 'systemctl status voxglass-gutenberg-mirror.service --no-pager'
ssh root@217.76.158.90 'systemctl list-timers voxglass-gutenberg-mirror.timer --no-pager'
ssh root@217.76.158.90 'journalctl -u voxglass-gutenberg-mirror.service -f'
ssh root@217.76.158.90 'sudo -u voxglass-gutenberg env GUTENBERG_STAGING_DIR=/opt/voxglass-gutenberg/cache GUTENBERG_STATE_DIR=/opt/voxglass-gutenberg/state GUTENBERG_BATCH_SIZE=500 /opt/voxglass-gutenberg/bin/gutenberg-mirror.sh --status'
```

The deploy script copies the local `uploaded-ids` progress file if present, so moving from the
workstation to the VPS does not redownload already-uploaded books. No credentials, SSH keys, or
private staging data are committed to git.

## Size and cost

Planning figures (Cloudflare R2 Standard, `$0.015/GB-month`, 10 GB-month free tier, free egress):

| Subset | Size | Estimated storage |
| --- | --- | --- |
| No-images EPUBs + catalog (default) | ~19.5 GB | **~$0.15/month** |
| Optional illustrated EPUBs | +126 GB | **~$1.76/month** |
| Full all-format mirror | ~2.44 TB | **~$36.50/month** (not recommended) |

The default budget reflects the 10 GB free tier: `(19.5 − 10) × $0.015 ≈ $0.14`. Medium covers add
roughly 1–2 GB for ~80k books; check `--verify` after the first run. The illustrated line uses the
plan’s 126 GB corpus figure; if that is incremental to the 19.5 GB core, recompute against the
current free-tier consumption. Full-mirror storage dominates; egress is free, and Class A/B operation
charges are negligible at nightly-sync volumes. If the account’s free tier is already consumed by
other buckets, add ~$0.15 for the default corpus.

## On-device search index

`scripts/build-gutenberg-index.py` reads `pg_catalog.csv` and writes:

```text
catalog/manifest.json
catalog/index-<sha>.json.zlib
```

The manifest is small and gets a short cache TTL:

```json
{"schema":1,"version":"2026-11-28T01:25:27Z","index":"index-9012491c19dc85b7.json.zlib","sha256":"901249...","bytes":6763085,"bookCount":78518}
```

The index is a compact JSON array of every `Text` record in the catalog — all Gutenberg languages,
not just English — with `id`, `title`, `authors`, `languages`, `subjects`, `bookshelves`, `issued`,
`epub`, and `cover`. Paths are relative to `gutenberg/`, so the app prefixes them with its public
base URL. The default index is roughly **6–7 MB zlib-compressed** for ~78k books.

The mirror script builds the index after fetching `pg_catalog.csv` (HTTP, then rsync fallback) and
uploads the versioned index before the manifest that references it. Use `--no-index` to skip it.
`GUTENBERG_INDEX_LANGUAGE` still accepts a single language code; the default is `all`.

The app downloads the index on first search/launch and retains the previous verified index until the
new one passes its size and SHA-256 checks. `manifest.json` is revalidated on each Discover load;
the versioned index object is immutable and can be cached for a year.

## Adding the mirror to the app

The app is wired to the mirror as its primary Gutenberg source:

1. **Base URL:** `AppServices` constructs `GutenbergIndexStore` with
   `https://gutenberg.parso.guru`. No R2 key or S3 endpoint exists in the app.
2. **Local search:** `DiscoverView` calls `gutenbergIndex.prepareForSearch()` before searching.
   That loads the cached index, then joins or starts one mirror refresh if no verified snapshot is
   available. Only after the mirror is genuinely unavailable does it construct
   `GutenbergCatalogClient`, whose order is gutenberg.org HTML and then Gutendex.
3. **Book URLs:** index results map to the mirror:
   ```text
   EPUB:  {base}/gutenberg/books/{id}/pg{id}.epub
   Cover: {base}/gutenberg/books/{id}/pg{id}.cover.medium.jpg
   ```
   `GutenbergBookPreview` passes that EPUB URL to `ReadWithAIImporter`, so text downloads come from
   the mirror as well. `detailsURL` remains a gutenberg.org attribution link only.
4. **Index integrity:** the app verifies the manifest byte count and SHA-256 before publishing a
   new snapshot in memory, writes both files atomically, and re-verifies the pair when loading from
   disk.
5. **Public access:** the R2 custom domain maps to the `voxglass-gutenberg` bucket and serves the
   `gutenberg/` prefix. The S3 endpoint and other buckets are never exposed. CORS is unnecessary for
   the native client; add it in a Worker if a web client is introduced.
6. **Caching:** EPUBs and covers are keyed by Gutenberg ID and served atomically from S3. The
   versioned index object is immutable; `manifest.json` is revalidated rather than cached
   indefinitely.

### License, attribution, and trademark

- Project Gutenberg eBooks are public domain in the United States, but the **Project Gutenberg
  License** and header apply to PG-produced files. Keep the eBook’s header and license intact; do
  not strip or rewrite them.
- Display attribution such as “Texts from Project Gutenberg” with a link to
  <https://www.gutenberg.org/>, and include the PG license/credits in an About or Sources screen.
- “Project Gutenberg” is a registered trademark. Use it descriptively (“Project Gutenberg texts”),
  not as the app name, logo, or an implied endorsement/affiliation. Do not use PG logos or trade
  dress. Add a short “not affiliated with or endorsed by Project Gutenberg” disclaimer.
- Do not sell the mirrored texts themselves. Charging for the app/features is a separate question;
  consult the current PG terms and, for anything ambiguous, legal review.

### Mirroring and terms caveats

- Use the official rsync mirrors rather than scraping `www.gutenberg.org`. `www.gutenberg.org` was
  returning HTTP 503 with a maintenance page during this work, so the script must tolerate that.
- `aleph.gutenberg.org::gutenberg-epub` and `ftp.ibiblio.org::gutenberg-epub` work; ibiblio notes it
  is phasing out rsync. `mirrors.xmission.com::gutenberg` mirrors `GUTINDEX.ALL` and the main
  directory but not the generated EPUB module (verified 2026-11-20).
- Mirrors are volunteer/charity funded. Keep transfers resumable and off-peak; use `GUTENBERG_INTERVAL`
  rather than tight retry loops, and consider `rsync --bwlimit` if your host is noisy.
- The catalog CSV is best-effort. `GUTINDEX.ALL` is mirrored from rsync and is the reliable fallback
  while gutenberg.org is down.
- Some titles have country-specific restrictions. The app should keep its existing rights filters
  and takedown process; a mirror does not change the underlying rights status.
- Do not commit Gutenberg data, staging directories, rclone configs, or credentials. `.gitignore`
  excludes the common local paths, but staging belongs outside the repository by default.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `10000 Authentication error` on bucket create | Token lacks Account → R2 Storage → Edit; see permissions above. |
| `403 AccessDenied` / `is a file not a directory` from rclone | Bucket missing, or the script is using the wrong key. Create the bucket and use a bucket-scoped Object Read & Write key; source `~/.config/voxglass-gutenberg.env` so the Gutenberg key wins over a shared `~/.r2-*`. |
| `pg_catalog.csv unavailable` warning | gutenberg.org maintenance/503. `GUTINDEX.ALL` is still mirrored; rerun later. |
| rsync hangs or is very slow | Mirror congestion/rate limiting. Switch `GUTENBERG_RSYNC_SOURCE` to `ftp.ibiblio.org::gutenberg-epub`, or use `--no-catalog` and retry. |
| `--status` says `stale` | The previous process was killed hard. `--resume` clears the PID and continues. |
| Lock held but no visible process | A dead process should release `flock` automatically. `--stop` reports if the PID is not ours; remove a stale `pid` only after checking `ps`. |
| Disk full in staging | Default batch mode peaks at roughly 150–200 MB. If you run `--no-batch`, point `GUTENBERG_STAGING_DIR` at a disk with ~25 GB free, or lower `--batch-size`. |

## Verification performed

- `bash -n scripts/gutenberg-mirror.sh` passes.
- `--dry-run --only-ids 84 --no-catalog` lists the two expected objects
  (`pg84.epub`, `pg84.cover.medium.jpg`, 311.31 KiB total) and writes no files.
- A real background `start` downloaded book 84 and wrote the staging tree; `--stop` terminated it
  cleanly; `--resume` reported `Number of regular files transferred: 0`, proving rsync resume.
- `GUTINDEX.ALL` (9,508,457 bytes) was downloaded successfully from the aleph mirror.
- rclone config generation produces a mode-`600` config; a live request reaches R2 and is refused
  with `403` because the target bucket/key is not available. No secret appears in logs or output.
- No bucket was created and no data was uploaded to R2.
