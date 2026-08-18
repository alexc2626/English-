import XCTest
@testable import PhotonCore

final class NamingTemplateTests: XCTestCase {

    private var context: NamingTemplate.Context {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 14
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        return .init(originalName: "IMG_4021", sequence: 7, captureDate: date,
                     rating: 4, camera: "Canon EOS R5", iso: 800)
    }

    func testPlainName() {
        XCTAssertEqual(NamingTemplate(template: "{name}").render(context), "IMG_4021")
    }

    func testSequencePadding() {
        XCTAssertEqual(NamingTemplate(template: "{name}-{seq:4}").render(context),
                       "IMG_4021-0007")
        XCTAssertEqual(NamingTemplate(template: "{seq}").render(context), "7")
    }

    func testDateFormatting() {
        XCTAssertEqual(NamingTemplate(template: "{date:yyyyMMdd}").render(context), "20260314")
        XCTAssertEqual(NamingTemplate(template: "{date}").render(context), "2026-03-14")
    }

    func testCombinedTemplate() {
        let t = NamingTemplate(template: "{date:yyyy}/{name}_{seq:3}_{rating}star")
        // '/' is sanitised out of file names.
        XCTAssertEqual(t.render(context), "2026_IMG_4021_007_4star")
    }

    func testUnknownTokenPassesThrough() {
        XCTAssertEqual(NamingTemplate(template: "{name}-{bogus}").render(context),
                       "IMG_4021-{bogus}")
    }

    func testMetadataTokens() {
        XCTAssertEqual(NamingTemplate(template: "{camera} ISO{iso}").render(context),
                       "Canon EOS R5 ISO800")
    }

    func testUnterminatedBraceIsLiteral() {
        XCTAssertEqual(NamingTemplate(template: "{name}-{seq").render(context), "IMG_4021-{seq")
    }
}
