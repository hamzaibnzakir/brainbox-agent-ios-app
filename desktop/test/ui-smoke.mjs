// Drives the real Electron app against a live Hermes (same env as the live tests) and saves
// screenshots: connect, chat, Hermes' screen (take over / hand back), terminal.
//   BRAINBOX_SHOTS=<dir> HERMES_E2E_SSH_*=… node test/ui-smoke.mjs
import { execSync } from "node:child_process";
import { createPrivateKey, createPublicKey } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";

const require = createRequire(import.meta.url);
let playwright;
try { playwright = require("playwright-core"); } catch { playwright = require(path.join(execSync("npm root -g").toString().trim(), "playwright")); }
const { _electron: electron } = playwright;

function identityFromRawSeed(seedB64, comment = "brainbox-e2e") {
  const seed = Buffer.from(seedB64, "base64");
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  const pub = createPublicKey(createPrivateKey({ key: der, format: "der", type: "pkcs8" })).export({ format: "der", type: "spki" }).subarray(-32);
  const s = (b) => { const v = Buffer.from(b); const n = Buffer.alloc(4); n.writeUInt32BE(v.length); return Buffer.concat([n, v]); };
  const u32 = (x) => { const n = Buffer.alloc(4); n.writeUInt32BE(x); return n; };
  const pubBlob = Buffer.concat([s("ssh-ed25519"), s(pub)]);
  let priv = Buffer.concat([u32(0x0b0b0b0b), u32(0x0b0b0b0b), s("ssh-ed25519"), s(pub), s(Buffer.concat([seed, pub])), s(comment)]);
  for (let i = 1; priv.length % 8 !== 0; i++) priv = Buffer.concat([priv, Buffer.from([i])]);
  const body = Buffer.concat([Buffer.from("openssh-key-v1\0"), s("none"), s("none"), s(""), u32(1), s(pubBlob), s(priv)]);
  return { privateKey: `-----BEGIN OPENSSH PRIVATE KEY-----\n${body.toString("base64").replace(/.{70}/g, "$&\n")}\n-----END OPENSSH PRIVATE KEY-----\n`,
           publicLine: `ssh-ed25519 ${pubBlob.toString("base64")} ${comment}` };
}

const e = process.env;
if (!e.HERMES_E2E_SSH_HOST || !e.HERMES_E2E_SSH_KEY) { console.log("HERMES_E2E_* not set; skipping UI smoke"); process.exit(0); }
const shots = e.BRAINBOX_SHOTS ?? path.join(os.tmpdir(), "brainbox-shots");
fs.mkdirSync(shots, { recursive: true });
const userData = fs.mkdtempSync(path.join(os.tmpdir(), "brainbox-ui-"));
const profile = { name: "Test VPS", target: { host: e.HERMES_E2E_SSH_HOST, port: parseInt(e.HERMES_E2E_SSH_PORT ?? "22", 10), username: e.HERMES_E2E_SSH_USER ?? "root" } };

// BRAINBOX_APP_EXE runs a packaged build (e.g. release/linux-unpacked/brainbox-desktop) instead of the dev tree.
const packaged = e.BRAINBOX_APP_EXE;
const app = await electron.launch({
  executablePath: packaged ?? require(path.resolve("node_modules/electron")),
  args: packaged ? ["--no-sandbox"] : [path.resolve("."), "--no-sandbox"],
  env: { ...process.env, BRAINBOX_E2E: "1", BRAINBOX_USER_DATA: userData,
         BRAINBOX_E2E_IDENTITY: JSON.stringify(identityFromRawSeed(e.HERMES_E2E_SSH_KEY)), BRAINBOX_E2E_PROFILE: JSON.stringify(profile) },
});
const page = await app.firstWindow();
await page.setViewportSize({ width: 1440, height: 900 }).catch(() => {});
const shot = async (name) => { await page.screenshot({ path: path.join(shots, name + ".png") }); console.log("shot", name); };
const step = (name) => console.log("step:", name);
let failed = false;
try {
  step("connect");
  await page.getByText("Online").waitFor({ timeout: 120_000 });
  step("chat");
  await page.getByRole("button", { name: "New chat" }).click();
  const box = page.locator("textarea");
  await box.fill("hello from the desktop app");
  await box.press("Enter");
  await page.locator(".msg-assistant", { hasText: "Echo:" }).first().waitFor({ timeout: 60_000 });
  await page.getByRole("tab", { name: "Chat" }).click();
  await page.getByText("Sending").waitFor({ state: "detached", timeout: 30_000 }).catch(() => {});
  await shot("01-chat");

  step("approval");
  await box.fill("run tool: rm -rf /tmp/brainbox-desktop-ui-none");
  await box.press("Enter");
  const approve = page.getByRole("button", { name: "Approve once" });
  await approve.waitFor({ timeout: 60_000 });
  await shot("02-approval");
  await approve.click();
  await page.locator(".msg-assistant", { hasText: "approved by the user" }).first().waitFor({ timeout: 60_000 });

  if (e.HERMES_E2E_SCREEN === "1") {
    step("screen");
    await page.getByRole("tab", { name: "Workspace" }).click();
    const start = page.getByRole("button", { name: "Start screen" });
    if (await start.isVisible().catch(() => false)) await start.click();
    await page.getByText("Hermes is in control").waitFor({ timeout: 120_000 });
    await page.waitForTimeout(2500);
    await shot("03-workspace-watching");
    await page.getByRole("button", { name: "Take over" }).click();
    await page.getByText("You're in control").waitFor({ timeout: 20_000 });
    await page.waitForTimeout(1000);
    await shot("04-workspace-in-control");
    await page.getByRole("button", { name: "Hand back" }).click();
    await page.getByText("Hermes is in control").waitFor({ timeout: 20_000 });
    step("screen ok");
  }

  step("terminal");
  await page.getByRole("tab", { name: "Terminal" }).click();
  await page.waitForTimeout(2000);
  await page.keyboard.type("echo brainbox-desktop-$((6*7))\n");
  await page.waitForTimeout(1500);
  const termText = await page.locator(".xterm-rows").innerText();
  if (!termText.includes("brainbox-desktop-42")) throw new Error("terminal output missing: " + termText.slice(-300));
  await shot("05-terminal");
  console.log("UI SMOKE OK");
} catch (err) {
  failed = true;
  console.error("UI SMOKE FAILED:", err.message);
  await shot("zz-failure").catch(() => {});
} finally {
  await app.close();
  fs.rmSync(userData, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
