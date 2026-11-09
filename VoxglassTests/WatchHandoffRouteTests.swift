import Testing
@testable import VoxglassCore

struct WatchHandoffRouteTests {
    @Test func watchLibraryActivityRoutesToLibrary() {
        #expect(WatchHandoffRoute.route(forActivityType: "guru.parso.voxglass.watch.library") == .library)
    }

    @Test func unknownActivityDoesNotRoute() {
        #expect(WatchHandoffRoute.route(forActivityType: "guru.parso.voxglass.other") == nil)
    }
}
