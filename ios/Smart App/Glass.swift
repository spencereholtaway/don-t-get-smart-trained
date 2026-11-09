import SwiftUI

// Liquid Glass on iPhone, iPad and Mac. visionOS has its own glass material instead.

extension View {
    /// A glass background in the given shape.
    @ViewBuilder
    func glassBackground(in shape: some Shape) -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: shape)
        #else
        glassEffect(.regular, in: shape)
        #endif
    }
}

/// Groups nearby glass shapes so they blend together (no-op on visionOS).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        #if os(visionOS)
        content
        #else
        GlassEffectContainer(spacing: spacing) { content }
        #endif
    }
}
