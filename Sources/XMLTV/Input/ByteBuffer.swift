#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A growable, uniquely owned byte buffer. It holds decompressed or transcoded documents and the
/// streaming reader's window.
///
/// `[UInt8]` would work, but it cannot hand out its uninitialized capacity for `read(2)` or zlib
/// to write into. Writing through a temporary buffer would cost an extra copy of every byte.
struct ByteBuffer: ~Copyable {
    private(set) var base: UnsafeMutablePointer<UInt8>
    private(set) var count = 0
    private(set) var capacity: Int

    init(capacity: Int = 0) {
        self.capacity = max(capacity, 16)
        self.base = .allocate(capacity: self.capacity)
    }

    deinit { base.deallocate() }

    var bytes: UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(start: base, count: count) }

    /// Writable space after the current contents, at least `minimum` bytes. Follow a write with
    /// ``commit(_:)``.
    mutating func unusedCapacity(atLeast minimum: Int) -> UnsafeMutableBufferPointer<UInt8> {
        if capacity - count < minimum { grow(toAtLeast: count + minimum) }
        return UnsafeMutableBufferPointer(start: base + count, count: capacity - count)
    }

    mutating func commit(_ written: Int) {
        precondition(written >= 0 && count + written <= capacity)
        count += written
    }

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        let space = unusedCapacity(atLeast: bytes.count)
        space.baseAddress!.update(from: bytes.baseAddress!, count: bytes.count)
        count += bytes.count
    }

    mutating func append(_ byte: UInt8) {
        if count == capacity { grow(toAtLeast: count + 1) }
        base[count] = byte
        count += 1
    }

    /// Discards the first `n` bytes, moving the rest to the front.
    mutating func removeFirst(_ n: Int) {
        precondition(n >= 0 && n <= count)
        guard n > 0 else { return }
        (base).update(from: base + n, count: count - n)
        count -= n
    }

    private mutating func grow(toAtLeast needed: Int) {
        var newCapacity = max(capacity, 16)
        while newCapacity < needed { newCapacity *= 2 }
        let newBase = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newBase.update(from: base, count: count)
        base.deallocate()
        base = newBase
        capacity = newCapacity
    }
}
