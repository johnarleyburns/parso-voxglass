import Foundation

/// The product's legal-safety strings (§3.6). They are the product's liability
/// boundary and MUST NOT be reworded without review. They appear verbatim in
/// the UI and in generated checklists, and are centralized here so CI gate
/// G-11 (literal strings only in this file) can be enforced.
public enum LegalStrings {
    /// §3.2.7 / §3.6 — shown beside any rights UI and in every export checklist.
    public static let noCopyrightDetermination = "Voxglass does not determine copyright status."
    /// §3.6 — Export wizard footer (mockup `14-export-wizard`).
    public static let noAcceptanceGuarantee = "Voxglass prepares files; it does not guarantee acceptance or determine copyright."
    /// §3.2.6 / §3.6 — LibriVox card when ineligible; validation issue detail.
    public static let librivoxHumanOnly = "LibriVox accepts only recordings made by human volunteers using their own voices. This project contains imported AI-generated audio and is not eligible."
    /// §3.6 — every export completion screen.
    public static let userSubmits = "You submit these files yourself. Voxglass never uploads on your behalf."
    /// §3.3.2 / §3.6 — IA manifest `notes`; retail `delivery-metadata.json`.
    public static let aiDisclosure = "Contains narration generated or processed with AI voice technology."
}
