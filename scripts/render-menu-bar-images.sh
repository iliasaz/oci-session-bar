#!/bin/bash
# Copyright 2026 Ilia Sazonov
# SPDX-License-Identifier: MIT
#
# Regenerates the menu bar stills in docs/images/ used by the README.
#
# Builds render-menu-bar-images.swift against the app's own MenuBarRenderer, so the
# images always match what the status item draws. The flags mirror the app target:
# Swift 6 with main-actor-by-default isolation.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$root/docs/images}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

mkdir -p "$output"

swiftc -O -swift-version 6 -default-isolation MainActor -parse-as-library \
  "$root/Sources/OCISessionBar/Views/MenuBarRenderer.swift" \
  "$root/Sources/OCISessionBar/Model/MenuBarPresentation.swift" \
  "$root/Sources/OCISessionBar/Model/MenuBarAppearance.swift" \
  "$root/Sources/OCISessionBar/StatusItemTooltip.swift" \
  "$root/scripts/render-menu-bar-images.swift" \
  -o "$build/render-menu-bar-images"

"$build/render-menu-bar-images" "$output"
