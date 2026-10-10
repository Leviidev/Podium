import XCTest
import Darwin
@testable import Podium

/// Opt-in integration test. Firmware stays ignored and is never distributed.
final class RealDiskBootTests: XCTestCase {
    func testReferenceFirmwareBootWithFileBackedDisk() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ipsw = repo.appendingPathComponent(".reference-firmware/iPod4,1_6.1.6_10B500_Restore.ipsw")
        guard FileManager.default.fileExists(atPath: ipsw.path) else {
            throw XCTSkip("Real firmware boot is opt-in; import the reference IPSW first.")
        }
        let parsed = try IPSWParser.parse(fileURL: ipsw)
        let firmware = ImportedFirmware(id: UUID(), metadata: parsed.metadata, compatibility: parsed.compatibility,
                                        importedAt: Date(), storedFileName: ipsw.lastPathComponent, isActive: true)
        let bundle = Bundle.main
        let keybag = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "keybag_bootstrap", withExtension: "bin")))
        let sync = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "podium_syncd", withExtension: "bin")))
        let state = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "first_boot_state", withExtension: "plist")))
        let readFiles = try String(contentsOf: XCTUnwrap(bundle.url(forResource: "boot_read_files", withExtension: "txt")), encoding: .utf8)
        let image = try RootFilesystemPreparer.prepare(firmwareAt: ipsw, keybagBootstrap: [UInt8](keybag),
            syncDaemon: [UInt8](sync), firstBootState: state, bootReadFiles: RootFilesystemRecipe.fileList(readFiles))
        let header = try RootFilesystemPreparer.readHFSPlusVolumeHeader(at: image)
        XCTAssertEqual(UInt64(header.totalBlocks) * UInt64(header.blockSize), FileBackedStorage.capacity)
        let kernel = try KernelcacheExtractor.extractKernelMachO(from: firmware, storedAt: ipsw)
        let tree = try DeviceTreeExtractor.extractDeviceTree(from: firmware, storedAt: ipsw)
        if FileManager.default.fileExists(atPath: ipsw.deletingLastPathComponent().appendingPathComponent("trace-buffer-mapping").path) {
            setenv("PODIUM_DISK_TRACE", "1", 1)
        }
        defer { unsetenv("PODIUM_DISK_TRACE") }
        let session = try EmulationSession(kernel: kernel, deviceTree: tree, rootFilesystem: image,
                                           firmwareBuildVersion: parsed.metadata.buildVersion, persistent: true)
        session.start()
        defer { session.stop() }
        var messages = ""
        var lockScreenAppeared = false
        for second in 0..<180 {
            Thread.sleep(forTimeInterval: 1)
            let text = session.newKernelMessages()
            messages += text
            if !text.isEmpty { print("GUEST: \(text)") }
            let snapshot = session.snapshot()
            if second % 5 == 0 { print("BOOTTRACE: t=\(second) instructions=\(snapshot.retiredInstructions) JIT=\(snapshot.jitAvailable) state=\(snapshot.state)") }
            guard snapshot.state == .running else {
                XCTFail("Guest stopped during reference boot: \(snapshot.state); kernel log: \(messages)")
                return
            }
            if EmulatorCore.lockScreenIsUp(session.display) {
                lockScreenAppeared = true
                print("BOOTTRACE: lock screen appeared at t=\(second), instructions=\(snapshot.retiredInstructions)")
                break
            }
        }
        XCTAssertTrue(messages.contains("BSD root") || messages.contains("hfs:"), "The guest must reach its real disk driver: \(messages)")
        XCTAssertTrue(lockScreenAppeared, "The real guest must show its lock screen, not merely keep executing kernel code")
    }
}
