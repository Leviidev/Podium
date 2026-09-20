import Foundation

/// A `NetworkInterface` that provides no connectivity: sent packets are
/// dropped and nothing is ever received. Networking is explicitly a stub
/// for now (Section 20 of the project spec); this makes that stance
/// concrete instead of leaving networking silently unimplemented.
final class NullNetworkInterface: NetworkInterface {
    var onReceive: ((Data) -> Void)?

    func send(_ packet: Data) {}
}
