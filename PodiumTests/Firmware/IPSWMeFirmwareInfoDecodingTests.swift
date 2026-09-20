import XCTest
@testable import Podium

/// Decodes a real, captured response from `api.ipsw.me/v4/ipsw/iPod4,1/10B500`
/// rather than a hand-written fixture, so this fails if the app's model
/// ever drifts from what the live API actually returns.
final class IPSWMeFirmwareInfoDecodingTests: XCTestCase {
    private static let capturedResponse = """
    {"identifier":"iPod4,1","version":"6.1.6","buildid":"10B500","sha1sum":"693bb78c8f6baf4186f7797bf3a0ef7d3b18255e","md5sum":"fe7544a1de32b7454ef8cdac355112d3","sha256sum":"1f6096c3298c87172f431e4924a4cf3c53298e5920f4b6c817929aa32d90c5ff","filesize":888894104,"url":"https://secure-appldnld.apple.com/iOS6.1/031-3211.20140221.Placef/iPod4,1_6.1.6_10B500_Restore.ipsw","releasedate":"2014-02-21T17:51:30Z","uploaddate":"2014-02-18T20:35:13Z","signed":true}
    """

    func testDecodesReferenceFirmwareResponse() throws {
        let info = try JSONDecoder().decode(IPSWMeFirmwareInfo.self, from: Data(Self.capturedResponse.utf8))

        XCTAssertEqual(info.identifier, "iPod4,1")
        XCTAssertEqual(info.version, "6.1.6")
        XCTAssertEqual(info.buildid, "10B500")
        XCTAssertEqual(info.sha256sum, "1f6096c3298c87172f431e4924a4cf3c53298e5920f4b6c817929aa32d90c5ff")
        XCTAssertEqual(info.filesize, 888_894_104)
        XCTAssertEqual(info.url, URL(string: "https://secure-appldnld.apple.com/iOS6.1/031-3211.20140221.Placef/iPod4,1_6.1.6_10B500_Restore.ipsw"))
    }

    func testExtraUnknownFieldsDontBreakDecoding() throws {
        // The live response has fields (sha1sum, md5sum, releasedate, ...)
        // this model doesn't use. Confirms Decodable's default behavior
        // of ignoring unrecognized keys is actually what's happening here.
        XCTAssertNoThrow(try JSONDecoder().decode(IPSWMeFirmwareInfo.self, from: Data(Self.capturedResponse.utf8)))
    }
}
