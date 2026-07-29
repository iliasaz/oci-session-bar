// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// The translucent capsule the countdown sits on, so the menu bar item reads as an
/// object rather than text floating in the bar.
///
/// This cannot be `.glassEffect()`. Liquid Glass samples the content *behind* it at
/// draw time, and a `MenuBarExtra` label is rasterized into a static `NSImage`
/// before it ever reaches the screen — there is no backdrop to sample, so the
/// effect renders as nothing.
///
/// The translucency here is real all the same: the bitmap keeps its alpha, and the
/// status item composites it over the menu bar, which is itself translucent over
/// the desktop. So the capsule genuinely shows what is behind it. What is hand-made
/// is the specular part — the gradient body and the brighter top edge that make it
/// read as a lens rather than a flat swatch.
///
/// It is tinted with the state's own colour rather than white or black, because the
/// image cannot adapt to the menu bar's appearance (it is deliberately not a
/// template image, so the countdown keeps its colour). A tinted capsule is legible
/// on light and dark menu bars alike, where a white one would vanish on one and a
/// black one on the other.
struct MenuBarCapsule: View {
  let tint: Color

  var body: some View {
    Capsule()
      // Denser at the top, thinning downward, the way a lens catches light.
      .fill(
        LinearGradient(
          colors: [tint.opacity(0.34), tint.opacity(0.12)],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .overlay {
        // The specular sheen. Confined to the upper half — carried further down it
        // reads as a flat wash rather than light falling on a curved surface.
        Capsule()
          .fill(
            LinearGradient(
              colors: [.white.opacity(0.40), .white.opacity(0.06), .clear],
              startPoint: .top,
              endPoint: .center
            )
          )
      }
      .overlay {
        // A rim that is bright at the top, takes the tint through the middle, and
        // picks up again at the bottom — the bounce light that sells a glass edge.
        Capsule()
          .strokeBorder(
            LinearGradient(
              colors: [.white.opacity(0.75), tint.opacity(0.45), .white.opacity(0.28)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 0.75
          )
      }
  }
}

#if DEBUG
  #Preview("Capsule", traits: .sizeThatFitsLayout) {
    HStack(spacing: 0) {
      ForEach(["1:20", "0:04"], id: \.self) { text in
        Text(text)
          .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
          .foregroundStyle(text == "1:20" ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
          .padding(.horizontal, 7)
          .frame(height: 18)
          .background {
            MenuBarCapsule(tint: text == "1:20" ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
          }
          .padding(6)
      }
    }
    .padding()
    .background(.black)
  }
#endif
