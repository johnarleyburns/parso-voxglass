import Foundation

/// L3 — LibriVox forum (NARRATION_NEEDS_SPEC §3.5, §1.6): the most authentic
/// live "needs". Two dependency-free paths, tried in order:
/// 1. **Atom** — `forum.librivox.org/feed.php?f=28` (Weekly Poetry) and `?f=19`
///    (Short Works), parsed with `AtomFeedParser` (Foundation `XMLParser`).
/// 2. **HTML fallback** — `viewforum.php?f=28/19` via the dependency-free
///    `LenientHTMLScanner`.
/// Emits `weeklyFeatured`, `openProjectNeedsReader`, `proofListenerNeeded`.
/// **PD gate (§6) is mandatory** — the forum is not a copyright authority;
/// unverifiable works degrade to `.practice`. Any failure (feed gone, markup
/// drift, **sign-in wall**, PD-unverified) → the rung yields nothing, silently.
public struct LibriVoxForumNeedsSource: NeedsSource {
    public var id: NeedSourceID { .libriVoxForum }

    public let baseURL: URL
    /// Thread ids observed on forum.librivox.org.
    public let weeklyPoetryForumID = "28"
    public let shortWorksForumID = "19"

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? URL(string: "https://forum.librivox.org")!
    }

    public func fetch(using fetcher: any HTTPFetching, clock: any Clock) async throws -> [NarrationNeed] {
        // Total by design: the most fragile rung NEVER surfaces an error.
        // Any failure (feed gone, markup drift, sign-in wall, PD-unverified)
        // → the rung yields nothing, silently (§3.5, Principle 2). Each forum
        // is isolated too, so one forum failing never discards the other's work.
        let descriptor = NeedsSourceDescriptors.descriptor(for: id)
        let now = clock.now
        let weekly = (try? await fetchForum(forumID: weeklyPoetryForumID, fetcher: fetcher, timeout: descriptor.defaultTimeout, now: now, isWeekly: true)) ?? []
        let shortWorks = (try? await fetchForum(forumID: shortWorksForumID, fetcher: fetcher, timeout: descriptor.defaultTimeout, now: now, isWeekly: false)) ?? []
        return weekly + shortWorks
    }

    private func fetchForum(
        forumID: String,
        fetcher: any HTTPFetching,
        timeout: TimeInterval,
        now: Date,
        isWeekly: Bool
    ) async throws -> [NarrationNeed] {
        let userAgent = NeedsSourceDescriptors.userAgent(for: id)

        // Path 1: Atom.
        if let atomURL = URL(string: "feed.php?f=\(forumID)", relativeTo: baseURL),
           let result = try? await fetcher.get(atomURL, timeout: timeout, userAgent: userAgent),
           result.statusCode == 200, !result.looksLikeAuthWall {
            let entries = AtomFeedParser().parse(result.data)
            if !entries.isEmpty {
                return parseEntries(entries, now: now, isWeekly: isWeekly)
            }
        }

        // Path 2: HTML fallback.
        guard let viewURL = URL(string: "viewforum.php?f=\(forumID)", relativeTo: baseURL) else { return [] }
        let result = try await fetcher.get(viewURL, timeout: timeout, userAgent: userAgent)
        guard result.statusCode == 200 else { return [] }
        let html = String(decoding: result.data, as: UTF8.self)
        let scanner = LenientHTMLScanner()
        if scanner.looksLikeLoginPage(html, finalURL: result.finalURL) {
            // Sign-in wall (G-14): yield nothing, never a login UI.
            return []
        }
        let items = scanner.scanTopicLinks(html, baseURL: result.finalURL)
        return items.compactMap { item in
            threadNeed(title: item.title, threadURL: item.url ?? result.finalURL, now: now, isWeekly: isWeekly)
        }
    }

    /// Parses Atom entries (feed path). Only live threads narratable.
    public func parseEntries(_ entries: [AtomFeedParser.Entry], now: Date, isWeekly: Bool) -> [NarrationNeed] {
        entries.compactMap { entry in
            threadNeed(title: entry.title, threadURL: entry.link, now: now, isWeekly: isWeekly)
        }
    }

    private func threadNeed(title: String, threadURL: URL?, now: Date, isWeekly: Bool) -> NarrationNeed? {
        let parsed = ForumTitleParser().parse(title)
        guard parsed.isNarratable else { return nil }
        guard let workTitle = parsed.title, !workTitle.isEmpty else { return nil }

        let signal: NeedSignal = {
            if isWeekly, parsed.isWeeklyPoem { return .weeklyFeatured }
            switch parsed.status {
            case .proofListenerNeeded: return .proofListenerNeeded
            case .openNeedsReader: return .openProjectNeedsReader
            case .complete, .full: return .evergreen
            }
        }()

        let work = NarratableWork(
            title: workTitle,
            author: parsed.author ?? "Unknown",
            subject: isWeekly ? "poem" : "short work",
            grade: .practice, // §6: the forum is not a copyright authority
            estSeconds: 120
        )
        return NarrationNeed(
            work: work,
            signal: signal,
            strength: signal.priority == 0 ? 95 : 80,
            provenance: NeedProvenance(
                sources: [.libriVoxForum],
                firstSeen: now,
                lastConfirmed: now,
                pdBasis: .unverified,
                libriVoxThreadURL: threadURL
            )
        )
    }
}
