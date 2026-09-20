import Foundation

/// Controlled network access for the guest. The guest never gets direct
/// access to the host's networking stack (Section 20 of the project
/// spec) — everything passes through here.
protocol NetworkInterface: AnyObject {
    func send(_ packet: Data)
    var onReceive: ((Data) -> Void)? { get set }
}
