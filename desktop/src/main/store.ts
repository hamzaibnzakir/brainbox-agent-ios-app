// What the desktop app keeps between launches, in Electron's userData folder:
//   brainbox.json  profile, preferences, pinned host keys, ownership id (no secrets)
//   secrets.json   the SSH private key and backend session tokens, encrypted with the OS keystore
//                  (Windows DPAPI via safeStorage). Never written in plain text where encryption works.
import { safeStorage } from "electron";
import fs from "node:fs";
import path from "node:path";
import { BackendRecord, makeOwnershipId } from "./hermes/backend";
import { EnginePersistence } from "./hermes/engine";
import { HostKeyStore, Identity, SSHTarget, generateIdentity } from "./hermes/ssh";

export interface Profile {
  name: string;
  target: SSHTarget;
}

export interface Preferences {
  notifyOnFinish: boolean;
  notifyOnApproval: boolean;
  desktopBackend: boolean;
  theme: "system" | "light" | "dark";
}

interface Plain {
  profile?: Profile;
  prefs: Preferences;
  hostKeys: Record<string, string>;
  ownershipId: string;
  lastChat?: string;
}

const DEFAULT_PREFS: Preferences = { notifyOnFinish: true, notifyOnApproval: true, desktopBackend: false, theme: "dark" };

export class Store implements HostKeyStore, EnginePersistence {
  private plainPath: string;
  private secretPath: string;
  private plain: Plain;
  private secrets: Record<string, string>;

  constructor(dir: string) {
    fs.mkdirSync(dir, { recursive: true });
    this.plainPath = path.join(dir, "brainbox.json");
    this.secretPath = path.join(dir, "secrets.json");
    this.plain = this.readJSON(this.plainPath) ?? { prefs: DEFAULT_PREFS, hostKeys: {}, ownershipId: makeOwnershipId() };
    this.plain.prefs = { ...DEFAULT_PREFS, ...(this.plain.prefs ?? {}) };
    this.plain.hostKeys ??= {};
    if (!/^[0-9a-f]{32}$/.test(this.plain.ownershipId ?? "")) this.plain.ownershipId = makeOwnershipId();
    this.secrets = this.readJSON(this.secretPath) ?? {};
    this.save();
  }

  private readJSON<T>(file: string): T | undefined {
    try { return JSON.parse(fs.readFileSync(file, "utf8")) as T; } catch { return undefined; }
  }

  private save() {
    fs.writeFileSync(this.plainPath, JSON.stringify(this.plain, null, 2), { mode: 0o600 });
    fs.writeFileSync(this.secretPath, JSON.stringify(this.secrets), { mode: 0o600 });
  }

  /** True when secrets are encrypted by the OS (always on Windows/macOS; Linux needs a keyring). */
  get encrypted(): boolean { return safeStorage.isEncryptionAvailable(); }

  private setSecret(key: string, value: string | undefined) {
    if (value === undefined) delete this.secrets[key];
    else this.secrets[key] = this.encrypted ? "enc:" + safeStorage.encryptString(value).toString("base64") : "raw:" + value;
    this.save();
  }

  private getSecret(key: string): string | undefined {
    const v = this.secrets[key];
    if (!v) return undefined;
    try {
      if (v.startsWith("enc:")) return safeStorage.decryptString(Buffer.from(v.slice(4), "base64"));
      if (v.startsWith("raw:")) return v.slice(4);
    } catch { /* unreadable (another user / machine): treat as missing */ }
    return undefined;
  }

  // ---- identity

  identity(): Identity {
    const raw = this.getSecret("identity");
    if (raw) {
      try { return JSON.parse(raw) as Identity; } catch { /* regenerate below */ }
    }
    return this.regenerateIdentity();
  }

  regenerateIdentity(): Identity {
    const id = generateIdentity(`brainbox-desktop-${process.platform}`);
    this.setSecret("identity", JSON.stringify(id));
    return id;
  }

  /** Test hook: the e2e suite hands in its own key. */
  useIdentity(id: Identity) { this.setSecret("identity", JSON.stringify(id)); }

  // ---- profile & prefs

  get profile() { return this.plain.profile; }
  set profile(p: Profile | undefined) { this.plain.profile = p; this.save(); }
  get prefs() { return this.plain.prefs; }
  set prefs(p: Preferences) { this.plain.prefs = { ...DEFAULT_PREFS, ...p }; this.save(); }
  get ownershipId() { return this.plain.ownershipId; }
  get lastChat() { return this.plain.lastChat; }
  set lastChat(c: string | undefined) { this.plain.lastChat = c; this.save(); }

  // ---- HostKeyStore

  pinned(hostId: string) { return this.plain.hostKeys[hostId]; }
  pin(hostId: string, key: string) { this.plain.hostKeys[hostId] = key; this.save(); }
  forgetHostKey(hostId: string) { delete this.plain.hostKeys[hostId]; this.save(); }

  // ---- EnginePersistence

  loadBackend(hostId: string): BackendRecord | undefined {
    const raw = this.getSecret("backend:" + hostId);
    try { return raw ? (JSON.parse(raw) as BackendRecord) : undefined; } catch { return undefined; }
  }

  saveBackend(hostId: string, record: BackendRecord | undefined) {
    this.setSecret("backend:" + hostId, record ? JSON.stringify(record) : undefined);
  }
}
