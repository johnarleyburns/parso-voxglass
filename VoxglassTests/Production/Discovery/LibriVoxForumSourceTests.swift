import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct LibriVoxForumSourceTests {

    let source = LibriVoxForumNeedsSource()

    @Test func atomWeeklyPoemContributesWeeklyFeatured() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>[WEEKLY POETRY] - Hope is the thing with feathers by Emily Dickinson</title>
            <link rel="alternate" href="https://forum.librivox.org/viewtopic.php?t=1001"/>
            <updated>2026-08-01T18:30:00Z</updated>
          </entry>
        </feed>
        """
        let entries = AtomFeedParser().parse(Data(xml.utf8))
        let needs = source.parseEntries(entries, now: FixedClock().now, isWeekly: true)
        #expect(needs.count == 1)
        let need = needs.first!
        #expect(need.signal == .weeklyFeatured)
        #expect(need.work.title == "Hope is the thing with feathers")
        #expect(need.work.author == "Emily Dickinson")
        #expect(!need.isSubmittable) // forum is not a copyright authority → practice
        #expect(need.provenance.libriVoxThreadURL != nil)
    }

    @Test func completeThreadYieldsNothing() throws {
        let entries = [
            AtomFeedParser.Entry(title: "COMPLETE [SOLO] - Pride and Prejudice by Jane Austen",
                                 link: URL(string: "https://forum.librivox.org/viewtopic.php?t=200")),
            AtomFeedParser.Entry(title: "[FULL] [GROUP] - Moby Dick",
                                 link: URL(string: "https://forum.librivox.org/viewtopic.php?t=201"))
        ]
        let needs = source.parseEntries(entries, now: FixedClock().now, isWeekly: false)
        #expect(needs.isEmpty)
    }

    @Test func proofListenerThreadContributesProofSignal() throws {
        let entries = [
            AtomFeedParser.Entry(title: "~[GROUP] - A Collection of Essays",
                                 link: URL(string: "https://forum.librivox.org/viewtopic.php?t=300"))
        ]
        let needs = source.parseEntries(entries, now: FixedClock().now, isWeekly: false)
        #expect(needs.first?.signal == .proofListenerNeeded)
    }

    @Test func openThreadContributesOpenProjectSignal() throws {
        let entries = [
            AtomFeedParser.Entry(title: "[SOLO] [OPEN] - The Time Machine by H. G. Wells",
                                 link: URL(string: "https://forum.librivox.org/viewtopic.php?t=400"))
        ]
        let needs = source.parseEntries(entries, now: FixedClock().now, isWeekly: false)
        #expect(needs.first?.signal == .openProjectNeedsReader)
    }

    @Test func htmlFallbackParsesTopicLinks() {
        let html = """
        <html><body>
          <a href="./viewtopic.php?t=500" class="topictitle">[OPEN] - The Time Machine by H. G. Wells</a>
          <a href="./viewtopic.php?t=501">COMPLETE [SOLO] - Pride and Prejudice</a>
        </body></html>
        """
        let scanner = LenientHTMLScanner()
        let items = scanner.scanTopicLinks(html, baseURL: URL(string: "https://forum.librivox.org/")!)
        #expect(items.count == 2)
        #expect(items[0].topicID == "500")
        #expect(items[0].title.contains("The Time Machine"))
        #expect(items[1].topicID == "501")
    }

    @Test func htmlFallbackViaFetcherYieldsNeeds() async throws {
        let html = """
        <html><body>
          <a href="./viewtopic.php?t=600" class="topictitle">[WEEKLY POETRY] - Fire and Ice by Robert Frost</a>
        </body></html>
        """
        let url = URL(string: "https://forum.librivox.org/viewforum.php?f=28")!
        let fetcher = StubFetcher(url: url, data: Data(html.utf8))
        let needs = try await source.fetch(using: fetcher, clock: FixedClock())
        #expect(needs.contains { $0.signal == .weeklyFeatured && $0.work.title == "Fire and Ice" })
    }

    @Test func signInWallYieldsNothing() async throws {
        // A login page (phpBB) must produce no needs and no error (G-14).
        let url = URL(string: "https://forum.librivox.org/viewforum.php?f=28")!
        let loginHTML = """
        <html><body><form id="login" action="./ucp.php?mode=login">
        <input type="text" name="username"/><input type="password" name="password"/></form></body></html>
        """
        // Atom path is attempted first and must yield nothing when it is a wall too.
        let fetcher = StubFetcher()
        fetcher.route(URL(string: "https://forum.librivox.org/feed.php?f=28")!, result: HTTPFetchResult(data: Data(loginHTML.utf8), statusCode: 200, finalURL: URL(string: "https://forum.librivox.org/ucp.php?mode=login")!))
        fetcher.route(url, result: HTTPFetchResult(data: Data(loginHTML.utf8), statusCode: 200, finalURL: URL(string: "https://forum.librivox.org/ucp.php?mode=login")!))
        let needs = try await source.fetch(using: fetcher, clock: FixedClock())
        #expect(needs.isEmpty)
    }

    @Test func authRedirectYieldsNothing() async throws {
        // A 401/403 response is an auth wall → the rung yields nothing.
        let url = URL(string: "https://forum.librivox.org/feed.php?f=19")!
        let fetcher = StubFetcher(url: url, data: Data("denied".utf8), statusCode: 403)
        let needs = try await source.fetch(using: fetcher, clock: FixedClock())
        #expect(needs.isEmpty)
    }

    @Test func staleOrGarbageHTMLYieldsNothing() async throws {
        let url = URL(string: "https://forum.librivox.org/viewforum.php?f=19")!
        let fetcher = StubFetcher(url: url, data: Data("<html><body>Markup drift, no topics</body></html>".utf8))
        let needs = try await source.fetch(using: fetcher, clock: FixedClock())
        #expect(needs.isEmpty)
    }
}
