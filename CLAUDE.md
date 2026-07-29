# CLAUDE.md

## Project Overview

OCISessionBar is a macOS menu bar utility that shows how long the current OCI
(Oracle Cloud Infrastructure) session token has left, refreshes it before it
lapses, and falls back to the browser sign-in flow only when it has to. It is
menu-bar-only (`LSUIElement`), deliberately **not** sandboxed, and distributed
signed + notarized.

## Package structure

- `project.yml` — XcodeGen source of truth. **Edit this, not the `.xcodeproj`**,
  then run `xcodegen generate`. The generated project is committed so CI needs no
  XcodeGen install.
- `Sources/OCISessionBar/Model/` — config parsing, session status, the SDK seam,
  the `@Observable` model.
- `Sources/OCISessionBar/Auth/` — the hand-rolled browser sign-in flow: JWK
  encoding, the Console URL, the loopback listener.
- `Sources/OCISessionBar/Views/` — SwiftUI.
- `Tests/OCISessionBarTests/` — Swift Testing.

## Core instructions

- Target **macOS 26.0 or later**. (Yes, it exists.) The `oci-swift-sdk` floor is
  macOS 15, but this app targets 26.
- Swift 6.2 or later, using modern Swift concurrency.
- SwiftUI backed by `@Observable` classes for shared state.
- Do not introduce third-party frameworks without asking first. `oci-swift-sdk`
  is the only direct dependency and should stay that way.
- Stay in SwiftUI where feasible; AppKit is reached for only where SwiftUI has no
  equivalent (`NSOpenPanel`, `NSWorkspace`, `NSApp.terminate`, menu bar image
  rendering) — confirm before adding more.

## Domain rules that are easy to get wrong

- **Refresh goes to the region that issued the session, not the profile's
  region.** `/v1/authentication/refresh` is region-bound, and sending the exchange
  to the wrong region returns a bare `401 NotAuthenticated` that is
  indistinguishable from an ended session. The issuing region comes from the JWT
  header's `kid` (`asw_<region>_<serial>`); the profile's region is only a
  fallback. This is why `SessionService.refresh` drives `SessionTokenClient`
  directly instead of using `SessionTokenManager.refresh(minimumRemaining:)`,
  which — like the `oci` CLI — always uses the profile's region.
  Only *refresh* is region-bound; identity calls (so `validate`) work anywhere.
- The SDK type is **`SessionTokenManager`**, not `TokenManager`. Its
  `refresh(minimumRemaining:)` writes the new token to the profile's
  `security_token_file` atomically at 0600 — but see the region rule above for
  why the app does not call it.
- `OCIKit` has **no browser flow**. `SessionTokenManager.authenticate(using:)` is
  the `--no-browser` half and needs credentials that already exist. The
  interactive flow in `Auth/` is ours.
- **Port 8181 is not negotiable.** `http://localhost:8181` is the redirect URI
  registered against `client_id=iaas_console`. A conflict is reported to the
  user, never worked around with a different port.
- A token being unexpired does **not** mean it can be refreshed: the server-side
  session has its own lifetime, and once it ends, refresh returns 401. Treat
  `NeedsReauthentication` as a normal outcome, not an error path.
- **Never modify a profile the user did not ask you to.** Creating a session
  profile refuses an existing name outright. Rewriting a managed profile carries
  unmanaged keys across (`SessionService.preservedEntries` / `restore`), because
  `SessionTokenStore.upsertProfile` replaces a section wholesale.
- `OCIKit` exports an ObjectStorage model named `Duration`, which shadows the
  standard library type in any file that imports it. Spell it `Swift.Duration`.

## Swift instructions

### Approachable concurrency

The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:

- Code is on the main actor by default. Views and `AuthModel` need no annotation.
- Mark pure-logic types (`nonisolated enum JWK`, `nonisolated struct
  SessionStatus`, …) `nonisolated` so they can be used from actors and
  synchronous non-main contexts.
- `deinit` is always nonisolated and cannot touch main-actor state — do not add
  one to reach isolated stored properties.
- Use `@concurrent` to move an async function onto the concurrent pool when
  parallelism is actually wanted.

### General Swift guidelines

- Prefer Swift-native API to Foundation's: `replacing("a", with: "b")` over
  `replacingOccurrences(of:with:)`, `split(whereSeparator: \.isNewline)` over
  splitting on `"\n"` (Swift treats CRLF as **one** Character — splitting on
  `"\n"` silently fails to divide Windows-authored files).
- Prefer modern Foundation: `URL.appending(path:)`, `url.path(percentEncoded:)`.
- Never use C-style formatting (`String(format: "%02d", …)`); use
  `value.formatted(.number.precision(.integerLength(2)))`.
- Prefer static member lookup: `.circle`, `.borderedProminent`.
- Never use GCD (`DispatchQueue.main.async`); use modern concurrency. The one
  exception is `NWListener`/`NWConnection`, whose callbacks take a `DispatchQueue`
  by API contract — hop straight into an actor from them.
