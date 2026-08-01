import Foundation

public struct PackageManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var packageFormatVersion: Int
    public var projectID: UUID
    public var title: String
    public var author: String
    public var narrator: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var appVersion: String
    public var lastOpenedByDeviceName: String?

    public static let currentPackageFormatVersion = 1

    public init(
        schemaVersion: Int,
        packageFormatVersion: Int = currentPackageFormatVersion,
        projectID: UUID,
        title: String,
        author: String,
        narrator: String,
        createdAt: Date,
        modifiedAt: Date,
        appVersion: String,
        lastOpenedByDeviceName: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.packageFormatVersion = packageFormatVersion
        self.projectID = projectID
        self.title = title
        self.author = author
        self.narrator = narrator
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.appVersion = appVersion
        self.lastOpenedByDeviceName = lastOpenedByDeviceName
    }
}
