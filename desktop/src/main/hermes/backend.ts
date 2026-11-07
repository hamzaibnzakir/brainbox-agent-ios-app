// Starts or reuses `hermes serve` on the server over SSH, the way Hermes Desktop's SSH mode does.
// A port of HermesKit's RemoteBackend.swift: same scripts, same lockfile, same ownership checks.
//
// Shared: every Brainbox device (phone, PCs) on this server uses ONE backend, so a chat is live on
// all of them at once (Hermes' gateway owns execution; clients attach to the same session). The
// backend lives in ~/.hermes/desktop-ssh/<SHARED_OWNER>/ with its token in a 0600 file next to the
// lock, so any device that can SSH in as this user can adopt it instead of starting its own.
// Backends from older builds (one per device, under the device's ownership id) are stopped.
//
// Not HERMES_DESKTOP=1 (unless asked): on a server that already runs the Hermes gateway (Telegram,
// cron), Desktop mode would start its own cron ticker and reap "unsupervised" gateway processes.
import { createHash, randomBytes } from "node:crypto";
import { SSHConnection } from "./ssh";
import { Tunnel } from "./tunnel";

export interface BackendRecord {
  pid: number;
  port: number;
  nonce: string;
  token: string;
  hermesPath: string;
  version?: string;
  /** Started under the shared directory (older builds kept one backend per device). */
  shared?: boolean;
}

export interface BackendHandle {
  record: BackendRecord;
  reused: boolean;
  /** Reused a backend another device started. */
  adopted?: boolean;
  version?: string;
}

export class BackendError extends Error {
  constructor(public code: "notFound" | "unsupported" | "spawnFailed" | "notReady" | "gated", message: string) {
    super(message);
  }
}

export type BackendStep = "Finding Hermes on the server" | "Checking the running backend" | "Starting Hermes" | "Waiting for Hermes to be ready";

