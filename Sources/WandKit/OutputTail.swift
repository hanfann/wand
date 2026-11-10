import Foundation

/// A bounded byte tail. Grow only as output arrives, then overwrite the oldest
/// bytes in place; linearize once when the caller requests the final result.
struct OutputTail {
    let limit: Int
    private var storage = Data()
    private var start = 0
    private(set) var truncated = false
    var count: Int { storage.count }

    init(limit: Int) { self.limit = max(0, limit) }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        guard limit > 0 else { truncated = true; return }
        let source = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        if bytes.count >= limit {
            truncated = truncated || !storage.isEmpty || bytes.count > limit
            storage = Data(bytes: source.advanced(by: bytes.count - limit), count: limit)
            start = 0
            return
        }
        let filling = min(bytes.count, limit - storage.count)
        if filling > 0 { storage.append(source, count: filling) }
        let remaining = bytes.count - filling
        guard remaining > 0 else { return }
        truncated = true
        let first = min(remaining, limit - start)
        storage.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: start).copyMemory(from: source.advanced(by: filling), byteCount: first)
            if remaining > first {
                destination.baseAddress!.copyMemory(from: source.advanced(by: filling + first), byteCount: remaining - first)
            }
        }
        start = (start + remaining) % limit
    }

    var data: Data {
        guard start > 0 else { return storage }
        var result = Data(capacity: storage.count)
        result.append(storage[start...])
        result.append(storage[..<start])
        return result
    }
}
