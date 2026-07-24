# Voxglass Studio — Paid AI-Narrated Titles

**Mockups:** [`docs/mockups/voxglass-studio-store.html`](mockups/voxglass-studio-store.html)

## Context

Voxglass is free and has no monetisation. `docs/RELEASE_PLAN.md` states the intent plainly: "Future monetization will come
from audiobook sales and library partnership integrations." This plan is the first, smallest version of that — a paid shelf
of $1.99–$2.99 audiobooks that **do not exist anywhere for free**, produced with synthetic narration, sold as
non-consumable in-app purchases.

Two outcomes matter, and the second is worth more than the first:

1. Revenue that covers the developer account and pays for itself.
2. **The plumbing**: entitlements, a content CDN, per-title downloads, restore-purchases, per-territory availability.
   Every one of those is required by a licensed-content deal with a publisher later. Building it now against
   zero-royalty inventory is the cheapest possible rehearsal.

---

## Part 1 — What is actually missing (research)

### Method

Demand proxy: Project Gutenberg's [Top 100 downloads, last 30 days](https://www.gutenberg.org/browse/scores/top)
(retrieved 22 July 2026). Supply check: the Internet Archive advanced-search API against
`collection:librivoxaudio`, run per title both as an exact title phrase and as a full-text query.

**Method caveat, and it matters.** An exact-title query returns a false negative when LibriVox uses a variant title —
*The Confessions of St. Augustine* returned zero, but LibriVox catalogues it simply as *Confessions*. Every candidate below
was therefore re-checked with a full-text query, and every one must still be confirmed by hand on librivox.org before a
single character is sent to a TTS API.

### The headline finding

**LibriVox has no Agatha Christie at all.** Eleven Christie titles queried, all zero, and a full-text search for
`"agatha christie"` inside `collection:librivoxaudio` returns 14 items, none of which are her works. Meanwhile *The Secret
of Chimneys* (1925) is **#7 on Gutenberg's 30-day list at 90,492 downloads** — enormous demand, zero free audio.

That gap is real, and its cause is also its biggest risk: Christie's works are public domain in the **US** for pre-1931
publication, but she died in 1976, so they remain in copyright in the UK/EU until 2047. LibriVox's stated policy is
US-public-domain-only, and they have still steered clear. Read that as a warning, not an invitation.

### Verified gaps, ranked

Demand = Gutenberg 30-day downloads where the title appears in the top 50. "LV" = LibriVox recordings found.

#### Tier A — public domain worldwide (author *and* translator died before ~1956). Safe to sell globally.

| # | Title | Author | Demand | LV | Est. length | Price |
|---|---|---|---|---|---|---|
| 1 | My Life, Vol. 1 | Richard Wagner (d. 1883) | 80,223 | 0 | ~20 h | $2.99 |
| 2 | The Love Letters of Mary Wollstonecraft to Gilbert Imlay | Mary Wollstonecraft (d. 1797) | 78,172 | 0 | ~4 h | $1.99 |
| 3 | Bidwell's Travels | Austin Bidwell (d. 1899) | 74,050 | 0 | ~22 h | $2.99 |
| 4 | Four Arthurian Romances | Chrétien de Troyes, tr. W. W. Comfort (d. 1955) | 65,160 | 0 | ~20 h | $2.99 |
| 5 | The Yeoman Adventurer | George W. Gough (1917) | 62,601 | 0 | ~12 h | $1.99 |
| 6 | Julie, or the New Heloise (*Eloisa*) | Rousseau (d. 1778) | 63,986 | 0 | ~39 h | split ×2 @ $2.99 |

#### Tier B — US public domain only. Requires per-territory IAP availability and legal review.

