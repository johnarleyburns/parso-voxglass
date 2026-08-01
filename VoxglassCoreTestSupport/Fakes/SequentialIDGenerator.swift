import Foundation
import VoxglassCore

public final class SequentialIDGenerator: IDGenerator, @unchecked Sendable {
    private let storage = NSLock()
    private var counter: Int = 0

    public init() {}

    public func next() -> UUID {
        storage.lock()
        counter += 1
        let c = counter
        storage.unlock()

        let bytes: [UInt8] = [
            UInt8((c >> 56) & 0xFF), UInt8((c >> 48) & 0xFF),
            UInt8((c >> 40) & 0xFF), UInt8((c >> 32) & 0xFF),
            UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF),
            UInt8((c >> 8) & 0xFF),  UInt8(c & 0xFF),
            0, 0, 0, 0, 0, 0, 0, 0
        ]
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
