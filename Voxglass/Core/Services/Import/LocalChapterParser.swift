import Foundation

/// A timestamped chapter entry from a sidecar text file.
public struct LocalChapterMarker: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let startTime: TimeInterval

    public init(number: Int, title: String, startTime: TimeInterval) {
        self.number = number
        self.title = title
        self.startTime = startTime
    }
}

public enum LocalChapterParserError: Error, LocalizedError, Equatable, Sendable {
    case noChapters
    case malformedLine(String)
    case nonIncreasingTimestamps

    public var errorDescription: String? {
        switch self {
        case .noChapters:
            return "The chapter text file does not contain any chapter lines."
        case .malformedLine(let line):
            return "Couldn't read chapter line: \"\(line)\". Use Chapter <n>: <title> <hh:mm:ss>."
        case .nonIncreasingTimestamps:
            return "Chapter timestamps must increase from one chapter to the next."
        }
    }
}

public enum LocalChapterParser {
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\s*Chapter\s+(\d+)\s*:\s*(.*?)\s+(\d{1,2}:\d{2}:\d{2}|\d{1,3}:\d{2})\s*$"#
    )

    public static func parse(_ text: String) throws -> [LocalChapterMarker] {
        var markers: [LocalChapterMarker] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = linePattern.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let titleRange = Range(match.range(at: 2), in: line),
                  let timestampRange = Range(match.range(at: 3), in: line) else {
                throw LocalChapterParserError.malformedLine(line)
            }
            let number = Int(line[numberRange])!
            let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamp = try parseTimestamp(String(line[timestampRange]))
            guard !title.isEmpty else { throw LocalChapterParserError.malformedLine(line) }
            if let previous = markers.last, timestamp <= previous.startTime {
                throw LocalChapterParserError.nonIncreasingTimestamps
            }
            markers.append(LocalChapterMarker(number: number, title: title, startTime: timestamp))
        }
        guard !markers.isEmpty else { throw LocalChapterParserError.noChapters }
        return markers
    }

    public static func parseTimestamp(_ raw: String) throws -> TimeInterval {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else {
            throw LocalChapterParserError.malformedLine(raw)
        }
        let hours: Int
        let minutes: Int
        let seconds: Int
        if parts.count == 3 {
            hours = parts[0]; minutes = parts[1]; seconds = parts[2]
        } else {
            hours = 0; minutes = parts[0]; seconds = parts[1]
        }
        guard minutes < 60, seconds < 60 else {
            throw LocalChapterParserError.malformedLine(raw)
        }
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }
}
