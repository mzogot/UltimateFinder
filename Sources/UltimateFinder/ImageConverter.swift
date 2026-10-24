import AppKit
import ImageIO
import UniformTypeIdentifiers
import libwebp

/// "Convert Image" in the context menu: re-encodes images as JPEG, PNG or WebP beside the
/// original, which is left untouched. Work runs off the main thread; completions return to it.
enum ImageConverter {
    enum Format: CaseIterable {
        case jpeg, png, webp

        var title: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            case .webp: return "WebP"
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .webp: return "webp"
            }
        }

        var type: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .webp: return .webP
            }
        }
    }

    private struct ConversionError: LocalizedError {
        let errorDescription: String?
    }

    /// True for files ImageIO can decode, which covers JPEG, PNG, WebP, HEIC, GIF, TIFF and more.
    static func canConvert(_ url: URL) -> Bool {
        guard let type = contentType(of: url), type.conforms(to: .image) else { return false }
        let readable = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return readable.contains(type.identifier)
    }

    /// The format `url` already has, so the menu can leave it out.
    static func format(of url: URL) -> Format? {
        guard let type = contentType(of: url) else { return nil }
        return Format.allCases.first { type.conforms(to: $0.type) }
    }

    static func convert(_ sources: [URL], to format: Format, completion: @escaping ([URL], Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [URL] = []
            var failure: Error?
            for source in sources {
                do {
                    results.append(try convert(source, to: format))
                } catch {
                    failure = error
                    break
                }
            }
            DispatchQueue.main.async { completion(results, failure) }
        }
    }

    private static func contentType(of url: URL) -> UTType? {
        try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    private static func convert(_ source: URL, to format: Format) throws -> URL {
        let name = source.lastPathComponent
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError(errorDescription: "“\(name)” couldn’t be read as an image.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(imageSource)
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        // A full-size "thumbnail" applies the EXIF orientation to the pixels, which WebP needs
        // and which spares the other formats from carrying the tag over.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, index, options as CFDictionary) else {
            throw ConversionError(errorDescription: "“\(name)” couldn’t be decoded.")
        }

        let data: Data
        switch format {
        case .jpeg:
            data = try encode(flattened(image), as: .jpeg, metadata: metadata(from: properties), named: name)
        case .png:
            data = try encode(image, as: .png, metadata: metadata(from: properties), named: name)
        case .webp:
            let sourceType = contentType(of: source)
            let lossy = [UTType.jpeg, .heic, .heif].contains { sourceType?.conforms(to: $0) == true }
            data = try encodeWebP(image, lossless: !lossy, named: name)
        }

        let base = source.deletingPathExtension().lastPathComponent
        let destination = FileOperations.unusedURL(named: "\(base).\(format.fileExtension)", in: source.deletingLastPathComponent())
        try data.write(to: destination, options: .withoutOverwriting)
        return destination
    }

    /// EXIF, GPS and IPTC survive the conversion; the orientation is already baked in.
    private static func metadata(from properties: [CFString: Any]) -> [CFString: Any] {
        var metadata: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            metadata[key] = properties[key]
        }
        metadata[kCGImagePropertyOrientation] = 1
        return metadata
    }

    private static func encode(_ image: CGImage, as type: UTType, metadata: [CFString: Any], named name: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ConversionError(errorDescription: "“\(name)” couldn’t be converted.")
        }
        var properties = metadata
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError(errorDescription: "“\(name)” couldn’t be converted.")
        }
        return data as Data
    }

    /// JPEG has no transparency, so transparent areas become white, as in Preview's export.
    private static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// Lossy (quality 90) for photos that were lossy to begin with, lossless otherwise, so
    /// screenshots and graphics stay crisp.
    private static func encodeWebP(_ image: CGImage, lossless: Bool, named name: String) throws -> Data {
        let width = image.width
        let height = image.height
        guard width <= WEBP_MAX_DIMENSION, height <= WEBP_MAX_DIMENSION else {
            throw ConversionError(errorDescription: "“\(name)” is too large for WebP, which allows at most \(WEBP_MAX_DIMENSION) pixels per side.")
        }

        // libwebp wants straight sRGB RGBA; Core Graphics only draws premultiplied, so undo that.
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError(errorDescription: "“\(name)” couldn’t be converted.") }
        for i in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for c in i..<i + 3 { pixels[c] = UInt8(min(255, (Int(pixels[c]) * 255 + alpha / 2) / alpha)) }
        }

        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buffer in
            lossless
                ? WebPEncodeLosslessRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(stride), &output)
                : WebPEncodeRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(stride), 90, &output)
        }
        defer { WebPFree(output) }
        guard size > 0, let output else { throw ConversionError(errorDescription: "“\(name)” couldn’t be encoded as WebP.") }
        return Data(bytes: output, count: size)
    }
}
