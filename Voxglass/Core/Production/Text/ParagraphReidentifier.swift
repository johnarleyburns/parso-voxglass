import Foundation

public struct ReidentificationReport: Sendable {
    public var assignments: [Int: UUID] = [:]
    public var newIndices: [Int] = []
    public var retiredIDs: [UUID] = []
    public var driftedIDs: [UUID: DriftKind] = [:]

    public init() {}
}

public struct ParagraphReidentifier: Sendable {
    private static let windowSize = 400

    public init() {}

    public func match(existing: [Paragraph], incoming: [ExtractedBlock]) -> ReidentificationReport {
        var report = ReidentificationReport()

        let exKeys = existing.map { TextNormalizer.identityKey($0.text) }
        let inKeys = incoming.map { TextNormalizer.identityKey($0.text) }
        let exHashes = existing.map(\.textHash)
        let inHashes = incoming.map { TextNormalizer.hash($0.text) }

        var keyToExIdx: [String: [Int]] = [:]
        for (i, k) in exKeys.enumerated() {
            keyToExIdx[k, default: []].append(i)
        }

        var keyToInIdx: [String: [Int]] = [:]
        for (j, k) in inKeys.enumerated() {
            keyToInIdx[k, default: []].append(j)
        }

        var exUsed = Array(repeating: false, count: existing.count)
        var inUnmatched: Set<Int> = []
        var exUnmatched: Set<Int> = []
        var anchors: [(ex: Int, in: Int)] = []

        func recordMatch(_ ex: Int, _ inp: Int) {
            report.assignments[inp] = existing[ex].id
            exUsed[ex] = true
            anchors.append((ex, inp))
            if exHashes[ex] != inHashes[inp] {
                let d = TextDriftDetector()
                report.driftedIDs[existing[ex].id] = d.classify(
                    recorded: existing[ex].text, current: incoming[inp].text)
            }
        }

        // Pass 1: sequential identity-key matching with forward lookahead.
        var exIdx = 0, inIdx = 0
        while exIdx < existing.count && inIdx < incoming.count {
            if exKeys[exIdx] == inKeys[inIdx] {
                recordMatch(exIdx, inIdx)
                exIdx += 1; inIdx += 1
                continue
            }

            let exKey = exKeys[exIdx], inKey = inKeys[inIdx]

            if let futureIn = keyToInIdx[exKey]?.sorted().first(where: { $0 >= inIdx && $0 - inIdx < Self.windowSize }) {
                for j in inIdx..<futureIn { inUnmatched.insert(j) }
                inIdx = futureIn
                recordMatch(exIdx, inIdx)
                exIdx += 1; inIdx += 1
                continue
            }

            if let futureEx = keyToExIdx[inKey]?.sorted().first(where: { $0 >= exIdx && $0 - exIdx < Self.windowSize }) {
                for i in exIdx..<futureEx { exUnmatched.insert(i) }
                exIdx = futureEx
                recordMatch(exIdx, inIdx)
                exIdx += 1; inIdx += 1
                continue
            }

            inUnmatched.insert(inIdx)
            exUnmatched.insert(exIdx)
            exIdx += 1; inIdx += 1
        }

        for i in exIdx..<existing.count { exUnmatched.insert(i) }
        for j in inIdx..<incoming.count { inUnmatched.insert(j) }
        for i in 0..<existing.count where exUsed[i] { exUnmatched.remove(i) }
        for j in 0..<incoming.count where report.assignments[j] != nil { inUnmatched.remove(j) }

        anchors.sort { $0.in < $1.in }

        // Pass 2: windowed matching between matched anchors (spec §9.4).
        // Windows larger than 400 paragraphs on either side are split at the midpoint.
        var windows: [(exLo: Int, inLo: Int, exHi: Int, inHi: Int)] = []
        var loEx = -1, loIn = -1
        for anchor in anchors {
            windows.append((loEx, loIn, anchor.ex, anchor.in))
            loEx = anchor.ex; loIn = anchor.in
        }
        windows.append((loEx, loIn, existing.count, incoming.count))

        func splitIfNeeded(_ w: (exLo: Int, inLo: Int, exHi: Int, inHi: Int)) -> [(exLo: Int, inLo: Int, exHi: Int, inHi: Int)] {
            let exCount = w.exHi - w.exLo - 1
            let inCount = w.inHi - w.inLo - 1
            if exCount > Self.windowSize && inCount > Self.windowSize {
                let midEx = w.exLo + 1 + exCount / 2
                let midIn = w.inLo + 1 + inCount / 2
                return splitIfNeeded((w.exLo, w.inLo, midEx, midIn))
                    + splitIfNeeded((midEx, midIn, w.exHi, w.inHi))
            }
            return [w]
        }

        var remainingEx = Array(exUnmatched).sorted()
        let remainingIn = Array(inUnmatched).sorted()

        for window in windows.flatMap(splitIfNeeded) {
            let exRange = (window.exLo + 1)..<window.exHi
            let inRange = (window.inLo + 1)..<window.inHi
            for j in inRange where report.assignments[j] == nil {
                var best: (ei: Int, sim: Double)? = nil
                for ei in exRange where !exUsed[ei] {
                    if exKeys[ei] == inKeys[j] {
                        best = (ei, 1.0); break
                    }
                    let sim = jaccardSimilarity(existing[ei].text, incoming[j].text)
                    if sim >= 0.72, best == nil || sim > best!.sim {
                        best = (ei, sim)
                    }
                }
                if let b = best {
                    recordMatch(b.ei, j)
                    remainingEx.removeAll { $0 == b.ei }
                }
            }
        }

        // Pass 3: first/last-60-character anchoring for edits in the middle.
        let stillEx = remainingEx.filter { !exUsed[$0] }
        for j in remainingIn where report.assignments[j] == nil {
            let inKey = TextNormalizer.identityKey(incoming[j].text)
            let inFirst = String(inKey.prefix(60)), inLast = String(inKey.suffix(60))
            for ei in stillEx where !exUsed[ei] {
                let exKey = TextNormalizer.identityKey(existing[ei].text)
                let ratio = Double(exKey.count) / Double(max(1, inKey.count))
                if ratio < 0.6 || ratio > 1.4 { continue }
                if String(exKey.prefix(60)) == inFirst || String(exKey.suffix(60)) == inLast {
                    recordMatch(ei, j)
                    break
                }
            }
        }

        for ei in 0..<existing.count where !exUsed[ei] { report.retiredIDs.append(existing[ei].id) }
        for j in 0..<incoming.count where report.assignments[j] == nil { report.newIndices.append(j) }

        return report
    }

    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let aT = tokenize(a), bT = tokenize(b)
        guard !aT.isEmpty, !bT.isEmpty else { return 0 }
        let aG = sliding3Gram(aT), bG = sliding3Gram(bT)
        guard !aG.isEmpty, !bG.isEmpty else { return 0 }
        let inter = Set(aG).intersection(Set(bG))
        let uni = Set(aG).union(Set(bG))
        return Double(inter.count) / Double(max(1, uni.count))
    }

    private func tokenize(_ s: String) -> [String] {
        TextNormalizer.identityKey(s).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    private func sliding3Gram(_ tokens: [String]) -> [String] {
        guard tokens.count >= 3 else { return [tokens.joined(separator: " ")] }
        var result: [String] = []
        for i in 0...(tokens.count - 3) {
            result.append(tokens[i..<(i + 3)].joined(separator: " "))
        }
        return result
    }
}
