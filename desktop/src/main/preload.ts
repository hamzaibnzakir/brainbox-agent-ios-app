// The only bridge between the window and the main process. No Node in the page.
import { contextBridge, ipcRenderer, IpcRendererEvent } from "electron";

const EVENTS = new Set([
  "bb:state", "bb:connected", "bb:transcript", "bb:gateway-event", "bb:prefill", "bb:navigate", "bb:screen-ask",
  "bb:screen-data", "bb:screen-closed", "bb:screen-input-lost", "bb:term-data", "bb:term-exit",
]);

contextBridge.exposeInMainWorld("bb", {
  invoke: async (name: string, ...args: unknown[]) => {
    const r = await ipcRenderer.invoke(name, ...args);
    if (!r.ok) {
      const err = new Error(r.error) as Error & { code?: string };
      err.code = r.code;
      throw err;
    }
    return r.value;
  },
  on: (channel: string, fn: (...args: unknown[]) => void) => {
    if (!EVENTS.has(channel)) throw new Error(`unknown channel ${channel}`);
    const listener = (_e: IpcRendererEvent, ...args: unknown[]) => fn(...args);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.removeListener(channel, listener);
  },
  screenInput: (bytes: Uint8Array) => ipcRenderer.send("bb:screen-input", bytes),
  termInput: (id: number, data: string) => ipcRenderer.send("bb:term-input", id, data),
});
