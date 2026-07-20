import Foundation
import ImageIO
import CoreGraphics

/// Blurhash (https://blurha.sh); the SDK requires one on outgoing images.
enum Blurhash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    static func encode(imageData: Data, componentsX: Int = 4, componentsY: Int = 3) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary)
        else { return nil }
        return encode(cgImage: thumb, componentsX: componentsX, componentsY: componentsY)
    }

    static func encode(cgImage: CGImage, componentsX: Int, componentsY: Int) -> String? {
        guard (1...9).contains(componentsX), (1...9).contains(componentsY) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var factors: [(Double, Double, Double)] = []
        for j in 0..<componentsY {
            for i in 0..<componentsX {
                let normalisation = (i == 0 && j == 0) ? 1.0 : 2.0
                var r = 0.0, g = 0.0, b = 0.0
                for y in 0..<height {
                    for x in 0..<width {
                        let basis = normalisation
                            * cos(Double.pi * Double(i) * Double(x) / Double(width))
                            * cos(Double.pi * Double(j) * Double(y) / Double(height))
                        let offset = (y * width + x) * 4
                        r += basis * sRGBToLinear(pixels[offset])
                        g += basis * sRGBToLinear(pixels[offset + 1])
                        b += basis * sRGBToLinear(pixels[offset + 2])
                    }
                }
                let scale = 1.0 / Double(width * height)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        let dc = factors[0]
        let ac = factors.dropFirst()

        var hash = ""
        hash += encode83((componentsX - 1) + (componentsY - 1) * 9, length: 1)

        var maximumValue = 1.0
        if !ac.isEmpty {
            let actualMax = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max() ?? 0
            let quantised = max(0, min(82, Int(actualMax * 166 - 0.5)))
            maximumValue = Double(quantised + 1) / 166
            hash += encode83(quantised, length: 1)
        } else {
            hash += encode83(0, length: 1)
        }

        hash += encode83(encodeDC(dc), length: 4)
        for factor in ac {
            hash += encode83(encodeAC(factor, maximumValue: maximumValue), length: 2)
        }
        return hash
    }

    // MARK: Decoding

    /// Decodes to a small blurry placeholder; nil on a malformed hash.
    static func decode(_ hash: String, width: Int, height: Int, punch: Double = 1) -> CGImage? {
        let chars = Array(hash)
        guard chars.count >= 6, width > 0, height > 0 else { return nil }
        guard let sizeFlag = decode83(chars[0..<1]) else { return nil }
        let numY = sizeFlag / 9 + 1
        let numX = sizeFlag % 9 + 1
        guard let quant = decode83(chars[1..<2]) else { return nil }
        let maximumValue = Double(quant + 1) / 166 * punch
        guard chars.count == 4 + 2 * numX * numY else { return nil }

        guard let dc = decode83(chars[2..<6]) else { return nil }
        var colors = [(Double, Double, Double)](repeating: (0, 0, 0), count: numX * numY)
        colors[0] = decodeDC(dc)
        for i in 1..<(numX * numY) {
            let start = 4 + i * 2
            guard let ac = decode83(chars[start..<start + 2]) else { return nil }
            colors[i] = decodeAC(ac, maximumValue: maximumValue)
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis = cos(Double.pi * Double(x) * Double(i) / Double(width))
                            * cos(Double.pi * Double(y) * Double(j) / Double(height))
                        let color = colors[j * numX + i]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(clamping: linearToSRGB(r))
                pixels[offset + 1] = UInt8(clamping: linearToSRGB(g))
                pixels[offset + 2] = UInt8(clamping: linearToSRGB(b))
                pixels[offset + 3] = 255
            }
        }
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    private static func decode83(_ chars: ArraySlice<Character>) -> Int? {
        var value = 0
        for char in chars {
            guard let digit = alphabet.firstIndex(of: char) else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func decodeDC(_ value: Int) -> (Double, Double, Double) {
        (sRGBToLinear(UInt8((value >> 16) & 255)),
         sRGBToLinear(UInt8((value >> 8) & 255)),
         sRGBToLinear(UInt8(value & 255)))
    }

    private static func decodeAC(_ value: Int, maximumValue: Double) -> (Double, Double, Double) {
        func signPow(_ v: Double) -> Double { copysign(pow(abs(v), 2), v) }
        let r = value / (19 * 19)
        let g = (value / 19) % 19
        let b = value % 19
        return (signPow((Double(r) - 9) / 9) * maximumValue,
                signPow((Double(g) - 9) / 9) * maximumValue,
                signPow((Double(b) - 9) / 9) * maximumValue)
    }

    // MARK: Internals

    private static func sRGBToLinear(_ value: UInt8) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Double) -> Int {
        let v = max(0, min(1, value))
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return Int(s * 255 + 0.5)
    }

    private static func encodeDC(_ value: (Double, Double, Double)) -> Int {
        (linearToSRGB(value.0) << 16) + (linearToSRGB(value.1) << 8) + linearToSRGB(value.2)
    }

    private static func encodeAC(_ value: (Double, Double, Double), maximumValue: Double) -> Int {
        func quantise(_ component: Double) -> Int {
            let v = component / maximumValue
            let signed = copysign(pow(abs(v), 0.5), v)
            return max(0, min(18, Int(floor(signed * 9 + 9.5))))
        }
        return quantise(value.0) * 19 * 19 + quantise(value.1) * 19 + quantise(value.2)
    }

    private static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        for i in stride(from: length, to: 0, by: -1) {
            let digit = (value / Int(pow(83.0, Double(i - 1)))) % 83
            result.append(alphabet[digit])
        }
        return result
    }
}
