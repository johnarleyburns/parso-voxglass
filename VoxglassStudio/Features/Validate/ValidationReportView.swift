import SwiftUI
import VoxglassCore

/// Validation Report (spec §18.1.14): target picker, severity sidebar with
/// counts, an eligibility panel, and the issue list with per-issue fixes.
public struct ValidationReportView: View {
    @Bindable var model: ValidationModel

    public init(model: ValidationModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isEvaluating {
                ProgressView("Validating…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView("Validation failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.report == nil {
                ContentUnavailableView("Run validation", systemImage: "checkmark.seal", description: Text("Choose a destination and run validation to check this project against its rules."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if model.report == nil {
                Task { await model.evaluate() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Label("Validation", systemImage: "checkmark.seal")
                .font(.headline)

            Picker("Destination", selection: $model.target) {
                ForEach(DestinationID.allCases, id: \.self) { destination in
                    Text(DestinationProfile.profile(for: destination).displayName)
                        .tag(destination)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)
            .accessibilityIdentifier("validate.target.\(model.target.rawValue)")

            Button("Run Again") {
                Task { await model.evaluate() }
            }
            .accessibilityIdentifier("validate.runAgain")

            Spacer()

            if let eligibility = model.eligibility {
                eligibilityChip(eligibility)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func eligibilityChip(_ eligibility: EligibilityProfile) -> some View {
        Group {
            if eligibility.librivoxEligible {
                Label("LibriVox eligible", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("LibriVox ineligible · \(eligibility.aiParagraphCount) AI paragraph\(eligibility.aiParagraphCount == 1 ? "" : "s")", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
    }

    // MARK: - Content

    private var content: some View {
        HStack(spacing: 0) {
            severitySidebar
            Divider()
            issueList
        }
    }

    private var severitySidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)
            severityRow("Blocking", count: model.blockingCount, color: .red, severity: .blocking)
            severityRow("Warnings", count: model.warningCount, color: .orange, severity: .warning)
            severityRow("Passed", count: model.passedCount, color: .green, severity: .passed)
            Divider()
            Text("Eligibility")
                .font(.headline)
            Text("\(model.report?.eligibility.humanParagraphCount ?? 0) human · \(model.report?.eligibility.aiParagraphCount ?? 0) AI")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(width: 180)
    }

    private func severityRow(_ label: String, count: Int, color: Color, severity: Severity) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text("\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("validate.severity.\(severity.rawValue)")
    }

    private var issueList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if model.issues.isEmpty {
                    Label("No issues — this project passes validation for the selected destination.", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                        .padding(12)
                }
                ForEach(Array(model.issues.enumerated()), id: \.element.id) { index, issue in
                    issueRow(issue, index: index)
                }
            }
            .padding(16)
        }
    }

    private func issueRow(_ issue: ValidationIssue, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .blocking ? .red : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.subheadline.weight(.semibold))
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let expected = issue.expected {
                    Text("Expected: \(expected)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let fix = issue.fix {
                    Text("Fix: \(fixLabel(fix))")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            Spacer()
            Text(issue.code.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
        .accessibilityIdentifier("validate.issue.\(index)")
    }

    private func fixLabel(_ fix: FixAction) -> String {
        switch fix {
        case .goToParagraph, .recordParagraph: return "record paragraph"
        case .goToChapter: return "go to chapter"
        case .openMetadata: return "open metadata"
        case .openRights: return "open rights"
        case .selectTake: return "select take"
        case .regenerateDisclaimers: return "regenerate disclaimers"
        case .regenerateCredits: return "regenerate credits"
        case .applyMastering: return "apply mastering"
        case .splitChapter: return "split chapter"
        case .chooseArtwork: return "choose artwork"
        case .setRetailSample: return "set retail sample"
        case .reanalyzeTake: return "re-analyze take"
        case .clearPickup: return "clear pickup"
        }
    }
}
