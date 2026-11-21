import { createPrivateKey, createPublicKey } from "node:crypto";
import { Identity } from "../src/main/hermes/ssh";

/** CI hands the e2e key over as a raw 32-byte Ed25519 seed (base64); ssh2 wants OpenSSH format. */
export function identityFromRawSeed(seedB64: string, comment = "brainbox-e2e"): Identity {
  const seed = Buffer.from(seedB64, "base64");
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  const pub = createPublicKey(createPrivateKey({ key: der, format: "der", type: "pkcs8" }))
    .export({ format: "der", type: "spki" }).subarray(-32);
  const s = (b: Buffer | string) => { const v = Buffer.from(b); const n = Buffer.alloc(4); n.writeUInt32BE(v.length); return Buffer.concat([n, v]); };
  const u32 = (x: number) => { const n = Buffer.alloc(4); n.writeUInt32BE(x); return n; };
  const pubBlob = Buffer.concat([s("ssh-ed25519"), s(pub)]);
  let priv = Buffer.concat([u32(0x0b0b0b0b), u32(0x0b0b0b0b), s("ssh-ed25519"), s(pub), s(Buffer.concat([seed, pub])), s(comment)]);
  for (let i = 1; priv.length % 8 !== 0; i++) priv = Buffer.concat([priv, Buffer.from([i])]);
  const body = Buffer.concat([Buffer.from("openssh-key-v1\0"), s("none"), s("none"), s(""), u32(1), s(pubBlob), s(priv)]);
  const b64 = body.toString("base64").replace(/.{70}/g, "$&\n");
  return {
    privateKey: `-----BEGIN OPENSSH PRIVATE KEY-----\n${b64}\n-----END OPENSSH PRIVATE KEY-----\n`,
    publicLine: `ssh-ed25519 ${pubBlob.toString("base64")} ${comment}`,
  };
}

export function e2eEnv() {
  const e = process.env;
  if (!e.HERMES_E2E_SSH_HOST || !e.HERMES_E2E_SSH_KEY) return undefined;
  return {
    target: { host: e.HERMES_E2E_SSH_HOST, port: parseInt(e.HERMES_E2E_SSH_PORT ?? "22", 10), username: e.HERMES_E2E_SSH_USER ?? "root" },
    identity: identityFromRawSeed(e.HERMES_E2E_SSH_KEY),
    screen: e.HERMES_E2E_SCREEN ?? "",
  };
}

export function waitFor<T>(check: () => T | undefined, timeoutMs = 60_000, intervalMs = 100): Promise<T> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      const v = check();
      if (v !== undefined && v !== false) return resolve(v);
      if (Date.now() - start > timeoutMs) return reject(new Error("timed out waiting"));
      setTimeout(tick, intervalMs);
    };
    tick();
  });
}
