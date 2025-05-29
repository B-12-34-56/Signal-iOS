import UIKit

struct HashUtils {
  /// 8×8 average hash → 16‑hex chars
  static func averageHash8x8(_ image: UIImage) -> String {
    let size = CGSize(width: 8, height: 8)
    guard let cg        = image.cgImage,
          let context   = CGContext(
            data: nil,
            width: 8, height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
          ) else { return "" }
    context.draw(cg, in: CGRect(origin: .zero, size: size))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return "" }

    // compute mean
    let count = 8*8
    var sum = 0
    for i in 0..<count { sum += Int(data[i]) }
    let avg = sum / count

    // build bitstring
    var bits = ""
    for i in 0..<count { bits += data[i] >= UInt8(avg) ? "1" : "0" }

    // convert each 4 bits → hex
    var hex = ""
    for i in stride(from: 0, to: bits.count, by: 4) {
      let start = bits.index(bits.startIndex, offsetBy: i)
      let end   = bits.index(start, offsetBy: 4, limitedBy: bits.endIndex) ?? bits.endIndex
      let nibble = String(bits[start..<end]).padding(toLength: 4, withPad: "0", startingAt: 0)
      hex += String(format: "%X", Int(nibble, radix: 2)!)
    }
    return hex
  }

  /// Hamming distance between two equal‑length hex strings
  static func hammingDistance(_ a: String, _ b: String) -> Int {
    guard a.count == b.count else { return Int.max }
    var dist = 0
    for (c1, c2) in zip(a, b) {
      guard let v1 = Int(String(c1), radix: 16),
            let v2 = Int(String(c2), radix: 16)
      else { dist += 4; continue }
      dist += (v1 ^ v2).nonzeroBitCount
    }
    return dist
  }

  /// Return true if ≥ threshold (e.g. 90%) bits match
  static func isSimilar(_ a: String, _ b: String, threshold: Double = 0.9) -> Bool {
    let dist = hammingDistance(a, b)
    let totalBits = a.count * 4
    return Double(totalBits - dist) / Double(totalBits) >= threshold
  }
}
