/// Checks text that is about to become a `String`: it must be well-formed UTF-8 and contain
/// only characters XML allows. That excludes C0 controls other than tab, LF and CR, and the
/// noncharacters U+FFFE and U+FFFF.
///
/// This exists for speed. The standard library's validating initializer,
/// `String(validating:as:)`, is generic over `Sequence` and is not specialized for buffers, so
/// each call does runtime generic-metadata lookups that cost more than the validation. Checking
/// here and then creating the string with `String(decoding:as:)` is several times faster, even
/// though that initializer validates the UTF-8 a second time (quickly; it never fails here).
/// Text in skipped subtrees is not checked: it never becomes a string.
enum TextValidation {
    /// The first problem of each kind in `bytes`, with its index, in the order they occur: a
    /// forbidden character, and invalid UTF-8. ``firstProblem(in:)`` finds whether there is a
    /// problem quickly; this slower scan runs only on text that has one, so that text with both
    /// kinds reports both, each where it is.
    static func problems(in bytes: UnsafeBufferPointer<UInt8>) -> [(kind: XMLTVError.Kind, index: Int)] {
        guard let base = bytes.baseAddress else { return [] }
        var invalidUTF8: Int?
        var forbidden: (kind: XMLTVError.Kind, index: Int)?
        var i = 0
        while i < bytes.count && (invalidUTF8 == nil || forbidden == nil) {
            switch scalarStep(base, from: i, until: bytes.count, count: bytes.count) {
            case .valid:
                i = bytes.count
            case .invalidUTF8(let index):
                if invalidUTF8 == nil { invalidUTF8 = index }
                i = index &+ 1
            case .forbidden(let scalar, let index):
                if forbidden == nil { forbidden = (.invalidCharacter(scalar), index) }
                // C0 controls are one byte; U+FFFE and U+FFFF are three.
                i = index &+ (scalar < 0x80 ? 1 : 3)
            }
        }
        var found = invalidUTF8.map { [(kind: XMLTVError.Kind.invalidUTF8, index: $0)] } ?? []
        if let forbidden { found.append(forbidden) }
        return found.sorted { $0.index < $1.index }
    }

    /// The first problem in `bytes`, or nil if the text is valid.
    @inline(__always)
    static func firstProblem(in bytes: UnsafeBufferPointer<UInt8>) -> XMLTVError.Kind? {
        guard let base = bytes.baseAddress else { return nil }
        let count = bytes.count
        var i = 0
        // Printable ASCII is checked 16 bytes at a time. Most EPG text is printable ASCII, so a
        // block with anything else (a newline, an accented letter) takes the scalar path only
        // up to the next block boundary.
        let space = SIMD16<UInt8>(repeating: 0x20), delete = SIMD16<UInt8>(repeating: 0x7F)
        while i &+ 16 <= count {
            let block = ByteSearch.load(base, i)
            if ByteSearch.nibbleMask((block .< space) .| (block .> delete)) == 0 {
                i &+= 16
                continue
            }
            switch scalarStep(base, from: i, until: i &+ 16, count: count) {
            case .valid(let next): i = next
            case .invalidUTF8: return .invalidUTF8
            case .forbidden(let scalar, _): return .invalidCharacter(scalar)
            }
        }
        switch scalarStep(base, from: i, until: count, count: count) {
        case .valid: return nil
        case .invalidUTF8: return .invalidUTF8
        case .forbidden(let scalar, _): return .invalidCharacter(scalar)
        }
    }

    /// The outcome of the scalar path. Positions and scalars only, so that it is returned in
    /// registers: the hot loop of ``firstProblem(in:)`` runs it for every block with a byte
    /// outside printable ASCII.
    private enum Step {
        /// Valid up to this index.
        case valid(Int)
        case invalidUTF8(at: Int)
        case forbidden(UInt32, at: Int)
    }

    /// The scalar path: the well-formed byte sequences of Unicode Table 3-7, plus XML's `Char`
    /// production. Checks sequences starting before `limit` and returns the index after the last
    /// one, which may lie past `limit` when a sequence straddles it.
    private static func scalarStep(
        _ p: UnsafePointer<UInt8>, from start: Int, until limit: Int, count: Int
    ) -> Step {
        var i = start
        @inline(__always) func continuation(_ index: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
            index < count && range.contains(p[index])
        }
        while i < limit {
            let lead = p[i]
            switch lead {
            case 0x09, 0x0A, 0x0D, 0x20...0x7F:
                i &+= 1
            case 0x00...0x1F:
                return .forbidden(UInt32(lead), at: i)
            case 0xC2...0xDF:
                guard continuation(i &+ 1) else { return .invalidUTF8(at: i) }
                i &+= 2
            case 0xE0:
                guard continuation(i &+ 1, 0xA0...0xBF), continuation(i &+ 2) else { return .invalidUTF8(at: i) }
                i &+= 3
            case 0xE1...0xEC, 0xEE:
                guard continuation(i &+ 1), continuation(i &+ 2) else { return .invalidUTF8(at: i) }
                i &+= 3
            case 0xEF:
                guard continuation(i &+ 1), continuation(i &+ 2) else { return .invalidUTF8(at: i) }
                // U+FFFE and U+FFFF are EF BF BE and EF BF BF.
                if p[i &+ 1] == 0xBF && p[i &+ 2] >= 0xBE {
                    return .forbidden(0xFFF0 | UInt32(p[i &+ 2] & 0x0F), at: i)
                }
                i &+= 3
            case 0xED:
                guard continuation(i &+ 1, 0x80...0x9F), continuation(i &+ 2) else { return .invalidUTF8(at: i) }
                i &+= 3
            case 0xF0:
                guard continuation(i &+ 1, 0x90...0xBF), continuation(i &+ 2), continuation(i &+ 3) else { return .invalidUTF8(at: i) }
                i &+= 4
            case 0xF1...0xF3:
                guard continuation(i &+ 1), continuation(i &+ 2), continuation(i &+ 3) else { return .invalidUTF8(at: i) }
                i &+= 4
            case 0xF4:
                guard continuation(i &+ 1, 0x80...0x8F), continuation(i &+ 2), continuation(i &+ 3) else { return .invalidUTF8(at: i) }
                i &+= 4
            default:
                return .invalidUTF8(at: i)
            }
        }
        return .valid(i)
    }
}
