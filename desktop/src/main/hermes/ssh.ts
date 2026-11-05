// SSH to the server with the PC's own Ed25519 key (ssh2). Mirrors HermesKit's SSHConnection:
// key auth only, host key pinned on first use (OpenSSH accept-new) and refused if it changes.
import { createHash } from "node:crypto";
import { Client, ClientChannel, utils } from "ssh2";

export interface SSHTarget {
  host: string;
  port: number;
  username: string;
}

export const hostId = (t: SSHTarget) => (t.port === 22 ? t.host.toLowerCase() : `[${t.host.toLowerCase()}]:${t.port}`);
export const displayTarget = (t: SSHTarget) => `${t.username}@${t.host}${t.port === 22 ? "" : `:${t.port}`}`;

/** Pins each server's host key (base64 of its wire blob). */
export interface HostKeyStore {
  pinned(hostId: string): string | undefined;
  pin(hostId: string, keyBase64: string): void;
}

export class MemoryHostKeys implements HostKeyStore {
  constructor(private keys: Record<string, string> = {}) {}
  pinned(id: string) { return this.keys[id]; }
  pin(id: string, key: string) { this.keys[id] = key; }
}

export class SSHError extends Error {
  constructor(public code: "connect" | "timeout" | "auth" | "hostKeyChanged" | "channel" | "closed", message: string,
              public expected?: string, public got?: string) {
    super(message);
  }
}

/** `SHA256:…` like `ssh-keygen -lf`, from a key's base64 wire blob. */
export function fingerprint(keyBase64: string): string {
  return "SHA256:" + createHash("sha256").update(Buffer.from(keyBase64, "base64")).digest("base64").replace(/=+$/, "");
}

export interface Identity {
  /** OpenSSH private key text. */
  privateKey: string;
  /** `ssh-ed25519 AAAA… comment`, for authorized_keys. */
  publicLine: string;
}

export function generateIdentity(comment = "brainbox-desktop"): Identity {
  const pair = utils.generateKeyPairSync("ed25519", { comment });
  return { privateKey: pair.private, publicLine: pair.public.trim() };
}

export function identityFingerprint(id: Identity): string {
  return fingerprint(id.publicLine.split(" ")[1] ?? "");
}

/** The one line that lets this PC in. */
export function authorizedKeysCommand(id: Identity): string {
  const line = id.publicLine.replace(/'/g, "");
  return `mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${line}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`;
}

export interface ExecResult {
  stdout: Buffer;
  stderr: Buffer;
  code: number | null;
  output: string;
  errorOutput: string;
}

export class SSHConnection {
  private closed = false;
  private constructor(public readonly target: SSHTarget, public readonly hostKey: string, private readonly client: Client) {
    client.on("close", () => { this.closed = true; });
    client.on("end", () => { this.closed = true; });
  }

  get isActive() { return !this.closed; }
  get hostFingerprint() { return fingerprint(this.hostKey); }

  onClose(fn: () => void) { this.client.once("close", fn); }

  static connect(target: SSHTarget, identity: Identity, hostKeys: HostKeyStore, timeoutMs = 20_000): Promise<SSHConnection> {
    return new Promise((resolve, reject) => {
      const client = new Client();
      let presented = "";
      let mismatch: SSHError | undefined;
      let settled = false;
      const done = (err?: Error) => {
        if (settled) return;
        settled = true;
        if (err) { client.end(); reject(err); } else resolve(new SSHConnection(target, presented, client));
      };
      client.on("ready", () => done());
      client.on("error", (err: Error & { level?: string }) => {
        if (mismatch) return done(mismatch);
        if (err.level === "client-authentication") {
          return done(new SSHError("auth", "The server refused this PC's SSH key. Add the key shown in Connection to ~/.ssh/authorized_keys on the server."));
        }
        if (/timed out/i.test(err.message)) return done(new SSHError("timeout", "Timed out waiting for the SSH handshake."));
        done(new SSHError("connect", `Couldn't reach the server: ${err.message}`));
      });
      client.connect({
        host: target.host,
        port: target.port,
        username: target.username,
        privateKey: identity.privateKey,
        readyTimeout: timeoutMs,
        keepaliveInterval: 15_000,
        keepaliveCountMax: 3,
        tryKeyboard: false,
        hostVerifier: (key: Buffer) => {
          presented = key.toString("base64");
          const id = hostId(target);
          const pinned = hostKeys.pinned(id);
          if (!pinned) { hostKeys.pin(id, presented); return true; }
          if (pinned === presented) return true;
          mismatch = new SSHError("hostKeyChanged",
            `The server's identity changed (expected ${fingerprint(pinned)}, got ${fingerprint(presented)}). This can mean someone is intercepting the connection, or the server was reinstalled. Brainbox won't connect until you reset the trusted key in Connection.`,
            fingerprint(pinned), fingerprint(presented));
          return false;
        },
      });
    });
  }

  /** Runs a command; `stdin` is written then closed (how secrets reach a remote command). */
  exec(command: string, opts: { stdin?: Buffer | string; timeoutMs?: number } = {}): Promise<ExecResult> {
    return new Promise((resolve, reject) => {
      if (this.closed) return reject(new SSHError("closed", "The SSH connection closed."));
      this.client.exec(command, (err, stream) => {
        if (err) return reject(new SSHError("channel", `SSH channel error: ${err.message}`));
        const out: Buffer[] = [];
        const errs: Buffer[] = [];
        let code: number | null = null;
        const timer = setTimeout(() => {
          stream.close();
          reject(new SSHError("timeout", "Timed out running a command on the server."));
        }, opts.timeoutMs ?? 60_000);
        stream.on("data", (d: Buffer) => out.push(d));
        stream.stderr.on("data", (d: Buffer) => errs.push(d));
        stream.on("exit", (c: number | null) => { code = c; });
        stream.on("close", () => {
          clearTimeout(timer);
          const stdout = Buffer.concat(out);
          const stderr = Buffer.concat(errs);
          resolve({ stdout, stderr, code, output: stdout.toString("utf8"), errorOutput: stderr.toString("utf8") });
        });
        if (opts.stdin !== undefined) stream.end(opts.stdin);
        else stream.end();
      });
    });
  }

  /** A TCP stream to `host:port` as seen from the server (`ssh -L`'s building block). */
  forward(port: number, host = "127.0.0.1"): Promise<ClientChannel> {
    return new Promise((resolve, reject) => {
      if (this.closed) return reject(new SSHError("closed", "The SSH connection closed."));
      this.client.forwardOut("127.0.0.1", 0, host, port, (err, stream) => {
        if (err) reject(new SSHError("channel", `SSH tunnel error: ${err.message}`));
        else resolve(stream);
      });
    });
  }

  /** An interactive login shell on a PTY. Erase = DEL, interrupt = ^C, stated explicitly. */
  shell(cols: number, rows: number): Promise<ClientChannel> {
    return new Promise((resolve, reject) => {
      if (this.closed) return reject(new SSHError("closed", "The SSH connection closed."));
      this.client.shell({ term: "xterm-256color", cols, rows, modes: { VERASE: 127, VINTR: 3 } }, (err, stream) => {
        if (err) reject(new SSHError("channel", `SSH shell error: ${err.message}`));
        else resolve(stream);
      });
    });
  }

  close() {
    this.closed = true;
    this.client.end();
  }
}
