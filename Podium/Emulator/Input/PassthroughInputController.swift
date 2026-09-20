import Foundation

/// Records input events without a guest OS to deliver them to. Exercises
/// the real input pipeline (UI → coordinate mapping → `InputEvent` →
/// here) so that plumbing exists and is testable before there's anything
/// on the other end of it — it does not simulate any guest response.
final class PassthroughInputController: InputController {
    private(set) var lastEvent: InputEvent?

    func send(_ event: InputEvent) {
        lastEvent = event
    }
}
