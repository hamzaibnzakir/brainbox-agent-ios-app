// Typed access to the preload bridge (window.bb).
import type { TranscriptState } from "../shared/transcript";

export type LinkState =
  | { kind: "idle" }
  | { kind: "connecting"; step: string }
  | { kind: "connected"; info: { target: string; hostFingerprint: string; version?: string; hermesPath: string; reusedBackend: boolean } }
  | { kind: "reconnecting"; attempt: number; reason: string }
  | { kind: "failed"; message: string };

export interface Profile { name: string; target: { host: string; port: number; username: string } }
export interface Preferences { notifyOnFinish: boolean; notifyOnApproval: boolean; desktopBackend: boolean; theme: "system" | "light" | "dark" }

export interface AppState {
  profile?: Profile;
  prefs: Preferences;
  link: LinkState;
  encrypted: boolean;
  publicKey: string;
  keyFingerprint: string;
  authorizedKeysCommand: string;
  lastChat?: string;
  transcripts: Record<string, TranscriptState>;
  platform: string;
  version: string;
}

export interface SessionSummary { id: string; title: string; preview: string; startedAt: number; messageCount: number; source: string }

export interface ScreenLease { holder: "agent" | "human"; viewerHash?: string; since: number; epoch: number; reason: string }
export interface ScreenStatus {
  profileKey: string; supported: boolean; installed: boolean; missing: string[]; running: boolean; geometry: string;
  installCommand?: string; browser?: string; blocker?: string; placement: string; lease: ScreenLease;
}

interface Bridge {
  invoke<T = unknown>(name: string, ...args: unknown[]): Promise<T>;
  on(channel: string, fn: (...args: any[]) => void): () => void;
  screenInput(bytes: Uint8Array): void;
  termInput(id: number, data: string): void;
}

declare global { interface Window { bb: Bridge } }

export const bb = window.bb;

/** Sessions from other surfaces (Telegram, cron…) are read-only: Brainbox never writes into them. */
export const isReadOnly = (source: string) => !["tui", "desktop", "cli", ""].includes(source);