| # | Title | Author | Demand | LV | Est. length | Price | Non-US PD |
|---|---|---|---|---|---|---|---|
| 7 | The Secret of Chimneys | Agatha Christie, 1925 | 90,492 | 0 | ~8 h | $2.99 | 2047 |
| 8 | The Murder at the Vicarage | Agatha Christie, 1930 (first Miss Marple) | — | 0 | ~8 h | $2.99 | 2047 |
| 9 | Civilization and Its Discontents | Sigmund Freud, 1930 | — | 0 | ~3.5 h | $1.99 | translation 2033 |
| 10 | Cimarron | Edna Ferber, 1930 (Pulitzer) | — | 0 | ~11 h | $2.99 | 2039 |

Also verified zero and worth holding in reserve: *The Murder of Roger Ackroyd*, *The Mystery of the Blue Train*,
*The Seven Dials Mystery*, *Partners in Crime*, *The Man in the Brown Suit* (all Christie); *The Sound and the Fury* and
*Sartoris* (Faulkner, d. 1962); *Vile Bodies* (Waugh); *Angel Pavement* (Priestley); *The Conquest of Happiness* (Russell);
*Passing* (Nella Larsen).

**Explicitly not recommended:** *The Sound and the Fury*. Highest name recognition on the list, but stream-of-consciousness
prose with unmarked time shifts carried by italics is close to the worst possible material for synthetic narration. It
would generate the app's first one-star review about the voice.

### Track 2 — a second thesis worth one experiment

