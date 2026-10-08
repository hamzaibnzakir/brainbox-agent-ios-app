# Security review — first release (v0.1.0)

Scope: the iOS app, `BrainboxCore`, the CI workflows and the repository.
The Brainbox gateway and Hermes are **not built yet**; requirements for them
are listed in §3. Severity: **High** (fix before connecting a real server),
**Medium**, **Low**, **Info**.

## 1. Results by area

| Area | Status | Notes |
|---|---|---|
| Credentials | ✅ | Gateway token only in the iOS Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` → never in iCloud backups/other devices). Never in `UserDefaults` (unit-tested). No credentials in code, config or tests (fake test tokens only). Token reveal requires Face ID and shows only the last 4 chars |
| Keychain | ✅ | Round-trip test runs hosted on the simulator; it is skipped (not faked) if the unsigned simulator build has no Keychain entitlement (`-34018`) |
| Network transport | ✅ | `wss://` required; `ws://` accepted only for Tailscale/RFC1918/loopback hosts (validator + tests). ATS stays on; only `NSAllowsLocalNetworking`. URL with embedded credentials is rejected. URLSession has no cache/cookie store |
| Authentication | ✅ | Token sent inside the encrypted socket in `auth.hello` (not in the URL, so it can't end up in proxy logs). Auth failure stops reconnection (no hammering). Connect timeout 15 s |
| WebSocket | ✅ | Protocol version check; malformed frames dropped; 8 MiB frame cap; frames from a previous socket ignored (generation counter); heartbeat |
| Command replay | ✅ | In-flight requests fail on disconnect and are **never** replayed. Offline sends are not queued. Retry is always a manual tap |
| Local storage | ⚠️ Medium (accepted) | Conversations (may include command output) are JSON files in Application Support with `completeUntilFirstUserAuthentication` protection. Settings → Security → *Erase local data* wipes them. Consider `complete` protection if the app never needs background access |
| Logs | ✅ | The app has no `print`/`NSLog`/`os_log` calls; tokens are never logged. The log viewer's *Clear* only clears the on-device buffer |
| Clipboard | ✅ | Copies are local-only (no Universal Clipboard) and expire after 10 min |
| App switcher | ✅ (fixed during review) | Privacy cover hides content whenever the app isn't active |
| Biometric protection | ✅ | `deviceOwnerAuthentication` (Face ID/Touch ID with passcode fallback) for: opening terminal, saving config files, deleting files, service control, changing connection/agent, revealing token, erasing data, turning protection off. Destructive actions always re-prompt; others have a 60 s grace period. App locks after the chosen background timeout. If the device has no passcode, sensitive actions are refused (fail closed) |
| Debug vs production | ✅ | The `-uitesting` switch (mock + biometric bypass) is compiled only into DEBUG builds; Release ignores it. Debug-only actions are `#if DEBUG`. The Mock provider remains selectable in Release by design and is labelled "Mock" everywhere |
| File access | ✅ client / ⏳ server | Client normalises paths, requires Face ID + confirmation for delete, shows a diff before saving, uses optimistic concurrency (`expectedVersion`) to avoid overwriting newer server changes. The **server must enforce** the allow-list (§3) |
| Command execution | ✅ client / ⏳ server | The app never executes anything locally. The terminal is behind Face ID; interrupts are explicit. The server must run commands as a low-privilege user (§3) |
| API exposure | ⏳ | No server yet. Gateway must listen on Tailscale only (§3) |
| Git history | ✅ | Scanned all commits for private keys, certificates, GitHub/OpenAI/AWS/Slack token patterns: none. `.gitignore` blocks `.p12`, `.mobileprovision`, `.cer`, `.key`, `.pem`, `.env*`, SSH keys |
| GitHub Actions | ✅ / ⚠️ Low | `ci.yml` uses no secrets and runs with `contents: read`. `signed-ipa.yml` is `workflow_dispatch`-only (never runs for pull requests from forks), decodes secrets into `$RUNNER_TEMP`, uses a temporary keychain and deletes it in an `always()` step. **Low:** actions are pinned by tag (`@v4`), not commit SHA |

## 2. Findings & actions

| # | Severity | Finding | Action |
|---|---|---|---|
| 1 | Medium | App-switcher snapshots could expose chat/terminal content | **Fixed** — privacy cover on inactive scene |
| 2 | Medium | Conversation history stored locally (protected by iOS Data Protection, not app-level encrypted) | Accepted for v0.1; erase option provided. Revisit if sensitive outputs are common |
| 3 | Low | General clipboard would sync copies to other Apple devices | **Fixed** — local-only, expiring copies |
| 4 | Low | No TLS certificate pinning | Accepted: transport is wss inside Tailscale (WireGuard). Revisit if the gateway is ever exposed publicly |
| 5 | Low | Actions pinned by tag, not SHA | Optional hardening: pin `actions/checkout` and `actions/upload-artifact` to commit SHAs |
| 6 | Info | Free-Apple-ID sideloading means the app is re-signed with your personal certificate; anyone with your Apple ID could sign apps as you | Use a strong Apple ID password + 2FA; consider a dedicated Apple ID for sideloading |
| 7 | Info | Unsigned simulator builds can't exercise the real Keychain in CI | The Keychain test skips with an explicit reason instead of passing falsely; verify on device |

## 3. Requirements for the gateway (must be met before connecting Hermes)

1. Bind only to the Tailscale interface (or use `tailscale serve` for HTTPS);
   firewall the public interface.
2. Bearer token ≥ 32 random bytes; store a hash; constant-time compare;
   rate-limit `auth.hello`; rotate by replacing the token in the app.
3. Never log tokens or full `auth.hello` frames.
4. `fs.*`: allow-list roots, resolve symlinks and `..` before checking,
   read-only areas enforced server-side, return `conflict` on version mismatch.
5. `terminal.*`: PTY as a dedicated low-privilege user; kill on
   `stream.unsubscribe` / `terminal.interrupt`; idle timeout.
6. `vps.service.action`: only allow-listed systemd units via a narrow sudoers
   rule.
7. Audit-log privileged actions (who/what/when, no secrets).
8. Run Hermes credentials only on the server; the app never sees them.

## 4. Gateway (built 2026-10-08)

| Control | Implementation |
|---|---|
| Bind | `127.0.0.1` by default; any non-localhost, non-Tailscale address is refused unless `BRAINBOX_ALLOW_PUBLIC_BIND=1` |
| Token | Only its SHA-256 is stored; constant-time compare; 10 failures/min per IP then connections are dropped |
| First frame | Must be `auth.hello` within 10 s, otherwise closed |
| Files | Realpath sandbox (symlinks and `..` resolved), read-only roots, roots undeletable, 2 MB/binary guard, optimistic concurrency |
| Services | Explicit allow-list; `hermes-gateway.service` intentionally excluded in the example config |
| Logs | Read-only `journalctl` for allow-listed units; never deletes or rotates |
| Terminal | Disabled by default; per-command process groups; 15 min timeout |
| Hermes | Not called until `verified = true`; isolated worker per turn; stdin closed (no hanging approvals); dangerous-command auto-approval off; cancel kills only the worker |
| Errors | Internal exceptions are logged server-side; clients get generic messages |
| Data | Conversation history in `/var/lib/brainbox-gateway` (0700 dir, 0600 files) |

**Open risk (High, needs your decision):** the gateway runs as root because
Hermes does. Expose it only through Tailscale.

## 5. Re-review triggers

Re-run this review when: the gateway is built, Hermes is connected, the app
gets a new capability (push notifications, file upload, background tasks),
or signing moves to a paid account.
