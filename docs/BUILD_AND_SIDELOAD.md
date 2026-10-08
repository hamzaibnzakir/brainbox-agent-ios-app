# Build & sideload — without owning a Mac

Everything that needs macOS (compiling, testing, archiving) runs on
**GitHub-hosted macOS runners**. You only download the result and install it
from a Windows (or Linux) PC.

> Research date: October 2026. Sideloading tools change often and Apple
> changes the rules with iOS releases — re-check each tool's own site before
> relying on it. Nothing below assumes your exact iOS version; check the
> compatibility notes for yours.

---

## 1. What CI produces

Workflow **CI** (`.github/workflows/ci.yml`) runs on every push to `main`:

| Job | Runner | Does |
|---|---|---|
| Core tests (Linux) | `ubuntu-latest`, `swift:6.0` container | builds `BrainboxCore`, runs its test-suite |
| iOS build, tests & unsigned IPA | `macos-15` (Xcode 16.4 at the time of writing) | core tests on macOS → `xcodegen generate` → app unit tests + UI tests on an iPhone simulator → Release archive with signing disabled → **`BrainboxAgent-unsigned.ipa`** artifact (kept 30 days) |

The repository is public, so GitHub-hosted macOS minutes are free for it. (On a
private repo macOS minutes are billed at a higher multiplier — check your
plan.)

### Downloading the IPA

1. GitHub → repository → **Actions** → latest green **CI** run.
2. Scroll to **Artifacts** → download **BrainboxAgent-unsigned-ipa** (a zip).
3. Unzip it → `BrainboxAgent-unsigned.ipa`.

An *unsigned* IPA cannot be installed as-is. A sideloading tool signs it with
your own Apple ID during installation (next section).

## 2. Ways to get it on your iPhone

| Option | Needs | Validity | Notes |
|---|---|---|---|
| **A. Sideloadly** (Windows/macOS) | Free Apple ID, PC + USB once | 7 days (free ID) | Simplest from Windows. Can re-sign over Wi-Fi while the PC is reachable |
| **B. SideStore** (+ LiveContainer) | Free Apple ID, PC once (iloader), LocalDevVPN app | 7 days, but refreshes **on the phone** | Best long-term free option: no PC needed after setup |
| **C. AltStore Classic** (AltServer on Windows) | Free Apple ID, PC on same Wi-Fi to refresh | 7 days | Works; refreshing needs AltServer running |
| **D. Paid Apple Developer Program** + `Signed IPA` workflow | 99 USD/year | Up to 1 year (development/ad-hoc profile) | No weekly refresh. Signing fully in CI |
| **E. TrollStore** | Specific iOS versions only | Permanent | Supports iOS 14.0 – 16.6.1, 16.7 RC and **17.0** only; **iOS 17.0.1 and newer are not supported**. Brainbox needs iOS 17, so this only applies to a device that is on exactly 17.0 |

Free Apple ID limits that apply to A–C: apps expire after **7 days** unless
refreshed, and only **3 sideloaded apps** can be active at once (SideStore
itself counts as one; LiveContainer can run more apps inside one slot).

On iOS 16+ every option except TrollStore requires **Developer Mode**:
Settings → Privacy & Security → Developer Mode → On (the phone restarts).

### A. Sideloadly (Windows) — quickest

