import Foundation

/// Translates virtual addresses to physical addresses.
///
/// No implementation exists yet. The eventual ARMv7 MMU needs to model
/// short-descriptor translation tables, domain access control, and the
/// TLB; none of that is safe to approximate, so this stays a contract
/// until it's built for real.
protocol MMU: AnyObject {
    func translate(virtualAddress: UInt32) throws -> UInt32
    func invalidateTLB()
}

enum MMUError: Error {
    case translationFault(virtualAddress: UInt32)
    case permissionFault(virtualAddress: UInt32)
}
