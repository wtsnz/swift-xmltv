#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deduplicates strings by their UTF-8 bytes.
///
/// EPG text repeats constantly: channel IDs, categories, rating systems and values, credit names,
/// titles of episodic shows, and the descriptions of reruns and looping channels. Interning
/// returns the existing `String` on a hit. That saves the allocation and the UTF-8 validation,
/// and lets every programme share one copy. On the 1.93 GB benchmark feed, interning strings up
/// to 4 KiB, descriptions included, made parsing 10% faster and lowered peak memory by 6%,
/// compared with interning only strings under 256 bytes.
///
/// - Each decoder owns its interner. Sharing one across threads would turn every retain of a
///   popular string into contended atomic traffic on one cache line.
/// - Keys are copied into an arena, so the table stays valid when the streaming driver replaces
///   its buffer.
/// - Strings of 15 bytes or fewer are stored inline in `String` and never allocate, so they
///   bypass the table.
/// - The table is bounded. Past the budget, lookups still hit but new strings are not added.
/// - The hash is seeded per interner, so crafted input cannot force collision chains.
struct Interner {
    static let minimumLength = 16
    static let maximumLength = 4096
    static let arenaBudget = 64 << 20
    static let initialCapacity = 1 << 14

    private struct Slot {
        var hash: UInt64 = 0          // 0 marks an empty slot
        var keyOffset: Int32 = 0
        var keyLength: Int32 = 0
        var value: String = ""
    }

    /// Allocated on first use, so small documents with only short strings never pay for it.
    private var slots: [Slot] = []
    private var arena: [UInt8] = []
    private var occupied = 0
    private let seed = UInt64.random(in: 1...UInt64.max)

    @inline(__always)
    static func isEligible(_ count: Int) -> Bool {
        count >= minimumLength && count <= maximumLength
    }

    /// Returns the interned string for `bytes`. On a miss, `make` creates it and says whether it
    /// may be cached. A value that needed repair is not cached, so that every occurrence reports
    /// its own diagnostic.
    @inline(__always)
    mutating func string<E: Error>(
        for bytes: UnsafeBufferPointer<UInt8>,
        make: (UnsafeBufferPointer<UInt8>) throws(E) -> (value: String, isCacheable: Bool)
    ) throws(E) -> String {
        if slots.isEmpty { slots = [Slot](repeating: Slot(), count: Interner.initialCapacity) }
        let hash = hash(bytes)
        let (index, found) = probe(hash, bytes)
        if found { return slots[index].value }

        let (value, isCacheable) = try make(bytes)
        guard isCacheable, arena.count &+ bytes.count <= Interner.arenaBudget else { return value }
        slots[index] = Slot(hash: hash, keyOffset: Int32(arena.count), keyLength: Int32(bytes.count), value: value)
        arena.append(contentsOf: bytes)
        occupied &+= 1
        if occupied &* 2 > slots.count { grow() }
        return value
    }

    /// Linear probing. Returns the matching slot, or the empty slot where `bytes` belongs.
    /// Works through raw buffers so that probing never retains a slot's `String`.
    @inline(__always)
    private func probe(_ hash: UInt64, _ bytes: UnsafeBufferPointer<UInt8>) -> (index: Int, found: Bool) {
        slots.withUnsafeBufferPointer { slots in
            arena.withUnsafeBufferPointer { arena in
                let mask = slots.count &- 1
                var index = Int(truncatingIfNeeded: hash) & mask
                while true {
                    let slotHash = slots[index].hash
                    if slotHash == 0 { return (index, false) }
                    if slotHash == hash, Int(slots[index].keyLength) == bytes.count,
                       memcmp(arena.baseAddress! + Int(slots[index].keyOffset), bytes.baseAddress!, bytes.count) == 0 {
                        return (index, true)
                    }
                    index = (index &+ 1) & mask
                }
            }
        }
    }

    /// A multiply-xorshift hash over 8-byte words. Never returns 0.
    @inline(__always)
    private func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        let p = UnsafeRawPointer(bytes.baseAddress!)
        let count = bytes.count
        var h = seed ^ (UInt64(count) &* 0x9E37_79B9_7F4A_7C15)
        var i = 0
        while i &+ 8 <= count {
            h = (h ^ p.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0xBF58_476D_1CE4_E5B9
            h ^= h &>> 31
            i &+= 8
        }
        if i < count {
            // The final partial word is loaded from the end, so it overlaps bytes already hashed.
            // That is harmless, and every key here is at least 16 bytes.
            h = (h ^ p.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self)) &* 0x94D0_49BB_1331_11EB
        }
        h ^= h &>> 29
        return h | 1
    }

    private mutating func grow() {
        let old = slots
        slots = [Slot](repeating: Slot(), count: old.count &* 2)
        let mask = slots.count &- 1
        for slot in old where slot.hash != 0 {
            var index = Int(truncatingIfNeeded: slot.hash) & mask
            while slots[index].hash != 0 { index = (index &+ 1) & mask }
            slots[index] = slot
        }
    }
}
