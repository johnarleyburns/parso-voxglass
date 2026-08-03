import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct FeaturedSelectorTests {

    let selector = FeaturedSelector()

    @Test func deterministicPickForSamePoolAndDate() {
        let pool = (0..<20).map { makeNeed(title: "Poem \($0)", author: "Poet \($0)") }
        let date = Date(timeIntervalSince1970: 1_752_000_000) // 2025-ish, UTC
        let first = selector.featured(from: pool, cadence: .weekly, on: date)
        let second = selector.featured(from: pool, cadence: .weekly, on: date)
        #expect(first != nil)
        #expect(first?.id == second?.id)
        // Same pick on every device (deterministic, not Hasher).
        let third = selector.featured(from: pool, cadence: .weekly, on: date)
        #expect(third?.id == first?.id)
    }

    @Test func rotatesAcrossWeeks() {
        let pool = (0..<8).map { makeNeed(title: "Poem \($0)", author: "Poet \($0)") }
        let week1 = selector.featured(from: pool, cadence: .weekly, on: isoDate("2026-08-02T12:00:00Z"))
        let week2 = selector.featured(from: pool, cadence: .weekly, on: isoDate("2026-08-09T12:00:00Z"))
        // Two different ISO weeks → two different deterministic picks (pool of 8).
        #expect(week1?.id != week2?.id)
    }

    @Test func rotatesAcrossMonths() {
        let pool = (0..<8).map { makeNeed(title: "Book \($0)", author: "Author \($0)") }
        let aug = selector.featured(from: pool, cadence: .monthly, on: isoDate("2026-08-15T12:00:00Z"))
        let sep = selector.featured(from: pool, cadence: .monthly, on: isoDate("2026-09-15T12:00:00Z"))
        #expect(aug?.id != sep?.id)
    }

    @Test func pinHonoredForCurrentPeriod() {
        let pinned = makeNeed(title: "Pinned Weekly", pinnedWeekOf: isoDate("2026-08-03T00:00:00Z"))
        let others = (0..<10).map { makeNeed(title: "Other \($0)", author: "Poet") }
        let pool = others + [pinned]
        let featured = selector.featured(from: pool, cadence: .weekly, on: isoDate("2026-08-05T12:00:00Z"))
        #expect(featured?.work.title == "Pinned Weekly")
    }

    @Test func stalePinIgnored() {
        let stale = makeNeed(title: "Stale Pin", pinnedWeekOf: isoDate("2026-07-20T00:00:00Z"))
        let others = (0..<10).map { makeNeed(title: "Other \($0)", author: "Poet") }
        let pool = others + [stale]
        let featured = selector.featured(from: pool, cadence: .weekly, on: isoDate("2026-08-05T12:00:00Z"))
        #expect(featured?.work.title != "Stale Pin")
        #expect(featured != nil)
    }

    @Test func monthlyPinHonored() {
        let pinned = makeNeed(title: "August Book", pinnedMonthOf: isoDate("2026-08-01T00:00:00Z"))
        let pool = [pinned] + (0..<8).map { makeNeed(title: "Book \($0)", author: "A") }
        let featured = selector.featured(from: pool, cadence: .monthly, on: isoDate("2026-08-21T12:00:00Z"))
        #expect(featured?.work.title == "August Book")
    }

    @Test func emptyPoolGuard() {
        let featured = selector.featured(from: [], cadence: .weekly, on: Date())
        #expect(featured == nil)
    }

    @Test func utcWeeksDoNotFlipMidweek() {
        let pool = (0..<4).map { makeNeed(title: "Poem \($0)", author: "Poet") }
        // ISO weeks run Monday–Sunday (UTC): two midweek dates share a period.
        let tuesday = selector.featured(from: pool, cadence: .weekly, on: isoDate("2026-08-04T12:00:00Z"))
        let friday = selector.featured(from: pool, cadence: .weekly, on: isoDate("2026-08-07T12:00:00Z"))
        #expect(tuesday?.id == friday?.id)
    }

    private func isoDate(_ string: String) -> Date {
        NeedsJSONCoding.isoDate(string)!
    }
}
