# Push notifications (APNs)

## Requirements

**A paid Apple Developer Program membership is required.** Free "Personal Team" provisioning, which is what the free sideloading tools use, can't use the Push Notifications capability. Apple confirms this in [DTS forum thread 768748](https://developer.apple.com/forums/thread/768748). Without a paid account:

- the app shows **"Not configured"** under Settings → Notifications;
- the server sends nothing;
- everything else works.

With a paid account you need:

1. **An APNs auth key.** Create one at developer.apple.com → Certificates, IDs & Profiles → Keys → "+" → Apple Push Notifications service. Download the `.p8` file once.
   - Copy it to the server only, for example `/etc/brainbox-gateway/apns/AuthKey.p8`, owned by root with mode 600.
   - **Never put it in the app, the repository, CI secrets for the IPA, or a chat.**
2. **Your Team ID and the key's Key ID** (each 10 characters).
3. **A signed build with the Push capability.**
   - Build with `BRAINBOX_PUSH=1` (see BUILD_AND_SIDELOAD.md). This adds the `aps-environment` entitlement.
   - The build must be signed with a provisioning profile that includes Push.
   - Use `environment = "development"` for debug/Xcode installs and `"production"` for TestFlight, ad-hoc or App Store builds.

## Server setup (review first)

```bash
sudo /opt/brainbox-gateway/venv/bin/pip install "/opt/brainbox-gateway/src[proxy,push]"
sudo install -d -m 700 /etc/brainbox-gateway/apns
sudo install -m 600 AuthKey_XXXXXXXXXX.p8 /etc/brainbox-gateway/apns/AuthKey.p8
# Edit [push] in /etc/brainbox-gateway/hermes-proxy.toml: enabled = true, team_id, key_id, key_file, bundle_id, environment
sudo /opt/brainbox-gateway/venv/bin/brainbox-gateway hermes-proxy-check --config /etc/brainbox-gateway/hermes-proxy.toml
sudo systemctl restart brainbox-hermes-proxy
journalctl -u brainbox-hermes-proxy -n 30 --no-pager    # "push notifications enabled but not ready: …" lists anything missing
```

Then, in the app, go to Settings → Notifications and do two things:

- allow notifications;
- tap **Send test notification**. It reports success only if APNs accepted it.

**Rollback:** set `[push] enabled = false` and restart the proxy. Tokens stay in `/var/lib/brainbox-gateway/push-tokens.json`, mode 600; delete that file to forget them.

## What is sent

Each event is sent only if that phone's preference allows it, and the same event is never sent twice.

| Event | When |
| --- | --- |
| Scheduled task finished / failed | A job's latest execution reaches completed / failed. The first poll after startup only records state. |
| Long task finished | A run started from the app ends after `long_task_seconds`, default 2 min. |
| Approval needed | A run started from the app is waiting for an approval. |
| Hermes isn't responding | `/health` fails 3 polls in a row. Sent once until it recovers. |

Payloads contain a generic title and body and a `brainbox://` deep link with ids only. They never include prompts, outputs, commands, file names or job names.

## Token lifecycle

A phone's tokens are removed in three cases:

- the phone turns notifications off (`DELETE /brainbox/push/register`);
- the phone's `[[devices]]` entry is deleted, checked at the next proxy start;
- Apple answers `400`/`410` (BadDeviceToken / Unregistered).

## Status

Event detection, dedupe, preferences, token handling and the ES256 provider token are covered by tests with a fake APNs sender. **Real delivery through Apple has not been tested**, because it needs your paid account, key and signed build.
