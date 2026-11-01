import AppKit

/// Window previews, kept small and reused between openings so the tiles have
/// something to show while the fresh captures come in. Without Screen Recording
/// permission there are no captures, and the tiles show app icons instead.
final class Thumbnails {
    static let shared = Thumbnails()

    private static let maxPixelWidth = 480

    private let queue = DispatchQueue(label: "com.isaac.swoop.thumbnails", qos: .userInitiated)
    private var images = [CGWindowID: CGImage]()

    func cached(_ id: CGWindowID) -> CGImage? {
        images[id]
    }

    /// Forgets windows that have closed.
    func keepOnly(_ ids: Set<CGWindowID>) {
        images = images.filter { ids.contains($0.key) }
    }

    /// Calls `completion` on the main thread once per window that was captured.
    func capture(_ ids: [CGWindowID], completion: @escaping (CGWindowID, CGImage) -> Void) {
        guard CGPreflightScreenCaptureAccess() else { return }
        for id in ids {
            queue.async {
                guard let full = PrivateAPI.captureWindow(id),
                      let image = Self.scaled(full)
                else { return }
                DispatchQueue.main.async {
                    self.images[id] = image
                    completion(id, image)
                }
            }
        }
    }

    /// At full resolution, for showing the selected window at its real size.
    func captureFull(_ id: CGWindowID, completion: @escaping (CGImage) -> Void) {
        guard CGPreflightScreenCaptureAccess() else { return }
        queue.async {
            guard let image = PrivateAPI.captureWindow(id) else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func scaled(_ image: CGImage) -> CGImage? {
        guard image.width > maxPixelWidth else { return image }
        let width = maxPixelWidth
        let height = max(1, image.height * width / image.width)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
