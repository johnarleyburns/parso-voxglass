import Testing
import VoxglassPortable

@Suite struct InternetArchiveURLParserTests {
    @Test func archiveURLParserRecognizesItemMetadataDownloadAndSearchURLs() {
        #expect(InternetArchiveURLParser.parse("https://archive.org/details/pride_and_prejudice_librivox") == .identifier("pride_and_prejudice_librivox"))
        #expect(InternetArchiveURLParser.parse("archive.org/metadata/pride_and_prejudice_librivox") == .identifier("pride_and_prejudice_librivox"))
        #expect(InternetArchiveURLParser.parse("https://archive.org/download/pride_and_prejudice_librivox/01%20Chapter%20One.mp3") == .identifier("pride_and_prejudice_librivox"))
        #expect(InternetArchiveURLParser.parse("https://archive.org/advancedsearch.php?q=collection%3A%28librivoxaudio%29") == .advancedSearch(query: "collection:(librivoxaudio)"))
    }
}
