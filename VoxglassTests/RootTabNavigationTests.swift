import Testing
@testable import VoxglassCore

@Suite struct RootTabNavigationTests {
    enum Tab: Equatable { case listen, library, find }

    @Test(arguments: [
        (Tab.listen, Tab.library), (Tab.library, Tab.find), (Tab.find, Tab.listen)
    ])
    func switchingTabDismissesNowPlaying(from: Tab, to: Tab) {
        let r = RootTabNavigation.reduce(selectedTab: from, destination: to, isNowPlayingPresented: true)
        #expect(r.selectedTab == to)
        #expect(r.dismissNowPlaying)
        #expect(r.didChangeSelection)
    }

    @Test func reselectingCurrentTabKeepsSheet() {
        let r = RootTabNavigation.reduce(selectedTab: Tab.listen, destination: .listen, isNowPlayingPresented: true)
        #expect(r.selectedTab == .listen)
        #expect(!r.dismissNowPlaying)
        #expect(!r.didChangeSelection)
    }

    @Test func switchingWithoutSheetSelectsOnly() {
        let r = RootTabNavigation.reduce(selectedTab: Tab.listen, destination: .library, isNowPlayingPresented: false)
        #expect(r.selectedTab == .library)
        #expect(!r.dismissNowPlaying)
        #expect(r.didChangeSelection)
    }
}
