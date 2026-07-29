# OCISessionBar

A macOS menu bar utility that shows how much time is left on your OCI (Oracle
Cloud Infrastructure) session token — and quietly keeps it alive, so the browser
sign-in flow stays rare.

```
⏱ 1:20        ← an hour and twenty minutes left, in green
⏱ 0:04        ← under 10% of the session remains, in red
```

Click it for a menu with **Authenticate**, **Settings**, and **Quit**. That's the
whole app: no Dock icon, no windows, no fuss.

## Why

Session-token auth (`oci session authenticate`) is the pleasant way to use OCI —
until the token lapses mid-task and a browser window appears. OCISessionBar
watches the expiry and refreshes at the token's half-life, so in normal use the
session simply never runs out. When it genuinely cannot be extended, the app says
so before the countdown hits zero, instead of failing at the worst moment.

It reads and writes the same `~/.oci/config` and `~/.oci/sessions/<profile>/`
layout the `oci` CLI uses, so the two stay interchangeable — refresh here, run
`oci` there, or the reverse.

## Features

- **Live countdown** in the menu bar, green until under 10% of the session's
  lifetime remains, then red.
- **Automatic refresh** at the token's half-life. Recomputed from wall-clock time
  every second, so it self-corrects after the machine sleeps.
- **Three ways to get a session**, picked automatically:
  - the token is alive → silent refresh (`oci session refresh`);
  - the session is over but the profile is linked to an API-key profile → a new
    session is minted silently from that key, still no browser;
  - otherwise → the OCI Console opens for an interactive sign-in, with a loopback
    listener catching the redirect, exactly as the `oci` CLI does it.
- **Derive a session profile from an API-key profile.** If you have a `jroga`
  profile using API-key auth, create `jroga-token` from it in one step. Your
  existing profile is only ever read, never modified.
- **Validate on demand** against the service (`oci session validate`).
- **Launch at login**, via `SMAppService`.
- **Notification** when a session can no longer be renewed in the background. The
  app never opens a browser on its own — that stays your decision.

## Requirements

- macOS 26 or later
- An existing `~/.oci/config`. Any profile carrying a `security_token_file` key
  can be tracked.

## Install

Download the latest `.dmg` from
[Releases](https://github.com/iliasaz/oci-session-bar/releases), open it, and
drag **OCISessionBar** to Applications. The app is signed with a Developer ID and
notarized by Apple, so it opens without a Gatekeeper prompt.

### Build from source

```bash
brew install xcodegen        # only needed if you change project.yml
git clone https://github.com/iliasaz/oci-session-bar.git
cd oci-session-bar
xcodegen generate            # optional; the .xcodeproj is committed
open OCISessionBar.xcodeproj
```

Or from the command line:

```bash
xcodebuild build -project OCISessionBar.xcodeproj -scheme OCISessionBar \
  -configuration Release -destination 'platform=macOS'
```

## Setup

1. Launch the app. It appears in the menu bar.
2. Open **Settings**.
3. Confirm the **config file** path (defaults to `~/.oci/config`).
4. Pick the **profile** to track. Only profiles with a `security_token_file`
   entry are listed — those are the session-token profiles.
5. Optionally set **Renew using** to an API-key profile. When the session ends,
   a replacement is minted from that key with no browser. Leave it on *Browser
   sign-in* if you have no API key — that is the normal case.

### Creating a session profile

**Settings → New Session Profile…** offers two routes:

- **From an API-key profile.** Pick the source, and the app proposes
  `<source>-token` and inherits its region. The source profile's key authorizes
  the new session directly — nothing opens, and the source is not touched.
- **Browser sign-in.** Name the profile, give a region, and the OCI Console opens.

A name that already exists is refused. Existing profiles are never overwritten.

## How it works

| What you'd type | What the app does |
| --- | --- |
| `oci session validate` | Parses the JWT on disk for the countdown; **Validate Now** additionally calls the service. |
| `oci session refresh` | `SessionTokenManager.refresh(minimumRemaining: 0)`, which rewrites `security_token_file` atomically at `0600`. |
| `oci session authenticate` | Generates an RSA-2048 keypair, sends its public half to the Console as a JWK, catches the redirect on `http://localhost:8181`, and writes the session in the CLI's own layout. |
| `oci session authenticate --no-browser` | `SessionTokenManager.authenticate(using:)` with an `APIKeySigner` — the "renew using an API-key profile" path. |

All OCI operations go through
[oci-swift-sdk](https://github.com/iliasaz/oci-swift-sdk). The interactive
browser flow is implemented here, because the SDK deliberately leaves it out.

## Notes and limitations

- **Port 8181 is fixed.** `http://localhost:8181` is the redirect URI registered
  against the Console's `iaas_console` client, so no other port is accepted. If
  something else holds it — often an `oci session authenticate` still waiting in
  a terminal — the app reports the conflict rather than failing obscurely.
- **Not sandboxed, by design.** The app needs read/write access to `~/.oci` and a
  loopback listener. It is signed with Hardened Runtime and notarized, with no
  entitlement exceptions.
- **Refresh is sent to the region that issued your session**, which is not
  necessarily the `region` in your profile. If your tenancy's sign-in is served by
  its home region while the profile points elsewhere, the auth service answers a
  bare `401`, and the `oci` CLI reports that as "your session is no longer valid
  and cannot be refreshed" — misleadingly, since the session is fine. This app
  reads the issuing region from the token instead, and leaves your profile's
  `region` alone so other tools keep talking to the region you chose.
- **A live token is not the same as a live session.** The server-side session has
  its own lifetime; when it ends, refresh is refused no matter how fresh the
  token looks. The app detects this and tells you.
- **No cross-process locking with the `oci` CLI.** Concurrent *refreshes* are
  last-writer-wins and safe. Running `oci session authenticate` for the same
  profile at the same moment as the app can, in principle, mismatch a key and a
  token; it is not something the app can prevent.
- **Launch at login needs an installed, signed build.** `SMAppService` refuses a
  build run from DerivedData. That is expected during development.
- **One profile at a time.** The menu bar tracks a single active profile; switch
  in Settings.
- The realm table covers the commercial realm plus the listed government and
  dedicated regions. An unrecognised region falls back to `oraclecloud.com`,
  matching the Python SDK's behavior.

## Security

- Private keys are written `0600`, session directories `0700`, tokens `0600` —
  all by the SDK's own persistence layer, which creates each file with its final
  mode rather than tightening it afterwards.
- No token material, private key, OCID or fingerprint is ever logged.
- Nothing is transmitted anywhere except Oracle's own auth and identity
  endpoints.

## Development

See [CLAUDE.md](CLAUDE.md) for conventions. In short: edit `project.yml` (not the
`.xcodeproj`), Swift 6 with main-actor-by-default isolation, Swift Testing, and
`OSLog`.

```bash
xcodebuild test -project OCISessionBar.xcodeproj -scheme OCISessionBar \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

Releases are cut by `.github/workflows/release.yml`, which signs, notarizes and
staples both the `.app` and the `.dmg`. Set the required secrets once with
`scripts/setup-release-secrets.sh`.

## Credits

- [oci-swift-sdk](https://github.com/iliasaz/oci-swift-sdk) for every OCI operation.
- The menu bar structure follows Natalia Panferova's
  [Build a macOS menu bar utility in SwiftUI](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/)
  and the launch-at-login setting follows
  [Add a launch at login setting](https://nilcoalescing.com/blog/LaunchAtLoginSetting/).
- The browser sign-in flow mirrors [oracle/oci-cli](https://github.com/oracle/oci-cli).

## License

MIT
