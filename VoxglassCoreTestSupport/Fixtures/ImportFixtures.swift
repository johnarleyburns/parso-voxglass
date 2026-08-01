import Foundation

/// Builds minimal valid EPUB and DOCX files for importer tests (§19.3: one
/// fixture per format with a known expected chapter/paragraph shape).
public enum ImportFixtures {

    /// A minimal EPUB with two spine items: the first opens with an H1
    /// (chapter title), the second is prose-only.
    public static func makeEPUB(named name: String = "fixture.epub", in dir: URL) throws -> URL {
        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let opfXML = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookID">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>The EPUB Fixture</dc:title>
            <dc:creator>Fixture Author</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """

        let ch1XHTML = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Chapter One</title></head>
          <body>
            <h1>Chapter One</h1>
            <p>This is the first paragraph of chapter one.</p>
            <p>This is the second paragraph of chapter one.</p>
          </body>
        </html>
        """

        let ch2XHTML = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Interlude</title></head>
          <body>
            <p>An interlude that opens with prose, not a heading.</p>
            <p>More prose follows here.</p>
          </body>
        </html>
        """

        let url = dir.appendingPathComponent(name)
        try TestZipWriter.write(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opfXML.utf8)),
            ("OEBPS/ch1.xhtml", Data(ch1XHTML.utf8)),
            ("OEBPS/ch2.xhtml", Data(ch2XHTML.utf8)),
        ], to: url)
        return url
    }

    /// A minimal DOCX with one heading-styled paragraph and two body
    /// paragraphs.
    public static func makeDOCX(named name: String = "fixture.docx", in dir: URL) throws -> URL {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter One</w:t></w:r></w:p>
            <w:p><w:r><w:t>This is the first paragraph of the document.</w:t></w:r></w:p>
            <w:p><w:r><w:t>This is the second paragraph of the document.</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """

        let url = dir.appendingPathComponent(name)
        try TestZipWriter.write(entries: [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="xml" ContentType="application/xml"/>
            </Types>
            """.utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
        ], to: url)
        return url
    }
}
