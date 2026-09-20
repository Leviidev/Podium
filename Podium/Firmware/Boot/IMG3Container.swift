import Foundation

enum IMG3Error: FriendlyError {
    case notIMG3
    case truncated
    case missingDataTag

    var userMessage: String {
        "Podium couldn't read this firmware component."
    }

    var developerDetail: String {
        switch self {
        case .notIMG3: return "File does not start with the IMG3 magic (\"Img3\")."
        case .truncated: return "File is shorter than a valid IMG3 container requires."
        case .missingDataTag: return "No DATA tag found while walking the IMG3 tag list."
        }
    }
}

/// Parses Apple's IMG3 firmware container: a small fixed header followed
/// by a sequence of TLV-style tags. Every A4-era firmware component uses
/// this format — most with a `.img3` file extension, though
/// `kernelcache.release.n81` doesn't have one despite being IMG3 too
/// (confirmed directly: its first four bytes are the IMG3 magic).
///
/// This only extracts what Podium needs — the component's 4-character
/// identifier, whether a KBAG tag (encryption key bag) is present, and
/// the DATA tag's payload — not the full tag set (VERS, SHSH, CERT, ...).
struct IMG3Container {
    let identifier: String
    let isEncrypted: Bool
    let payload: Data

    private static let headerSize = 20
    private static let tagHeaderSize = 12

    init(data: Data) throws {
        guard data.count >= Self.headerSize else { throw IMG3Error.truncated }
        guard data.readReversedASCIITag(at: 0, length: 4) == "Img3" else { throw IMG3Error.notIMG3 }

        identifier = data.readReversedASCIITag(at: 16, length: 4)

        var offset = Self.headerSize
        var encrypted = false
        var dataPayload: Data?

        while offset + Self.tagHeaderSize <= data.count {
            let tagMagic = data.readReversedASCIITag(at: offset, length: 4)
            let totalLength = Int(data.readUInt32LE(at: offset + 4))
            guard totalLength >= Self.tagHeaderSize, offset + totalLength <= data.count else { break }

            if tagMagic == "KBAG" {
                encrypted = true
            } else if tagMagic == "DATA" {
                // The true payload length is `totalLength - tagHeaderSize`,
                // *not* the tag's own declared `dataLength` field (the next
                // 4 bytes after totalLength). Verified empirically against
                // the real iPod4,1 6.1.6 kernelcache: for encrypted
                // payloads, `dataLength` undercounts by exactly the number
                // of trailing bytes needed to round the AES-CBC ciphertext
                // down to a whole number of 16-byte blocks — decrypting
                // only `dataLength` bytes silently truncates the final
                // block and corrupts the tail of the decompressed output
                // (caught by an Adler-32 mismatch before this fix; exact
                // match after switching to `totalLength - tagHeaderSize`,
                // which is always block-aligned).
                let payloadStart = offset + Self.tagHeaderSize
                let payloadLength = totalLength - Self.tagHeaderSize
                dataPayload = data.subdata(in: payloadStart..<(payloadStart + payloadLength))
            }

            offset += totalLength
        }

        guard let payload = dataPayload else { throw IMG3Error.missingDataTag }
        self.isEncrypted = encrypted
        self.payload = payload
    }
}
