# Voxglass market assessment — September 9, 2026

Voxglass has a plausible specialist opportunity, but the general audiobook-player market is already well served. The strongest commercial hypothesis is an iPhone workflow for people who want to finish a human-narrated audiobook. A curated public-domain listening app is a credible second direction, with weaker monetization. Neither hypothesis is validated by the existence of the code.

## Scope and evidence

Reviewed repository HEAD `7e9b77e`, README, current status, revised narration specification, app navigation, narration UI, microphone check, production domain, licensing, validation and export code, and catalog components. This is a product/architecture assessment with selective source inspection, not a full correctness, security, or release audit. No builds, device tests, competitor hands-on trials, customer interviews, or revenue verification were performed. The working tree was clean before adding this report.

External findings use public product pages and US App Store listings accessed September 9, 2026. Features are vendor claims unless otherwise stated; listed prices may vary by region and offer. Missing advertised features do not prove absence. Market judgments and proposed experiments below are inferences, not measured market share or demand.

## What the repository actually contains

There are two products competing for attention:

1. A public-domain and personal-file audiobook player: library, discovery, narrator metadata, playback persistence, downloads, CarPlay, and Watch playback work.
2. An iPhone narration workspace: manuscript import, paragraph-addressed takes, review, assembly, mic checking, destination validation, mastering/export infrastructure, and a StoreKit Narration Pro entitlement.

Relevant implementation evidence:

- `Voxglass/App/RootView.swift` exposes the Narration tab.
- `Voxglass/Features/Production/Discovery/NarrationTabView.swift` connects discovery and projects to the narration flow.
- `Voxglass/Features/Production/Discovery/MicCheckView.swift` records and plays back a short microphone test with level/frequency displays.
- `Voxglass/Core/Production/Validation/ValidationRuleEngine.swift` evaluates project and destination issues.
- `Voxglass/Core/Production/Packaging/ExportPreflight.swift` considers asset hydration, staging space, and backup verification.
- `Voxglass/Core/Production/License/LicenseTypes.swift` defines paid mastering, retail presets, batch export, M4B, and report export capabilities. Price comes from StoreKit; the specification's $49 introductory/$79 standard proposal is not proof of live pricing.

The README understates narration and describes Watch as future work. Conversely, older narration specifications describe Watch production/review features that `current_status.md` explicitly removes. Current status records hardware validation still pending for Watch playback. Source presence and historic test reports should not be presented as proven release quality.

The amount of integration is an asset, but also a maintenance obligation. Phone recording, background listening, Watch downloads, CarPlay, cloud assets, and paid export each create distinct failure modes. More surface area will not, by itself, solve positioning.

## Demand and competition

