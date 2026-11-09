import SwiftUI
import CoreGraphics

// The app's own look: a deep rail green, reversed out with white text, with a little grain.
// SMART orange is the secondary color, for labels and markers only; statuses keep their own colors.

extension View {
    /// A deep green glass surface with a fine grain, for the cards. Content on it reads as dark mode,
    /// so text turns white and the accent and late colors switch to their lighter variants.
    func brandSurface(in shape: some Shape) -> some View {
        self
            .environment(\.colorScheme, .dark)
            .background { NoiseTexture().clipShape(shape) }
            .brandGlass(in: shape)
    }

    @ViewBuilder
    fileprivate func brandGlass(in shape: some Shape) -> some View {
        #if os(visionOS)
        background(Color.brand.opacity(0.85), in: shape)
            .glassBackgroundEffect(in: shape)
        #else
        glassEffect(.regular.tint(.brand), in: shape)
        #endif
    }
}

/// Film-grain noise, tiled. Light and dark specks over whatever is behind it.
struct NoiseTexture: View {
    var opacity = 0.12

    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 2)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.overlay)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// One 128-pixel tile of random gray specks, made once.
    private static let tile: CGImage? = {
        let size = 128
        var rng = SystemRandomNumberGenerator()
        // Gray + alpha pairs: each pixel is a random gray at a random strength.
        var pixels = [UInt8](repeating: 0, count: size * size * 2)
        for i in stride(from: 0, to: pixels.count, by: 2) {
            pixels[i] = UInt8.random(in: 0...255, using: &rng)
            pixels[i + 1] = UInt8.random(in: 80...255, using: &rng)
        }
        // Premultiply, as Core Graphics expects.
        for i in stride(from: 0, to: pixels.count, by: 2) {
            pixels[i] = UInt8(Int(pixels[i]) * Int(pixels[i + 1]) / 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: size * 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }()
}
