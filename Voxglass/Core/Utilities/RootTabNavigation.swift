/// Pure policy for explicit tab navigation while the global Now Playing sheet
/// may be presented. Navigation never touches playback state.
public enum RootTabNavigation {
    public struct Result<Tab: Equatable>: Equatable {
        public let selectedTab: Tab
        public let dismissNowPlaying: Bool
        public let didChangeSelection: Bool
    }

    public static func reduce<Tab: Equatable>(
        selectedTab: Tab,
        destination: Tab,
        isNowPlayingPresented: Bool
    ) -> Result<Tab> {
        guard destination != selectedTab else {
            return Result(selectedTab: selectedTab, dismissNowPlaying: false, didChangeSelection: false)
        }
        return Result(selectedTab: destination, dismissNowPlaying: isNowPlayingPresented, didChangeSelection: true)
    }
}
