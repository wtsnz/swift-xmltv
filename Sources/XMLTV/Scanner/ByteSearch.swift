#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Byte-search kernels for the scanner.
///
/// Markup in XMLTV is dense: about one `<` every 37 bytes in real feeds. That makes per-call
/// overhead as important as raw bandwidth. The kernels therefore search 16 bytes at a time with
/// `SIMD16<UInt8>` and turn the comparison mask into a scalar bitmask with a single narrowing
/// shift, the NEON `shrn` idiom. One `ctz` then gives the index of the first hit. Measured on the
/// 1.93 GB corpus, this beat a scalar loop (2.3 GB/s), `memchr` (4.2 GB/s) and 64-byte unrolling
/// (3.9 GB/s) at about 6 GB/s per core.
///
/// Every function takes a base pointer, a start index and an end index, and never reads at or
/// past `end`.
enum ByteSearch {
    typealias Block = SIMD16<UInt8>

    /// Bytes that force a text value off the copy-free path: entity references and carriage
    /// returns (XML line-end normalisation).
    static let ampersand = Block(repeating: UInt8(ascii: "&"))
    static let carriageReturn = Block(repeating: 0x0D)
    static let lessThan = Block(repeating: UInt8(ascii: "<"))

    /// Packs a 16-lane comparison mask into a `UInt64` with four bits per lane.
    ///
    /// Reinterpreting the 0x00/0xFF lanes as eight 16-bit lanes and narrowing each by four bits
    /// lowers to a single `shrn` on arm64. On x86 it lowers to a short shuffle sequence.
    @inline(__always)
    static func nibbleMask(_ mask: SIMDMask<SIMD16<Int8>>) -> UInt64 {
        let lanes = unsafeBitCast(mask, to: SIMD8<UInt16>.self) &>> 4
        return unsafeBitCast(SIMD8<UInt8>(truncatingIfNeeded: lanes), to: UInt64.self)
    }

    @inline(__always)
    static func load(_ base: UnsafePointer<UInt8>, _ index: Int) -> Block {
        UnsafeRawPointer(base + index).loadUnaligned(as: Block.self)
    }

    /// Index of the first `needle` in `base[from..<end]`, or `end`.
    @inline(__always)
    static func first(_ needle: UInt8, in base: UnsafePointer<UInt8>, from: Int, end: Int) -> Int {
        var i = from
        let pattern = Block(repeating: needle)
        while i &+ 16 <= end {
            let bits = nibbleMask(load(base, i) .== pattern)
            if bits != 0 { return i &+ bits.trailingZeroBitCount &>> 2 }
            i &+= 16
        }
        while i < end && base[i] != needle { i &+= 1 }
        return i
    }

    /// Index of the first `stop` byte in `base[from..<end]` (or `end`), and whether any byte
    /// before it needs a closer look: `&` or CR always, and with `flagControls` also any byte
    /// below 0x20 and `<`. Attribute values set `flagControls`, because XML maps literal tab
    /// and newline in them to spaces and forbids a raw `<`.
    ///
    /// Most text runs between tags are short (indentation, `en`, a title), so a short scalar
    /// prologue runs before the vector loop.
    @inline(__always)
    static func stop(
        at stop: UInt8, in base: UnsafePointer<UInt8>, from: Int, end: Int, flagControls: Bool
    ) -> (index: Int, needsDecoding: Bool) {
        var i = from
        var needsDecoding = false

        @inline(__always) func isSpecial(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: "&") || (flagControls ? byte < 0x20 || byte == UInt8(ascii: "<") : byte == 0x0D)
        }

        let prologueEnd = min(end, from &+ 8)
        while i < prologueEnd {
            let byte = base[i]
            if byte == stop { return (i, needsDecoding) }
            if isSpecial(byte) { needsDecoding = true }
            i &+= 1
        }

        let stopPattern = Block(repeating: stop)
        let controlLimit = Block(repeating: 0x20)
        while i &+ 16 <= end {
            let block = load(base, i)
            let stopBits = nibbleMask(block .== stopPattern)
            let special = flagControls
                ? (block .== ampersand) .| (block .< controlLimit) .| (block .== lessThan)
                : (block .== ampersand) .| (block .== carriageReturn)
            let specialBits = nibbleMask(special)
            if stopBits != 0 {
                let lane = stopBits.trailingZeroBitCount
                // Only specials that come before the stop byte count.
                if specialBits & ((1 &<< UInt64(lane)) &- 1) != 0 { needsDecoding = true }
                return (i &+ lane &>> 2, needsDecoding)
            }
            if specialBits != 0 { needsDecoding = true }
            i &+= 16
        }

        while i < end {
            let byte = base[i]
            if byte == stop { return (i, needsDecoding) }
            if isSpecial(byte) { needsDecoding = true }
            i &+= 1
        }
        return (end, needsDecoding)
    }

    /// Index of the first occurrence of `literal` at or after `from`, or `end`.
    /// Used for the rare constructs: comment, CDATA and PI terminators.
    static func first(_ literal: StaticString, in base: UnsafePointer<UInt8>, from: Int, end: Int) -> Int {
        let count = literal.utf8CodeUnitCount
        let head = literal.utf8Start[0]
        var i = from
        while true {
            i = first(head, in: base, from: i, end: end)
            guard i &+ count <= end else { return end }
            if memcmp(base + i, literal.utf8Start, count) == 0 { return i }
            i &+= 1
        }
    }

    /// Number of line ends in `base[from..<end]`, counted as XML normalises them: a CR LF pair,
    /// a lone LF and a lone CR are one each. A CR at `end - 1` counts as a lone CR. Used only to
    /// compute line numbers on error paths and when the streaming reader discards input.
    static func countNewlines(in base: UnsafePointer<UInt8>, from: Int, end: Int) -> Int {
        @inline(__always) func isLoneCR(_ i: Int) -> Bool {
            base[i] == 0x0D && (i &+ 1 >= end || base[i &+ 1] != 0x0A)
        }
        var count = 0
        var i = from
        let newline = Block(repeating: 0x0A)
        while i &+ 16 <= end {
            let block = load(base, i)
            count &+= nibbleMask(block .== newline).nonzeroBitCount &>> 2
            // A CR is a line end only when no LF follows. Most files have none, or CR LF pairs.
            if nibbleMask(block .== carriageReturn) != 0 {
                for k in i..<(i &+ 16) where isLoneCR(k) { count &+= 1 }
            }
            i &+= 16
        }
        while i < end {
            if base[i] == 0x0A || isLoneCR(i) { count &+= 1 }
            i &+= 1
        }
        return count
    }

    /// The index of the first byte of the line containing `offset`: just after the nearest LF or
    /// CR before it, or `floor` when there is none at or after `floor`.
    static func lineStart(of offset: Int, in base: UnsafePointer<UInt8>, floor: Int = 0) -> Int {
        var i = offset
        while i > floor && base[i &- 1] != 0x0A && base[i &- 1] != 0x0D { i &-= 1 }
        return i
    }
}
