import Foundation

// MARK: - PackageLock
//
// The exclusive advisory lock (§8.3): `Autosave/lock.json` inside the
// package. A live lock (same device, pid alive) means the project is already
// open — focus its window instead of opening a second. A stale lock (other
// device, or pid gone) is offered "Open anyway" with the iCloud-Drive
// warning: SQLite WAL tolerates concurrent editors, but concurrent
// multi-machine editing of a package in iCloud Drive is a data-loss scenario.

public struct PackageLock: Codable, Sendable, Equatable {
    public var pid: Int32
    public var deviceName: String
    public var openedAt: Date

    public init(pid: Int32, deviceName: String, openedAt: Date) {
        self.pid = pid
        self.deviceName = deviceName
        self.openedAt = openedAt
    }

    public static func live(now: Date = Date()) -> PackageLock {
        PackageLock(
            pid: ProcessInfo.processInfo.processIdentifier,
            deviceName: Host.current().localizedName ?? "unknown device",
            openedAt: now
        )
    }

    /// The pid is alive on this machine.
    public var isAliveLocally: Bool {
        // kill(pid, 0) succeeds for a live process we may signal.
        let result = kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}

public enum PackageLockFile {
    public static func url(in packageRoot: URL) -> URL {
        packageRoot.appendingPathComponent("Autosave/lock.json", isDirectory: false)
    }

    public static func read(from packageRoot: URL) -> PackageLock? {
        let url = url(in: packageRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PackageLock.self, from: data)
    }

    public static func write(to packageRoot: URL) throws {
        let url = url(in: packageRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PackageLock.live())
        try data.write(to: url, options: .atomic)
    }

    public static func remove(from packageRoot: URL) {
        try? FileManager.default.removeItem(at: url(in: packageRoot))
    }

    /// True when a lock is present and live on this machine.
    public static func isHeldHere(_ lock: PackageLock) -> Bool {
        lock.deviceName == (Host.current().localizedName ?? "unknown device") && lock.isAliveLocally
    }
}
