import UIKit

/// Shrinks a photo to a JPEG that fits one Firestore document (<= 900 KB).
///
/// Strategy: cap the long edge at 2048 px, then lower JPEG quality step by
/// step; if that is not enough, halve the size again. A 12 MP iPhone photo
/// usually lands around 400-700 KB at 2048 px / quality 0.7.
enum PhotoCompressor {
    static let maxBytes = 900 * 1024

    static func jpeg(from image: UIImage, maxBytes: Int = maxBytes) -> Data? {
        var longEdge: CGFloat = 2048
        while longEdge >= 512 {
            let resized = resize(image, longEdge: longEdge)
            for quality in stride(from: 0.8, through: 0.4, by: -0.1) {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= maxBytes {
                    return data
                }
            }
            longEdge /= 1.5
        }
        return nil
    }

    private static func resize(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, longEdge / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
