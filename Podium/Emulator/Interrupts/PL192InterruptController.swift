import Foundation

/// The A4's interrupt controller: four ARM PrimeCell PL192 VICs, each
/// serving 32 interrupt lines, at 64KB strides from the device tree's
/// `vic` base (`0x3F200000`, size `0x40000`). Line N belongs to VIC
/// `N / 32`, bit `N % 32` — the numbering every device tree
/// `interrupts` property uses. Register behavior follows ARM DDI 0273
/// (PL192 TRM), including vectored priority: reading `VICADDRESS` hands
/// out the highest-priority pending IRQ and masks equal-or-lower
/// priorities until it's written back (end of interrupt).
///
/// Outputs are OR-ed across the four VICs into the CPU's IRQ and FIQ
/// pins, but `VICADDRESS` follows the daisy chain (VIC0 first): the
/// kernel's AppleARMPL192VIC reads only VIC0's `VICADDRESS` to find the
/// line, then — for a line in VIC k ≥ 2 — VIC1…VIC(k-1)'s, and ends the
/// interrupt by writing VIC k…VIC0's. A read on VIC n hands out its own
/// best line, or, when VIC n+1 has something that outranks it (at
/// `VICPRIORITYDAISY`), VIC n+1's hand-out, marking the daisy slot in
/// service on VIC n.
final class PL192InterruptController: MMIODevice {
    static let vicCount = 4
    static let vicStride: UInt32 = 0x1_0000
    static let windowLength: UInt32 = UInt32(vicCount) * vicStride

    private final class VIC {
        var hardwareLines: UInt32 = 0
        var softInterrupts: UInt32 = 0
        var intSelect: UInt32 = 0
        var intEnable: UInt32 = 0
        var protection: UInt32 = 0
        var softwarePriorityMask: UInt32 = 0xFFFF
        var priorityDaisy: UInt32 = 0xF
        var vectorAddress = [UInt32](repeating: 0, count: 32)
        var vectorPriority = [UInt32](repeating: 0xF, count: 32)
        /// Priorities currently being serviced (pushed by a `VICADDRESS`
        /// read, popped by a write to it).
        var inService: [UInt32] = []
        var lastHandedOutAddress: UInt32 = 0

        var raw: UInt32 { hardwareLines | softInterrupts }
        var irqStatus: UInt32 { raw & intEnable & ~intSelect }
        var fiqStatus: UInt32 { raw & intEnable & intSelect }

        /// IRQ sources allowed to interrupt right now: enabled, not
        /// masked by software priority, and strictly higher priority
        /// (lower number) than whatever is currently in service.
        var deliverableIRQs: UInt32 {
            let ceiling = inService.last ?? 16
            var result: UInt32 = 0
            var pending = irqStatus
            while pending != 0 {
                let line = pending.trailingZeroBitCount
                pending &= pending - 1
                let priority = vectorPriority[line] & 0xF
                if priority < ceiling, softwarePriorityMask & (1 << priority) != 0 {
                    result |= 1 << line
                }
            }
            return result
        }
    }

    private let vics = (0..<vicCount).map { _ in VIC() }
    private let outputsChanged: (_ irq: Bool, _ fiq: Bool) -> Void

    init(outputsChanged: @escaping (_ irq: Bool, _ fiq: Bool) -> Void) {
        self.outputsChanged = outputsChanged
    }

    /// Asserts or deasserts hardware interrupt line `line` (0..<128).
    func setLine(_ line: Int, asserted: Bool) {
        let vic = vics[line / 32]
        let bit: UInt32 = 1 << UInt32(line % 32)
        let updated = asserted ? vic.hardwareLines | bit : vic.hardwareLines & ~bit
        guard updated != vic.hardwareLines else { return }
        vic.hardwareLines = updated
        updateOutputs()
    }

