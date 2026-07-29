// Copyright 2026 Ilia Sazonov
// SPDX-License-Identifier: MIT

import SwiftUI

/// The translucent capsule the countdown sits on, so the menu bar item reads as an
/// object rather than text floating in the bar.
///
/// This cannot be `.glassEffect()`, and not for the reason it first appears.
/// `MenuBarExtra` does not host its label as a live SwiftUI view at all: a `Text`
/// label is reduced to the status button's `title` string, with every modifier —
/// `foregroundStyle`, `padding`, `glassEffect` — dropped before AppKit sees it.
/// (Verified by introspecting the button: a `Text` label yields `image=nil,
/// title="1:20"`.) Rendering to an `NSImage` is the only way to put anything but
/// plain system-coloured text up there, and a bitmap has no backdrop to sample, so
/// Liquid Glass and `.ultraThinMaterial` have nothing to work with.
///
/// The translucency is real all the same: the bitmap keeps its alpha, and the
/// status item composites it over the menu bar, which is itself translucent over
/// the desktop. Only the sheen is hand-drawn.
///
/// The capsule is deliberately **neutral**, not tinted with the state's colour.
/// Tinting it put red text on a red capsule, which lost contrast against the text
/// it framed and disappeared entirely over a warm desktop picture. Real glass is
/// neutral and lets its content carry the colour; this does the same.
struct MenuBarCapsule: View {
  let appearance: MenuBarAppearance
  /// The alert state gets a denser scrim. Red content is the one case that can
  /// still lose itself against a warm desktop picture even with a neutral capsule,
  /// and it is also the state that most needs to be read at a glance.
  var isCritical: Bool = false

  var body: some View {
    Capsule()
      // Denser at the top, thinning downward, the way a lens catches light.
      .fill(
        LinearGradient(
          colors: [scrim.opacity(topOpacity), scrim.opacity(bottomOpacity)],
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
              colors: [.white.opacity(sheenOpacity), .white.opacity(0.04), .clear],
              startPoint: .top,
              endPoint: .center
            )
          )
      }
      .overlay {
        // A rim that is bright at the top and picks up again at the bottom — the
        // bounce light that sells a glass edge.
        Capsule()
          .strokeBorder(
            LinearGradient(
              colors: rimColors,
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 0.75
          )
      }
  }

  /// Normally the capsule is a lightening of a dark menu bar and a darkening of a
  /// light one, so it stays neutral against either.
  ///
  /// The alert state always darkens instead. Lightening is what fails over a warm
  /// desktop picture: a white scrim turns a red wallpaper pink, and bright red text
  /// on pink is the least readable combination of the lot. A dark bed gives red the
  /// luminance contrast it needs no matter what is behind the bar.
  private var scrim: Color {
    if isCritical { return .black }
    return switch appearance {
    case .dark: Color.white
    case .light: Color.black
    }
  }

  private var topOpacity: Double {
    if isCritical { return 0.46 }
    return switch appearance {
    case .dark: 0.16
    case .light: 0.10
    }
  }

  private var bottomOpacity: Double {
    if isCritical { return 0.34 }
    return switch appearance {
    case .dark: 0.06
    case .light: 0.04
    }
  }

  private var sheenOpacity: Double {
    if isCritical { return 0.22 }
    return switch appearance {
    case .dark: 0.30
    case .light: 0.55
    }
  }

  private var rimColors: [Color] {
    // The dark alert bed needs its own bright rim, or it reads as a hole rather
    // than an object on a light menu bar.
    if isCritical {
      return [.white.opacity(0.55), .white.opacity(0.10), .white.opacity(0.30)]
    }
    return switch appearance {
    case .dark: [Color.white.opacity(0.55), .white.opacity(0.10), .white.opacity(0.22)]
    case .light: [Color.white.opacity(0.70), .black.opacity(0.14), .white.opacity(0.35)]
    }
  }
}

#if DEBUG
  #Preview("Capsule", traits: .sizeThatFitsLayout) {
    HStack(spacing: 16) {
      ForEach([MenuBarAppearance.dark, .light], id: \.self) { appearance in
        Text("1:20")
          .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(Color(nsColor: .systemGreen))
          .padding(.horizontal, 7)
          .frame(height: 18)
          .background { MenuBarCapsule(appearance: appearance) }
          .padding(8)
          .background(appearance == .dark ? Color.black : Color(white: 0.93))
          .environment(\.colorScheme, appearance.colorScheme)
      }
    }
    .padding()
  }
#endif
