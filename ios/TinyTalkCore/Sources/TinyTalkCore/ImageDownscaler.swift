import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a generated picture as a small JPEG. Cloudflare returns a
/// full-size (about 1024 px) image; a storybook page on a phone never needs
/// more than ~512 px, and the same bytes are what get uploaded to the Mac at
/// sync time -- so shrinking once, here, keeps both local storage and the
/// upload payload small (roughly 50-100 KB a page).
public enum ImageDownscaler {
    /// At most `maxLongSide` pixels on the long side, aspect ratio kept, JPEG.
    /// nil when `data` isn't an image ImageIO can decode.
    public static func jpeg(from data: Data, maxLongSide: Int = 512, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
