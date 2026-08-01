import Foundation

public protocol VoxglassError: Error, Sendable {
    var code: String { get }
    var userMessage: String { get }
    var isRecoverable: Bool { get }
    var underlying: (any Error)? { get }
}

public enum PackageError: VoxglassError {
    case notAPackage(URL)
    case schemaTooNew(Int)
    case missingAsset(AudioAssetReference)
    case corruptManifest
    case autosaveConflict
    case diskFull(needBytes: Int64)

    public var code: String {
        switch self {
        case .notAPackage: "PKG.NOT_A_PACKAGE"
        case .schemaTooNew: "PKG.SCHEMA_TOO_NEW"
        case .missingAsset: "PKG.MISSING_ASSET"
        case .corruptManifest: "PKG.CORRUPT_MANIFEST"
        case .autosaveConflict: "PKG.AUTOSAVE_CONFLICT"
        case .diskFull: "PKG.DISK_FULL"
        }
    }

    public var userMessage: String {
        switch self {
        case .notAPackage(let url): "The file \"\(url.lastPathComponent)\" is not a Voxglass project package."
        case .schemaTooNew(let schema): "This project was created by a newer version of Voxglass (schema version \(schema)). Please update the app."
        case .missingAsset(let ref): "The audio asset referenced at \"\(ref.sha256)\" is missing from the project."
        case .corruptManifest: "The project manifest is corrupted and cannot be read."
        case .autosaveConflict: "An autosave session is in conflict with the current project state."
        case .diskFull(let need): "Not enough disk space. Need \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) more."
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .diskFull, .missingAsset: true
        default: false
        }
    }

    public var underlying: (any Error)? { nil }
}