export const randomHex = (bytes: number) => randomBytes(bytes).toString("hex");
export const makeOwnershipId = () => randomHex(16);
/** Single-quotes a value for POSIX sh. */
export const shq = (v: string) => "'" + v.replace(/'/g, "'\\''") + "'";

/** Hermes requires 32 hex for the runtime dir: sha256("brainbox-shared-backend")[:32], fixed. */
export const SHARED_OWNER = "9bfaf1f3f5d1b43167520d9fb4c60c03";

export class RemoteBackend {
  readyTimeoutMs = 120_000;
  /** `ownershipId` names this device's legacy directory (cleaned up); the backend itself is shared. */
  constructor(private ssh: SSHConnection, private ownershipId: string, private desktopMode = false) {}

  get runtimeDir() { return `$HOME/.hermes/desktop-ssh/${SHARED_OWNER}`; }
  get lockPath() { return `${this.runtimeDir}/brainbox-mobile.lock.json`; }
  get tokenPath() { return `${this.runtimeDir}/backend.token`; }
  get legacyDir() { return `$HOME/.hermes/desktop-ssh/${this.ownershipId}`; }

  async locateHermes(): Promise<string> {
    const script = `for c in "$(bash -lc 'command -v hermes' 2>/dev/null </dev/null)" "$(sh -lc 'command -v hermes' 2>/dev/null </dev/null)" \\
  "$HOME/.local/bin/hermes" "$HOME/.hermes/hermes-agent/venv/bin/hermes" "$HOME/.hermes/hermes-agent/.venv/bin/hermes" \\
  /usr/local/bin/hermes /opt/hermes/bin/hermes; do
  if [ -n "$c" ] && [ -x "$c" ]; then echo "HERMES_PATH=$c"; exit 0; fi
done
echo HERMES_MISSING`;
    const res = await this.ssh.exec(script, { timeoutMs: 30_000 });
    const line = res.output.split("\n").find((l) => l.startsWith("HERMES_PATH="));
    if (line) return line.slice("HERMES_PATH=".length).trim();
    throw new BackendError("notFound", "Couldn't find Hermes on the server. Brainbox looks for `hermes` on the login PATH, ~/.local/bin and ~/.hermes/hermes-agent.");
  }

  async readLock(): Promise<BackendRecord | undefined> {
    // Lock JSON on the first line, the token (if the file is there) on the second.
    const res = await this.ssh.exec(`tr -d '\n' < ${this.lockPath} 2>/dev/null; echo; cat ${this.tokenPath} 2>/dev/null`, { timeoutMs: 20_000 });
    const [json, token = ""] = res.output.split("\n");
    try {
      const lock = JSON.parse(json);
      if (typeof lock.pid !== "number" || typeof lock.port !== "number" || typeof lock.nonce !== "string") return undefined;
      return { pid: lock.pid, port: lock.port, nonce: lock.nonce, token: token.trim(), hermesPath: lock.hermesPath, shared: true };
    } catch {
      return undefined;
    }
  }

  /** The backend another device started, when it is alive and its token still opens it. */
  async adopt(): Promise<BackendHandle | undefined> {
    const lock = await this.readLock().catch(() => undefined);
    if (!lock?.token || !/^[0-9a-f]{64}$/.test(lock.token) || !(await this.pidAlive(lock))) return undefined;
    const version = await this.verify(lock);
    return version ? { record: { ...lock, version }, reused: true, adopted: true, version } : undefined;
  }

  /** Stops a backend an older build started for this device alone (only if its argv proves it). */
  async retireLegacy(r: BackendRecord | undefined) {
    if (!r || r.shared || !(await this.pidAlive(r))) return;
    await this.ssh.exec(`kill ${r.pid} 2>/dev/null; rm -f ${this.legacyDir}/brainbox-mobile.lock.json; true`, { timeoutMs: 20_000 }).catch(() => undefined);
  }

  /** Serialises starts across devices: two connecting at once must not start two backends. */
  private async withSpawnLock<T>(body: () => Promise<T>): Promise<T> {
    const dir = `${this.runtimeDir}/spawn.lock`;
    await this.ssh.exec(`umask 077; mkdir -p "$HOME/.hermes/desktop-ssh" "${this.runtimeDir}"; chmod 700 "$HOME/.hermes/desktop-ssh" "${this.runtimeDir}"
for i in $(seq 1 90); do mkdir "${dir}" 2>/dev/null && { echo GOT; exit 0; }
  find "${dir}" -maxdepth 0 -mmin +3 -exec rmdir {} \\; 2>/dev/null; sleep 1; done; echo BUSY`, { timeoutMs: 100_000 });
    try {
      return await body();
    } finally {
      await this.ssh.exec(`rmdir "${dir}" 2>/dev/null; true`, { timeoutMs: 15_000 }).catch(() => undefined);
    }
  }

  async pidAlive(r: BackendRecord): Promise<boolean> {
    const check = `tr '\\0' ' ' < /proc/${r.pid}/cmdline 2>/dev/null | grep -q -- ${shq(`--ssh-owner-nonce ${r.nonce}`)} && echo ALIVE || (kill -0 ${r.pid} 2>/dev/null && ps -o args= -p ${r.pid} 2>/dev/null | grep -q -- ${shq(r.nonce)} && echo ALIVE) || echo DEAD`;
    try {
      return (await this.ssh.exec(check, { timeoutMs: 20_000 })).output.includes("ALIVE");
    } catch {
      return false;
    }
  }

  /** The Hermes version when `record` is a live backend this PC owns and can authenticate to. */
  async verify(r: BackendRecord): Promise<string | undefined> {
    const tunnel = new Tunnel(this.ssh, r.port, r.token);
    try {
      const own = await tunnel.request("GET", "/api/ssh/ownership", { timeoutMs: 15_000 });
      if (own.status !== 200 || JSON.parse(own.text)?.sshOwnerNonce !== r.nonce) return undefined;
    } catch {
      return undefined;
    }
    for (const path of ["/api/health", "/api/status"]) {
      try {
        const res = await tunnel.request("GET", path, { timeoutMs: 15_000 });
        const body = JSON.parse(res.text);
        if (typeof body?.version === "string" && body.version) {
          return body.version === "unknown" && typeof body.displayVersion === "string" && body.displayVersion ? body.displayVersion : body.version;
        }
      } catch { /* try the next */ }
    }
    return "unknown";
  }

  async ensure(known: BackendRecord | undefined, progress: (s: BackendStep) => void = () => {}): Promise<BackendHandle> {
    progress("Checking the running backend");
    if (known?.shared && await this.pidAlive(known)) {
      const version = await this.verify(known);
      if (version) return { record: { ...known, version }, reused: true, version };
    }
    const adopted = await this.adopt();
    if (adopted) {
      await this.retireLegacy(known);
      return adopted;
    }
    await this.retireLegacy(known);
    return this.withSpawnLock(async () => {
      // Another device may have finished starting one while we waited for the lock.
      const late = await this.adopt();
      if (late) return late;
      progress("Finding Hermes on the server");
      const hermes = await this.locateHermes();
      progress("Starting Hermes");
      return this.spawn(hermes, progress);
    });
  }

  async spawn(hermesPath: string, progress: (s: BackendStep) => void = () => {}): Promise<BackendHandle> {
    const token = randomHex(32);
    const nonce = randomHex(8);
    const log = `${this.runtimeDir}/${nonce}.log`;
    const tokenFile = `${this.runtimeDir}/${nonce}.token`;
    // Stop a previous backend of ours first (only if its argv proves it is ours).
    const old = await this.readLock().catch(() => undefined);
    if (old && await this.pidAlive(old)) {
      await this.ssh.exec(`kill ${old.pid} 2>/dev/null; sleep 1; kill -0 ${old.pid} 2>/dev/null && kill -9 ${old.pid} 2>/dev/null; true`, { timeoutMs: 20_000 }).catch(() => undefined);
    }
    const env = this.desktopMode ? "env HERMES_DESKTOP=1 " : "";
    const script = `umask 077
root="$HOME/.hermes/desktop-ssh"; dir="${this.runtimeDir}"
mkdir -p "$root" "$dir" && chmod 700 "$root" "$dir" || exit 71
cat > "${tokenFile}" || exit 72
chmod 600 "${tokenFile}"
find "$dir" -name '*.log' -mtime +3 -delete 2>/dev/null
: > "${log}"
launcher="$(command -v setsid || echo nohup)"
child=$("$launcher" sh -c 'ulimit -n 4096 2>/dev/null; exec ${env}"$0" serve --isolated --host 127.0.0.1 --port 0 --ssh-session-token-file "$1" --ssh-owner-nonce "$2" </dev/null >>"$3" 2>&1 & echo $!' ${shq(hermesPath)} "${tokenFile}" ${nonce} "${log}")
echo "PID=$child"`;
    const res = await this.ssh.exec(script, { stdin: token, timeoutMs: 40_000 });
    const pidLine = res.output.split("\n").find((l) => l.startsWith("PID="));
    const pid = pidLine ? parseInt(pidLine.slice(4).trim(), 10) : NaN;
    if (!Number.isFinite(pid)) throw new BackendError("spawnFailed", `Hermes didn't start: ${(res.errorOutput + res.output).trim()}`);

    progress("Waiting for Hermes to be ready");
    const deadline = Date.now() + this.readyTimeoutMs;
    let port: number | undefined;
    while (Date.now() < deadline) {
      const probe = await this.ssh.exec(
        `grep -o 'HERMES_\\(BACKEND\\|DASHBOARD\\)_READY port=[0-9]*' "${log}" | head -n1; kill -0 ${pid} 2>/dev/null && echo RUNNING || { echo EXITED; tail -n 15 "${log}"; }`,
        { timeoutMs: 20_000 });
      const m = /port=(\d+)/.exec(probe.output);
      if (m) { port = parseInt(m[1], 10); break; }
      if (probe.output.includes("EXITED")) {
        const tail = probe.output.split("EXITED").pop()!.trim();
        if (tail.includes("ssh-session-token-file") || tail.includes("unrecognized arguments")) {
          throw new BackendError("unsupported", `This Hermes version can't run the Desktop backend over SSH (${tail.slice(-300)}). Update Hermes on the server.`);
        }
        throw new BackendError("spawnFailed", `Hermes didn't start: ${tail.slice(-600)}`);
      }
      await new Promise((r) => setTimeout(r, 750));
    }
    if (port === undefined) {
      const tail = (await this.ssh.exec(`tail -n 15 "${log}"`, { timeoutMs: 15_000 }).catch(() => undefined))?.output ?? "";
      throw new BackendError("notReady", `Hermes started but never reported ready. Last log lines:\n${tail}`);
    }

    const record: BackendRecord = { pid, port, nonce, token, hermesPath, shared: true };
    const lock = {
      schemaVersion: 1, owner: "brainbox-mobile", pid, port, nonce, hermesPath,
      tokenFingerprint: createHash("sha256").update(token).digest("hex").slice(0, 32),
    };
    // Token first, lock last: a device that reads the lock always finds the matching token.
    await this.ssh.exec(`umask 077; printf %s ${token} > ${this.tokenPath}.tmp && mv -f ${this.tokenPath}.tmp ${this.tokenPath} && cat > ${this.lockPath}.tmp && mv -f ${this.lockPath}.tmp ${this.lockPath}`,
      { stdin: JSON.stringify(lock), timeoutMs: 20_000 }).catch(() => undefined);
    const version = await this.verify(record);
    return { record: { ...record, version }, reused: false, version };
  }

  /** Stops the shared Brainbox backend (never anything else); other devices reconnect to a new one. */
  async stop(r: BackendRecord): Promise<void> {
    if (await this.pidAlive(r)) {
      const files = !r.shared ? `${this.legacyDir}/brainbox-mobile.lock.json` : `${this.lockPath} ${this.tokenPath}`;
      await this.ssh.exec(`kill ${r.pid} 2>/dev/null; rm -f ${files}`, { timeoutMs: 20_000 }).catch(() => undefined);
    }
  }
}