The audiobook category is growing: APA reports $2.43 billion in 2025 publisher receipts, 157 million US adults who have ever listened, and more than 750,000 active titles. These are publisher/content metrics, not the addressable market for a paid player or narration app. A large category can still have a crowded software layer. [APA research](https://www.audiopub.org/research-faq)

| Segment and alternatives | Existing offer | Implication for Voxglass |
|---|---|---|
| Free library listening: Libby | Free ebooks and audiobooks through participating libraries | Free listening is already available beyond public-domain classics. [Libby](https://libbyapp.com/) |
| Built-in retail listening: Apple Books | Audiobook discovery, purchase, and playback in Apple's ecosystem | A general player must give people a specific reason to add another app. [Apple Books](https://www.apple.com/apple-books/) |
| Public-domain catalog: BookDesign LibriVox Audiobooks | Advertises narrator browsing, offline playback, CarPlay, bookmarks, sleep timer, and collections; US listing includes $1.99/month and $9.99/year subscriptions | The README's feature-parity argument is weaker today. Narrator display and CarPlay are not exclusive. [App Store](https://apps.apple.com/us/app/librivox-audiobooks/id596159212) |
| Personal-file listening: BookPlayer | M4B/M4A/MP3 playback, Apple Watch support, active server-integration development; listed Pro prices $4.99/month or $49.99/year | Strong direct competition for imported books and Apple-device convenience. [App Store](https://apps.apple.com/us/app/bookplayer/id1138219998) |
| Personal-file listening: Bound | DRM-free audiobook imports and dedicated playback | Owning files and avoiding a content subscription are established use cases. [App Store](https://apps.apple.com/us/app/bound-audiobook-player/id1041727137) |
| Server-backed listening: Prologue | Plex audiobook listening across iPhone, iPad, and Apple Watch | Watch support alone is not a distinctive position. [Prologue](https://prologue.audio/) |
| Read-along: Lex, HushBook | Lex offers reading/listening and synchronization; HushBook advertises local transcription, word highlighting, offline use, and no account | Both synchronized text and private read-along already face competition. [Lex](https://lex-books.com/), [HushBook](https://hushbook.app/) |
| Human narration: Hindenburg Narrator | Document-based recording and audiobook workflow on Mac/Windows; separate iPhone field recorder | Manuscript-led production is established. A complete phone workflow is the narrower opening. [Products](https://home.hindenburg.com/products/?sector=user), [Supported platforms](https://hindenburg.uservoice.com/knowledgebase/articles/308158-what-operating-systems-os-platforms-do-hindenbur) |
| Production assistance: Pozotron | Script preparation, proofing/pickup workflow, pronunciation research, DAW marker export | Quality assurance is an existing paid category; basic validation is not a moat. [Pozotron](https://www.pozotron.com/) |
| Synthetic audiobook creation: ElevenLabs | Manuscript-to-audio generation, editing, download and distribution | Avoid competing on generic AI narration or cheap generation. [ElevenLabs Audiobooks](https://elevenlabs.io/audiobooks) |

Competitive entry continues even in production: the creator of Kosmos recently announced a free local desktop recording, manuscript-proofing, mastering, and export app. Treat this as an early entrant to monitor, not an established competitor or verified quality benchmark. It further weakens any claim that an integrated production workflow is globally unique. [Creator announcement](https://www.reddit.com/r/ACX/comments/1w5s492/i_made_a_free_open_source_local_app_to_record/)

## Positioning options

### 1. Best commercial hypothesis: finish your first human-narrated audiobook on iPhone

Proposed promise: **“Your manuscript. Your voice. A finished audiobook—from your iPhone.”**

Target self-narrating authors with a real manuscript and reason to preserve their own performance. Start with short nonfiction, essays, and short fiction rather than assuming a phone suits every 20-hour production. Volunteers are useful usability partners, but their free contribution workflow does not establish commercial demand.

The valuable outcome is avoiding the handoffs between a script viewer, recorder, take organizer, proofing notes, mastering tool, and packaging utility. Much of the foundation already exists here. Prioritize:

- A short guided first session ending in one completed chapter.
- Clear recovery after calls, route changes, app termination, and storage pressure.
- Retakes and review notes tied to the exact manuscript passage.
- Concrete recording feedback: what to change and what requires rerecording.
- A predictable finished package that an independent editor can inspect.

Treat automated manuscript mismatch detection as a later experiment, not an existing capability established by this review. Technical threshold checks are not equivalent to performance quality or distributor acceptance.

The main counterargument is important: people serious enough to pay may prefer a desktop, while phone-only novices may not finish. Test that before expanding this product. The reviewed competitors suggest a possible gap; they do not establish an empty market.

### 2. Best listening hypothesis: help me choose the right recording of a classic

Proposed promise: **“Find the voice that makes a classic worth finishing.”**

A large public-domain catalog is shared inventory. The differentiated job is choosing among recordings: solo versus multiple readers, performance style, translation/edition, completeness, sound quality, and duration.

Build a small editorially verified collection with short comparison samples, explicit edition matching, and plain explanations of why each recording was selected. Existing narrator extraction, catalog matching, curated collections, and normalization offer a starting point. A narrator name alone is parity; trusted recording selection could be a stronger experience.

Begin with 30–50 works, not a larger catalog count. The possible defensibility comes from reliable metadata, editorial judgment, and audience trust accumulated over time. Demand and willingness to fund that work remain unproven.

### 3. Secondary convenience proposition: classics and owned books on Watch without a server

Useful supporting value, particularly for walking and exercise, but competitors already support Watch. The distinction would be easier setup and dependable transfers, not hardware availability. Current pending physical-device evidence makes reliability validation a prerequisite to promoting this claim.

## Monetization and focus

The README anticipates book sales and library partnerships while code already contains Narration Pro. Choose a primary economic model. Library partnerships are a separate customer-development and sales effort; they are not a demonstrated way to subsidize a free player. Retailing the same available content likewise needs its own distribution advantage.

Narration Pro is more coherent: charge for time saved completing production while preserving the documented free contribution and personal-recording paths. Test the existing $49/$79 proposal with real purchasers before treating it as the right price.

Illustrative arithmetic, not a forecast: 1,000 new purchases at $79 yield $79,000 gross before platform fees, taxes, refunds, support, and development costs. A one-time model needs continued new buyers; free listener growth does not guarantee those buyers.

Keep the listening product useful, but use distinct listening and narration landing pages. Do not assume listeners naturally become creators. A separate app can wait until acquisition and usage evidence justify the operational cost.

## Six-week validation plan

These are proposed decision thresholds, not industry benchmarks.

1. Recruit 12–15 authors/narrators with actual work in progress, including at least eight plausible commercial buyers. Observe their current workflow and ask why they would use a phone.
2. Have at least ten attempt a real chapter with Voxglass. Target seven completing without developer intervention, and at least five electing to record another chapter. Track blockers and hands-on support time through consented observation.
3. Have an independent audio editor inspect at least three exported chapters. Check audible joins, consistency, missing/duplicated passages, metadata, and destination suitability; automated green checks alone do not pass this test.
4. Seek five real paid pilot purchases from the commercial cohort at the proposed price. Record refusals and reasons. A waitlist or friendly compliment does not substitute for purchase behavior.
5. In parallel with user testing, test an editorial collection with 20 classics listeners. Observe recording selection and repeat use over several weeks. Establish whether they prefer it to their current app strongly enough to switch.

Pause commercial expansion if users prefer desktop workflows, repeatedly fail to finish, require support that overwhelms the purchase value, or reject payment. If listeners return but creators do not pay, decide explicitly whether Voxglass should be a small community product rather than assuming retail revenue will appear later.

## Recommendation

Continue only with a narrower thesis. The player category is crowded enough that feature parity, privacy, free access, read-along, or Watch support individually are weak reasons to invest further. The most promising commercial experiment is the existing iPhone human-narration workflow; the most promising listening experiment is trusted recording selection. Allocate the next effort to real chapter completion, export quality, paid pilots, and repeat listening—not more product surfaces.
