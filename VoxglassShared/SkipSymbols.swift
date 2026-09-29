import UIKit

enum SkipSymbols {
    static func back(_ seconds: Int) -> String {
        UIImage(systemName: "gobackward.\(seconds)") != nil ? "gobackward.\(seconds)" : "gobackward.15"
    }

    static func forward(_ seconds: Int) -> String {
        UIImage(systemName: "goforward.\(seconds)") != nil ? "goforward.\(seconds)" : "goforward.30"
    }
}
