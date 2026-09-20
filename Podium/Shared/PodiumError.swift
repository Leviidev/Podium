import Foundation

/// An error with a message written for the person using the app, plus
/// optional technical detail for the collapsible "Details" disclosure.
///
/// Every user-facing error path in Podium should produce one of these
/// rather than surfacing a raw system or parsing error directly.
protocol FriendlyError: Error {
    /// Short, plain-language explanation. No error codes, no jargon.
    var userMessage: String { get }
    /// Technical detail shown only behind "Details". May be empty.
    var developerDetail: String { get }
}

extension FriendlyError {
    var developerDetail: String { "" }
}