- Filter user-entered text with `localizedStandardContains()`, not `contains()`.
- Avoid force unwraps and force `try` outside genuinely unrecoverable situations.

## SwiftUI instructions

- Always `foregroundStyle()`, never `foregroundColor()`.
- Always `clipShape(.rect(cornerRadius:))`, never `cornerRadius()`.
- Never `ObservableObject`; use `@Observable`.
- Never the one-parameter `onChange()`; use the two-parameter or zero-parameter form.
- Never `onTapGesture()` unless the location or tap count is genuinely needed —
  otherwise `Button`.
- Never `Task.sleep(nanoseconds:)`; use `Task.sleep(for:)`.
- Do not break views up with computed properties — make new `View` structs.
- Do not force font sizes; prefer Dynamic Type. The menu bar label is the sole
  exception, because it is rendered to a fixed-height bitmap.
- Use `ImageRenderer` when a view must become an image.
- Avoid `AnyView` unless genuinely required.
- Avoid hard-coded padding and stack spacing unless asked for.
- Avoid AppKit colors in SwiftUI code, except where a system color must match
  menu bar appearance.

### Menu bar specifics

- `MenuBarExtra` renders its label as a **template** image, discarding
  `foregroundStyle`. Any state whose colour carries meaning must be rendered to an
  `NSImage` with `isTemplate = false` (see `MenuBarLabel`). Tie that to
  `MenuBarPresentation.usesTemplateRendering`, **not** to `isCritical` — a healthy
  countdown is green but not critical, and templating it silently repaints it in
  the menu bar's own colour.
- **`MenuBarExtra` does not host its label as a live SwiftUI view.** A `Text`
  label is reduced to the status button's `title` string and every modifier —
  `foregroundStyle`, `padding`, `glassEffect` — is dropped before AppKit sees it.
  Verified by introspecting the button: a `Text` label gives `image=nil,
  title="1:20"`, an `Image(nsImage:)` label gives `image=29x16 template=false`.
  Rendering to an `NSImage` is therefore the only way to put anything but plain
  system-coloured text in the menu bar. Re-run that introspection before believing
  any claim that a SwiftUI effect "should" work up there.
- Consequently `.glassEffect()` and `.ultraThinMaterial` are unavailable: both need
  a backdrop to sample and a bitmap has none. `ImageRenderer` flattens the material
  to a near-opaque light fill — a white blob on a dark menu bar. `MenuBarCapsule`
  hand-draws the sheen; the *translucency* is real, since the bitmap keeps its alpha.
- The capsule is **neutral, not tinted**, and adapts via `MenuBarAppearance` read
  from the status button's own `effectiveAppearance` (not Dark Mode — the menu bar
  also follows the desktop picture). Tinting it put red text on a red capsule,
  which vanished over a warm wallpaper. The alert state always *darkens* on both
  appearances: lightening a red wallpaper turns it pink, and red on pink is the
  worst case of all.
- `MenuBarExtra` exposes no handle on its `NSStatusItem`, and `.help()` on the
  label does not survive rasterization. The tooltip is set on the status button
  found by walking the app's `NSStatusBarWindow` (`StatusItemTooltip`), pushed
  from the model's tick. It is covered by tests that run against the real status
  item, because the hierarchy walk is undocumented and would fail silently.
- Under `LSUIElement` the app is outside the activation order: call
  `NSApp.activate(ignoringOtherApps: true)` **before** `openSettings()` or an
  `NSOpenPanel`, or the window opens behind everything.
- With `.menuBarExtraStyle(.menu)` the content closure is a menu builder —
  `Button`, `Text`, `Divider`, `Menu` compose; arbitrary views do not.

## Logging instructions

- Use `OSLog`: `import OSLog`, `Logger(subsystem:category:)`, subsystem
  `com.iliasaz.OCISessionBar`.
- Levels: `.debug`, `.info`, `.notice`, `.error`, `.fault`.
- Never `print()` in production code.
- **Never log token material, private keys, OCIDs or fingerprints.** Profile
  names and expiry timestamps are fine; mark them `privacy: .public` so they are
  actually readable in Console.

## Testing instructions

- Use Swift Testing (`import Testing`, `@Test`, `#expect`, `@Suite`).
- **Always** write tests for logic changes, and run them before calling a task
  done. Code that compiles but is untested is not finished.
- Test against external ground truth where one exists — the JWK tests check the
  modulus against `openssl rsa -pubin -modulus -noout`, not against our own
  parser.
- Never touch the real `~/.oci` in a test. Write a config file into
  `FileManager.default.temporaryDirectory` and clean it up.
- Tests that bind sockets take their own high port and `await` shutdown; sharing
  one port across tests makes the suite flaky.
- Run: `xcodebuild test -project OCISessionBar.xcodeproj -scheme OCISessionBar \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO`

## Git workflow

- When creating releases, use `gh release list` to find the latest version.
  Never use `git tag` for this — tags from dependency packages can mislead.
- Releases run through `.github/workflows/release.yml`: sign → notarize → staple
  the `.app`, then the same for the `.dmg`. Both `spctl` assessments are fatal.