A large share of the most-wanted classics *are* on LibriVox but only as multi-narrator group recordings, and "a different
reader every chapter" is the single most common complaint in reviews of the incumbent LibriVox app. A consistent
single-voice narration of, say, *The Mysteries of Udolpho* (#8 on Gutenberg, 89,217 downloads, one LibriVox recording) has
zero rights risk and a much larger addressable audience — but it competes against a free version, so conversion is lower.

**Recommendation:** ship one Track 2 title alongside the first Tier A batch and compare attach rates directly. That single
data point decides the shape of the next twenty titles.

---

## Part 2 — Financial analysis

### Cost per title

| Line | Cost | Note |
|---|---|---|
| TTS synthesis | $7 – $99 | An 80,000-word book ≈ 448K characters. OpenAI TTS at $15/M = **$6.72**; ElevenLabs volume API at ~$60/M = **$27**; ElevenLabs Creator at ~$220/M = **$99**. |
| Retakes / pronunciation fixes | +20% | Names, archaic spellings, verse |
| Cover art | $0 – 15 | The app already generates covers via `BookArtworkView` |
| **Cash total** | **≈ $50** | Budget figure per average-length title |
| Human time | **8 – 12 h** | Text prep and chapter splitting (2–4 h), listen-through QA at 2× (5 h), encode/metadata/upload (1 h) |

Cash is not the constraint. **Time is.** At 10 h/title a part-time solo effort sustains roughly 4–6 titles/month.

### Fixed and marginal costs

- Apple Developer Program: **$99/yr** (already paid).
- Storage: 8 h at 64 kbps mono ≈ **250 MB/title**. Twenty titles ≈ 5 GB.
- **Egress is the trap.** Each purchase downloads ~250 MB. On S3 at $0.09/GB, 1,280 downloads/month = **$29/month**.
  On **Cloudflare R2 or Backblaze B2 + Cloudflare, egress is $0** and storage is ~$0.015/GB-month → **under $0.10/month**.
  Use R2. This single choice is the difference between ~85% and ~70% gross margin at volume.
- Apple's commission: **15%** under the Small Business Program (proceeds under $1M/yr).

Net per sale: **$1.69** on $1.99, **$2.54** on $2.99.

### Break-even per title

| Basis | Cost | Units to break even @ $2.54 net |
|---|---|---|
| Cash only | $50 | **20 sales** |
| Cash + 10 h valued at $50/h | $550 | **217 sales** |

Twenty sales per title is a trivially low bar. Two hundred is the number that decides whether this is a business or a
hobby, and it is the number to measure against.

### Revenue scenarios (steady state, month 12, catalogue of 20 titles)

| | Bear | Base | Bull |
|---|---|---|---|
| Monthly active users | 3,000 | 12,000 | 40,000 |
| MAU who buy in a month | 0.4% | 1.0% | 2.0% |
| Buyers / month | 12 | 120 | 800 |
| Units per buyer | 1.3 | 1.4 | 1.6 |
| **Units / month** | **16** | **168** | **1,280** |
| Average price | $2.30 | $2.40 | $2.50 |
| Gross / month | $37 | $403 | $3,200 |
| **Net after Apple 15% / month** | **$31** | **$343** | **$2,720** |
| **Net / year** | **$375** | **$4,110** | **$32,640** |

Catalogue investment: 20 titles × $50 = **$1,000 cash**, 200 hours.

| | Bear | Base | Bull |
|---|---|---|---|
| Months to recover $1,000 cash | 32 | **3** | **<1** |
| Months to recover cash + 200 h @ $50/h ($11,000) | never | 32 | 4 |
| Effective hourly rate, year 1 | $1.90/h | $20.55/h | $163/h |

**Read:** the bear case is not a business but it is a cheap, bounded experiment — $1,000 to learn whether these users pay
for anything at all. The base case funds the developer account, the CDN, and the cost of the next twenty titles. The bull
case justifies quitting other work on the app to do this full time.

### Sensitivity — what actually moves the number

1. **Install base.** Everything is linear in MAU. Twenty titles do not create demand; they monetise demand that the free
   app has to earn first. **Do not build this before the app has users.**
2. **Attach rate.** A 1% → 2% shift doubles revenue and costs nothing. The lever is the *"No LibriVox recording exists"*
   line on every store row and the free chapter-1 sample — not price.
3. **Price.** $1.99 → $2.99 is +50% revenue at likely-modest volume loss for content with no free substitute. Start at
   $2.99 for Tier A/B novels and $1.99 for anything under 5 hours; test the reverse after 90 days.
4. **Bundles.** "Any 3 for $5.99" lifts units-per-buyer, which is the cheapest growth in the whole model.
5. **Territory restriction.** Restricting Tier B to the US removes roughly 55–60% of the addressable market for those
   titles. That is the price of doing it legally, and it is why Tier A ships first.

### Kill criteria — decide in advance

- Launch batch = **5 titles** (4 Tier A + 1 Track 2), cash outlay ≈ $250, ~50 hours.
- If the launch batch sells **fewer than 60 units in 90 days**, stop; the thesis is wrong and the money is a rounding error.
- If it sells **60–250**, continue at 2 titles/month while focusing on installs.
- If it sells **250+**, go to 5 titles/month and start the publisher conversation with real conversion data in hand.

---

## Part 3 — Legal and store constraints

These are the parts that can sink the project, so they come before any code.

1. **Territory.** The App Store sells globally by default. A US-public-domain-only work sold in the UK is infringement.
   App Store Connect supports **per-territory availability for individual in-app purchases** — Tier B products must be
   US-only, and the product page must say so (the mockup does).
2. **Get counsel on Tier B before spending a dollar on it.** Christie in particular: Agatha Christie Limited is an active
   rights-holder, and LibriVox's total absence of her work is evidence worth taking seriously. Tier A is designed so the
   project can launch and prove itself without waiting on that review.
3. **Translations are separately copyrighted.** Freud's ideas are not the issue; Riviere's and Strachey's English
   translations are. Verify the specific Gutenberg edition's translator and their death date for every non-English work.
4. **TTS provider terms.** Commercial use of ElevenLabs output requires a paid tier; OpenAI TTS permits commercial use but
   requires disclosure that the voice is synthetic. **Disclose on the product page, not in settings.** Never imply a human
   reader; never use a voice cloned from a real narrator.
5. **LibriVox goodwill.** The free catalogue must stay completely untouched and never gated. Studio is an additional
   shelf, clearly separate. Getting this wrong costs the app its entire positioning.
6. **App Review.** Non-consumable IAP for downloadable content is a standard, well-trodden pattern. Enable Family Sharing
   — it costs nothing marginal and raises perceived value.

---

## Part 4 — Implementation

### Product surface

- New tab or a section in Browse: **Voxglass Studio**, matching the mockups. Every row states the gap it fills.
- Product page: cover, synthetic-narration badge naming the voice, author/year/length/chapter count, **free chapter-1
  stream**, Buy, Restore, and the disclosure block.
- Purchased titles land in My Books as ordinary books, with a small Studio provenance chip (reuse `ProvenanceChip` in
  `Voxglass/DesignSystem/VoxglassComponents.swift`) — they play through the same `PlaybackCoordinator` and the same
  offline path, and they resume like everything else.

### Code

| Area | Work |
|---|---|
| `Voxglass/Core/Store/` | `StudioCatalog` (JSON manifest, same shape as `Core/Resources/CuratedLists`), `StudioProduct`, `EntitlementStore` |
| StoreKit 2 | `Product.products(for:)`, `purchase()`, `Transaction.updates` listener, `currentEntitlements` on launch and on restore |
| Delivery | Signed, expiring R2 URLs issued only against a verified transaction; chapters fetched by the existing `OfflineDownloadManager` |
| Import | On purchase, write a `Source` of a new kind `.studio` and the book/chapters through `LibraryRepository` — no new playback code |
| Sample | Chapter 1 is a public URL; no entitlement needed |

### Production pipeline (`Tools/StudioNarrate/`)

Follow the existing `Tools/CuratedLists` pattern — a small Swift executable plus scripts:

1. Fetch the Gutenberg text, strip licence header/footer, split on chapter headings.
2. Apply a per-title pronunciation lexicon (proper nouns, archaisms, foreign phrases).
3. Synthesize chapter by chapter; cache by content hash so retakes only re-bill the changed chapter.
4. Encode to 64 kbps mono AAC, tag chapter metadata, generate the manifest entry and durations.
5. Upload to R2; emit the `StudioCatalog` JSON.
6. **Human listen-through at 2× before publish.** Non-negotiable — this is the whole quality argument.

### Sequencing

- **Phase 0 (this quarter):** confirm the five launch titles by hand on librivox.org; get Tier B legal review started;
  build `Tools/StudioNarrate` and produce one title end to end.
- **Phase 1:** StoreKit + entitlements + Studio shelf, with the one produced title as the only product. Ship it.
- **Phase 2:** remaining four launch titles; measure against the kill criteria at day 90.
- **Phase 3:** scale to 20 titles, or stop.

## Verification

1. StoreKit sandbox: buy, download, play offline, delete the app, reinstall, **Restore purchases** returns the title with
   its position intact.
2. Ask-to-Buy and Family Sharing accounts behave correctly.
3. A Tier B product is invisible in a non-US storefront (test with a UK sandbox account).
4. Refund path: a revoked transaction removes the entitlement and the audio, but leaves the book row and reading position
   in place.
5. The free LibriVox catalogue is unchanged — no paywall appears anywhere outside the Studio shelf. Guard this with a
   source-level test in the style of `ArtworkPresentationTests`: no file under `Features/` outside `Features/Studio/`
   references `EntitlementStore`.

## Sources

- [Project Gutenberg — Top 100 downloads](https://www.gutenberg.org/browse/scores/top)
- [Internet Archive advanced search API](https://archive.org/advancedsearch.php) — `collection:librivoxaudio` supply checks, 22 July 2026
- [Public Domain Day 2026 — works from 1930](https://blog.archive.org/public-domain-day-2026/)
- [Apple — App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/)
- [ElevenLabs API pricing, 2026](https://texttolab.com/blog/elevenlabs-pricing)
- [OpenAI TTS pricing, 2026](https://texttolab.com/blog/openai-tts-pricing)