    func readRegister(at offset: UInt32) -> UInt32 {
        let vic = vics[Int(offset / Self.vicStride)]
        let register = offset % Self.vicStride
        switch register {
        case 0x000: return vic.irqStatus
        case 0x004: return vic.fiqStatus
        case 0x008: return vic.raw
        case 0x00C: return vic.intSelect
        case 0x010: return vic.intEnable
        case 0x018: return vic.softInterrupts
        case 0x020: return vic.protection
        case 0x024: return vic.softwarePriorityMask
        case 0x028: return vic.priorityDaisy
        case 0x100..<0x180: return vic.vectorAddress[Int((register - 0x100) / 4)]
        case 0x200..<0x280: return vic.vectorPriority[Int((register - 0x200) / 4)]
        case 0xF00: return handOutHighestPriorityIRQ(from: Int(offset / Self.vicStride))
        case 0xFE0: return 0x92
        case 0xFE4: return 0x11
        case 0xFE8: return 0x04
        case 0xFEC: return 0x00
        case 0xFF0: return 0x0D
        case 0xFF4: return 0xF0
        case 0xFF8: return 0x05
        case 0xFFC: return 0xB1
        default: return 0
        }
    }

    func writeRegister(_ value: UInt32, at offset: UInt32) {
        let vic = vics[Int(offset / Self.vicStride)]
        let register = offset % Self.vicStride
        switch register {
        case 0x00C: vic.intSelect = value
        case 0x010: vic.intEnable |= value
        case 0x014: vic.intEnable &= ~value
        case 0x018: vic.softInterrupts |= value
        case 0x01C: vic.softInterrupts &= ~value
        case 0x020: vic.protection = value & 1
        case 0x024: vic.softwarePriorityMask = value & 0xFFFF
        case 0x028: vic.priorityDaisy = value & 0xF
        case 0x100..<0x180: vic.vectorAddress[Int((register - 0x100) / 4)] = value
        case 0x200..<0x280: vic.vectorPriority[Int((register - 0x200) / 4)] = value & 0xF
        case 0xF00: _ = vic.inService.popLast()
        default: return
        }
        updateOutputs()
    }

    /// `VICADDRESS` read on VIC `index`: the vector address of the
    /// highest-priority deliverable IRQ (lowest priority number, then
    /// lowest line) among its own lines and whatever the rest of the
    /// daisy chain offers, which then counts as in service. With nothing
    /// deliverable, the last address handed out is returned unchanged.
    private func handOutHighestPriorityIRQ(from index: Int) -> UInt32 {
        let vic = vics[index]
        let own = bestDeliverable(in: vic)
        let daisyPriority = vic.priorityDaisy & 0xF
        let ceiling = vic.inService.last ?? 16
        let chainOffers = index + 1 < vics.count && chainHasDeliverable(from: index + 1)
            && daisyPriority < ceiling && vic.softwarePriorityMask & (1 << daisyPriority) != 0
        if let own, !chainOffers || own.priority <= daisyPriority {
            vic.inService.append(own.priority)
            vic.lastHandedOutAddress = vic.vectorAddress[own.line]
        } else if chainOffers {
            vic.inService.append(daisyPriority)
            vic.lastHandedOutAddress = handOutHighestPriorityIRQ(from: index + 1)
        } else {
            return vic.lastHandedOutAddress
        }
        updateOutputs()
        return vic.lastHandedOutAddress
    }

    private func bestDeliverable(in vic: VIC) -> (line: Int, priority: UInt32)? {
        var best: (line: Int, priority: UInt32)?
        var pending = vic.deliverableIRQs
        while pending != 0 {
            let line = pending.trailingZeroBitCount
            pending &= pending - 1
            let priority = vic.vectorPriority[line] & 0xF
            if best == nil || priority < best!.priority { best = (line, priority) }
        }
        return best
    }

    private func chainHasDeliverable(from index: Int) -> Bool {
        vics[index...].contains { $0.deliverableIRQs != 0 }
    }

    private func updateOutputs() {
        var irq = false
        var fiq = false
        for vic in vics {
            if vic.deliverableIRQs != 0 { irq = true }
            if vic.fiqStatus != 0 { fiq = true }
        }
        outputsChanged(irq, fiq)
    }
}
