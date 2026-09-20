import UniformTypeIdentifiers

extension UTType {
    /// IPSWs are ZIP archives with a renamed extension; there's no Apple-
    /// registered UTI for them, so this is synthesized from the file
    /// extension at runtime rather than declared in Info.plist.
    static var ipsw: UTType {
        UTType(filenameExtension: "ipsw") ?? .zip
    }
}