1. Install the **web (non-Microsoft-Store) versions of iTunes and iCloud**
   (Sideloadly's requirement on Windows), then install Sideloadly from its
   official site.
2. Plug in the iPhone, tap **Trust**, open iTunes once so the device pairs.
3. In Sideloadly: drag `BrainboxAgent-unsigned.ipa` in, enter your Apple ID,
   press **Start**. (Use an Apple ID dedicated to sideloading if you prefer.)
4. On the phone: Settings → General → VPN & Device Management → your Apple
   ID → **Trust**. Enable Developer Mode if asked.
5. Re-do step 3 (or enable its auto-refresh) before the 7 days run out.

### B. SideStore — refresh without a PC

1. On the PC (Windows 64-bit, or Linux), install **iloader** (Windows needs
   iTunes installed first; Linux needs `usbmuxd`).
2. Plug in and trust the iPhone, sign in to iloader with your Apple ID, and
   install **SideStore** (the LiveContainer + SideStore bundle is the
   recommended option on iOS 26).
3. On the phone: set a passcode, install **LocalDevVPN** from the App Store and
   connect it, trust your Apple ID in VPN & Device Management, enable
   Developer Mode.
4. Open SideStore (with LocalDevVPN connected), sign in with the same Apple ID,
   refresh SideStore itself once.
5. Download the IPA to the phone (e.g. open the GitHub artifact link in Safari
   → Files), then open it with SideStore → install.
6. Refresh from SideStore within 7 days (VPN on). If the pairing file expires
   after an iOS update/reset, re-run iloader once.

### D. Fully signed builds in CI (paid Apple Developer account)

The **Signed IPA** workflow (`.github/workflows/signed-ipa.yml`, run manually
from the Actions tab) signs with your certificate stored as GitHub **encrypted
secrets**. Nothing is committed.

Creating the signing files without a Mac (Windows, using OpenSSL — e.g. from
Git Bash):

```bash
# 1. Private key + certificate signing request
openssl genrsa -out brainbox.key 2048
openssl req -new -key brainbox.key -out brainbox.csr -subj "/emailAddress=you@example.com/CN=Your Name/C=NG"
```

2. developer.apple.com → Certificates → **+** → *Apple Development* (or *Apple
   Distribution* for ad-hoc) → upload `brainbox.csr` → download the `.cer`.
3. Identifiers → register App ID `app.brainbox.agent` (or your own; then set
   the `BUNDLE_ID` repository variable).
4. Devices → register your iPhone's UDID (Sideloadly/iTunes show it).
5. Profiles → **+** → iOS App Development (or Ad Hoc) → pick the App ID,
   certificate and device → download `.mobileprovision`.

```bash
# 6. Bundle cert + key into a .p12 (choose a password)
openssl x509 -inform DER -in development.cer -out development.pem
openssl pkcs12 -export -legacy -inkey brainbox.key -in development.pem -out brainbox.p12
# (-legacy keeps the p12 importable by macOS' security tool; drop it on old OpenSSL)

# 7. Base64 for GitHub secrets
base64 -w0 brainbox.p12 > p12.b64
base64 -w0 profile.mobileprovision > profile.b64
```

8. GitHub → Settings → Secrets and variables → Actions → add:
   `BUILD_CERTIFICATE_BASE64` (p12.b64), `P12_PASSWORD`,
   `BUILD_PROVISION_PROFILE_BASE64` (profile.b64), `KEYCHAIN_PASSWORD`
   (any random string), `APPLE_TEAM_ID`.
9. Actions → **Signed IPA** → Run workflow → method `development` (or
   `ad-hoc`). Download the artifact and install it with Sideloadly (choose
   "use existing signature"), Apple Configurator, or any IPA installer.
10. Delete `brainbox.key`, `.p12` and the `.b64` files from your PC once the
    secrets are saved (keep an encrypted backup of the key).

**What only you can provide:** an Apple ID (free or paid), the device UDID,
and — for option D — the Apple Developer membership, certificate and profile.
CI cannot create these for you.

## 3. Updating

Push → CI → download the new artifact → install over the old app with the
same tool and the same Apple ID. App data (conversations, Keychain token)
survives as long as the bundle ID and signing team stay the same.

## 4. Building locally (if you ever get a Mac)

```bash
brew install xcodegen
xcodegen generate
open BrainboxAgent.xcodeproj
```

## 5. Troubleshooting

| Symptom | Fix |
|---|---|
| "Unable to install" in Sideloadly | Re-trust the computer, make sure iTunes (web version) sees the phone, try another USB port/cable |
| App icon greyed / won't open after 7 days | Free-ID signature expired → refresh/re-sideload |
| "Untrusted Developer" | Settings → General → VPN & Device Management → Trust |
| App opens then closes immediately | Developer Mode is off (iOS 16+) |
| Reached app limit | Free IDs allow 3 active sideloaded apps — remove one or use LiveContainer |
| CI green but no artifact | Artifacts are only uploaded when the iOS job succeeds; open the job's annotations for the error |
