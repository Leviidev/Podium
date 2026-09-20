import Foundation

/// Receives abstract input events on behalf of the guest.
protocol InputController: AnyObject {
    func send(_ event: InputEvent)
}
