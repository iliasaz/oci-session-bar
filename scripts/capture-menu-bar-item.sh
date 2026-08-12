#!/bin/bash
# Copyright 2026 Ilia Sazonov
# SPDX-License-Identifier: MIT
#
# Captures the menu bar item as the running app is drawing it right now — the live
# countdown, the menu bar's own light/dark appearance — and writes it to a PNG with
# a transparent background, so the docs get the item and not a slice of menu bar.
#
# Usage: scripts/capture-menu-bar-item.sh [output.png] [options]
#   --scale N              pixels per point (default 3)
#   --appearance a|light|dark   force the appearance instead of asking the menu bar
#   --profile NAME         a profile other than the app's selected one
#   --text 1:20 [--critical] | --expired | --unconfigured   a fixed state
#
# Builds against the app's own MenuBarRenderer, so a capture cannot drift from what
# the status item draws. The flags mirror the app target: Swift 6 with
# main-actor-by-default isolation.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$root/docs/images/menu-bar-live.png}"
[ $# -gt 0 ] && shift
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

mkdir -p "$(dirname "$output")"

swiftc -O -swift-version 6 -default-isolation MainActor -parse-as-library \
  "$root/Sources/OCISessionBar/Views/MenuBarRenderer.swift" \
  "$root/Sources/OCISessionBar/Model/MenuBarPresentation.swift" \
  "$root/Sources/OCISessionBar/Model/MenuBarAppearance.swift" \
  "$root/Sources/OCISessionBar/StatusItemTooltip.swift" \
  "$root/scripts/MenuBarImageOutput.swift" \
  "$root/scripts/capture-menu-bar-item.swift" \
  -o "$build/capture-menu-bar-item"

"$build/capture-menu-bar-item" "$output" "$@"
