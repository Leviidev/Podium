import XCTest
@testable import Podium

final class S5L8930XPlatformTests: XCTestCase {
    /// Every modeled device answers at its physical base and at the
    /// `| 0x80000000` alias the kernel actually maps (child address +
    /// `arm-io`'s `0x80000000` range) — here the SWI, whose alias is
    /// where `AppleSamsungSWI` polls.
    func testDevicesAnswerAtBothAliases() throws {
        let cpu = ARMv7CPU(memory: FlatPhysicalMemory(length: 16))
        let platform = S5L8930XPlatform(cpu: cpu)
        let bus = SegmentedMemoryBus(regions: platform.regions)

        try bus.writeWord32(1, at: 0xBF60_0014)
        XCTAssertEqual(try bus.readWord32(at: 0x3F60_0014) & 1, 0)

        try bus.writeWord32(1 << 4, at: 0x8630_0100)
        XCTAssertEqual(try bus.readWord32(at: 0x0630_0100) & (1 << 1), 1 << 1)
    }
}
