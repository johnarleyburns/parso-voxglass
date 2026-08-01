import Foundation

struct DirectFormFilter {
    private let b: [Double]
    private let a: [Double]
    private var v: [Double]

    init(b: [Double], a: [Double]) {
        precondition(b.count == a.count, "b and a must have equal count")
        precondition(a[0] == 1.0, "a[0] must be 1")
        self.b = b
        self.a = a
        self.v = [Double](repeating: 0, count: b.count - 1)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b[0] * x + v[0]
        let n = v.count
        var k = 0
        while k < n - 1 {
            v[k] = b[k + 1] * x - a[k + 1] * y + v[k + 1]
            k += 1
        }
        v[n - 1] = b[n] * x - a[n] * y
        return y
    }

    mutating func reset() {
        for i in v.indices { v[i] = 0 }
    }
}
