import Foundation

private struct UInt64Box: Decodable {
    let v: UInt64
}

@_cdecl("antigravity_swift_decode_uint64")
public func antigravitySwiftDecodeUInt64(
    _ tokenPtr: UnsafePointer<CChar>?,
    _ tokenLen: Int,
    _ outValue: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    guard let tokenPtr, let outValue, tokenLen > 0, tokenLen <= 16_777_216 else {
        return 0
    }
    let rawBuffer = UnsafeBufferPointer(
        start: UnsafeRawPointer(tokenPtr).assumingMemoryBound(to: UInt8.self),
        count: tokenLen
    )
    for b in rawBuffer {
        let isAllowed =
            (b >= 0x30 && b <= 0x39) ||
            b == 0x2D ||
            b == 0x2B ||
            b == 0x2E ||
            b == 0x65 ||
            b == 0x45
        if !isAllowed {
            return 0
        }
    }
    var payload = Data("{\"v\":".utf8)
    payload.reserveCapacity(tokenLen + 6)
    payload.append(rawBuffer)
    payload.append(0x7D)
    guard let decoded = try? JSONDecoder().decode(UInt64Box.self, from: payload) else {
        return 0
    }
    outValue.pointee = decoded.v
    return 1
}
