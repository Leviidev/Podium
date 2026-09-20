import XCTest
@testable import Podium

final class IMG3ContainerTests: XCTestCase {
    private func appendReversedTag(_ tag: String, to data: inout Data) {
        data.append(Data(Array(tag.utf8).reversed()))
    }

    private func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func makeIMG3(
        ident: String,
        payload: Data,
        includeKBAG: Bool,
        declaredDataLengthOverride: UInt32? = nil
    ) -> Data {
        var tags = Data()

        var typeTag = Data()
        appendReversedTag("TYPE", to: &typeTag)
        appendLE32(32, to: &typeTag)
        appendLE32(4, to: &typeTag)
        appendReversedTag(ident, to: &typeTag)
        typeTag.append(Data(repeating: 0, count: 32 - typeTag.count))
        tags.append(typeTag)

        if includeKBAG {
            var kbagTag = Data()
            appendReversedTag("KBAG", to: &kbagTag)
            appendLE32(12, to: &kbagTag)
            appendLE32(0, to: &kbagTag)
            tags.append(kbagTag)
        }

        var dataTag = Data()
        appendReversedTag("DATA", to: &dataTag)
        let totalLength = UInt32(12 + payload.count)
        appendLE32(totalLength, to: &dataTag)
        appendLE32(declaredDataLengthOverride ?? UInt32(payload.count), to: &dataTag)
        dataTag.append(payload)
        tags.append(dataTag)

        var header = Data()
        appendReversedTag("Img3", to: &header)
        appendLE32(UInt32(20 + tags.count), to: &header)
        appendLE32(UInt32(tags.count), to: &header)
        appendLE32(UInt32(tags.count), to: &header)
        appendReversedTag(ident, to: &header)

        return header + tags
    }

    func testParsesIdentifierAndUnencryptedPayload() throws {
        let payload = Data("hello".utf8)
        let file = makeIMG3(ident: "krnl", payload: payload, includeKBAG: false)

        let container = try IMG3Container(data: file)
        XCTAssertEqual(container.identifier, "krnl")
        XCTAssertFalse(container.isEncrypted)
        XCTAssertEqual(container.payload, payload)
    }

    func testDetectsKBAGAsEncrypted() throws {
        let payload = Data(repeating: 0xAB, count: 16)
        let file = makeIMG3(ident: "krnl", payload: payload, includeKBAG: true)

        let container = try IMG3Container(data: file)
        XCTAssertTrue(container.isEncrypted)
    }

    func testPayloadLengthUsesTotalLengthMinusTagHeaderNotDeclaredDataLength() throws {
        // Deliberately declares a too-small dataLength, matching what the
        // real encrypted iPod4,1 6.1.6 kernelcache does. IMG3Container
        // must trust totalLength - 12 (always block-aligned for AES),
        // not this field — see IMG3Container's own doc comment for how
        // that was discovered.
        let payload = Data(repeating: 0xCD, count: 32)
        let file = makeIMG3(ident: "krnl", payload: payload, includeKBAG: false, declaredDataLengthOverride: 4)

        let container = try IMG3Container(data: file)
        XCTAssertEqual(container.payload, payload)
    }

    func testExposesDeclaredDataLengthSeparatelyFromPayload() throws {
        // Mirrors the real DeviceTree.n81ap.img3 shape: a declared
        // length smaller than the block-aligned payload, by exactly
        // the AES padding remainder.
        let payload = Data(repeating: 0xEF, count: 32)
        let file = makeIMG3(ident: "dtre", payload: payload, includeKBAG: false, declaredDataLengthOverride: 28)

        let container = try IMG3Container(data: file)
        XCTAssertEqual(container.payload, payload)
        XCTAssertEqual(container.declaredDataLength, 28)
    }

    func testRejectsNonIMG3Data() {
        let bogus = Data(repeating: 0, count: 64)
        XCTAssertThrowsError(try IMG3Container(data: bogus)) { error in
            guard case IMG3Error.notIMG3 = error else {
                return XCTFail("Expected .notIMG3, got \(error)")
            }
        }
    }

    func testTruncatedDataThrows() {
        let tooShort = Data(repeating: 0, count: 10)
        XCTAssertThrowsError(try IMG3Container(data: tooShort)) { error in
            guard case IMG3Error.truncated = error else {
                return XCTFail("Expected .truncated, got \(error)")
            }
        }
    }
}
