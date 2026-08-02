import Foundation

/// Renders a `ValidationReport` to JSON, self-contained HTML, and plain text
/// (§15.5). The HTML report is printable, single-file, and never embeds
/// paragraph text beyond the 90-character snippets that appear in issue
/// messages (NDA safety).
public struct ValidationReportRenderer: Sendable {

    public init() {}

    /// Deterministic JSON (sorted keys, ISO-8601 dates).
    public func json(_ report: ValidationReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    /// Self-contained, printable HTML with no external assets.
    public func html(_ report: ValidationReport) -> String {
        let rows = report.issues
            .sorted { ($0.severity, $0.code.rawValue) < ($1.severity, $1.code.rawValue) }
            .map(htmlRow)
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Validation report — \(escaped(report.projectTitle))</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #222; }
          h1 { font-size: 1.4rem; } h2 { font-size: 1.1rem; margin-top: 1.5rem; }
          table { border-collapse: collapse; width: 100%; margin-top: 0.75rem; }
          th, td { border: 1px solid #ddd; padding: 0.4rem 0.6rem; text-align: left; font-size: 0.9rem; vertical-align: top; }
          th { background: #f4f4f4; }
          .blocking { color: #b00020; font-weight: 600; } .warning { color: #b26a00; } .passed { color: #1a7f37; }
          .summary { display: flex; gap: 2rem; margin: 0.5rem 0; }
          .chip { padding: 0.2rem 0.6rem; border-radius: 999px; background: #eee; }
        </style>
        </head>
        <body>
          <h1>Voxglass validation report</h1>
          <p><strong>Project:</strong> \(escaped(report.projectTitle)) · <strong>Destination:</strong> \(escaped(report.destination.rawValue))</p>
          <p><strong>Generated:</strong> \(dateText(report.generatedAt)) · <strong>App:</strong> \(escaped(report.appVersion)) · <strong>Analyzer:</strong> v\(report.analyzerVersion)</p>
          <h2>Summary</h2>
          <div class="summary">
            <span class="chip blocking">\(report.summary.blocking) blocking</span>
            <span class="chip warning">\(report.summary.warnings) warnings</span>
            <span class="chip passed">\(report.summary.passed) passed</span>
          </div>
          <p>\(report.summary.totalParagraphs) paragraphs, \(report.summary.recordedParagraphs) recorded · \(durationText(report.summary.totalDuration)) total · \(report.summary.chaptersOverMaxDuration) chapter(s) over the maximum duration.</p>
          <h2>Eligibility</h2>
          <p>Narration origin: \(escaped(report.eligibility.narrationOrigin.rawValue)) · LibriVox eligible: \(report.eligibility.librivoxEligible ? "yes" : "no") · \(report.eligibility.humanParagraphCount) human / \(report.eligibility.aiParagraphCount) AI paragraphs.</p>
          <h2>Issues</h2>
          <table>
            <thead><tr><th>Severity</th><th>Code</th><th>Issue</th><th>Details</th><th>Measured</th><th>Expected</th></tr></thead>
            <tbody>
        \(rows)
            </tbody>
          </table>
        </body>
        </html>
        """
    }

    /// Plain-text form used by submission checklists.
    public func plainText(_ report: ValidationReport) -> String {
        var lines: [String] = []
        lines.append("Validation report — \(report.projectTitle) (\(report.destination.rawValue))")
        lines.append("Generated \(dateText(report.generatedAt)) · app \(report.appVersion) · analyzer v\(report.analyzerVersion)")
        lines.append("\(report.summary.blocking) blocking, \(report.summary.warnings) warnings, \(report.summary.passed) passed")
        lines.append("Eligibility: \(report.eligibility.narrationOrigin.rawValue) · LibriVox eligible: \(report.eligibility.librivoxEligible ? "yes" : "no")")
        lines.append("")
        for issue in report.issues.sorted(by: { $0.severity < $1.severity && $0.code.rawValue < $1.code.rawValue }) {
            let expected = issue.expected.map { " expected \($0)" } ?? ""
            let measured = issue.measured.map { String(format: " measured %.2f", $0) } ?? ""
            lines.append("[\(issue.severity.rawValue.uppercased())] \(issue.code.rawValue): \(issue.title) — \(issue.message)\(measured)\(expected)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    private func htmlRow(_ issue: ValidationIssue) -> String {
        let severity = "\(issue.severity.rawValue)"
        let measured = issue.measured.map { String(format: "%.2f", $0) } ?? ""
        let expected = issue.expected.map(escaped) ?? ""
        return """
            <tr>
              <td class="\(severity)">\(severity.uppercased())</td>
              <td><code>\(escaped(issue.code.rawValue))</code></td>
              <td>\(escaped(issue.title))</td>
              <td>\(escaped(issue.message))</td>
              <td>\(measured)</td>
              <td>\(expected)</td>
            </tr>
        """
    }

    private func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
