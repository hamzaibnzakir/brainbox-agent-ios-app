declare module "@novnc/novnc" {
  export default class RFB extends EventTarget {
    constructor(target: HTMLElement, urlOrChannel: string | object, options?: { shared?: boolean; credentials?: object; wsProtocols?: string[] });
    viewOnly: boolean;
    scaleViewport: boolean;
    clipViewport: boolean;
    dragViewport: boolean;
    resizeSession: boolean;
    showDotCursor: boolean;
    focusOnClick: boolean;
    qualityLevel: number;
    compressionLevel: number;
    background: string;
    disconnect(): void;
    focus(options?: FocusOptions): void;
    blur(): void;
    sendCtrlAltDel(): void;
    sendKey(keysym: number, code: string | null, down?: boolean): void;
    clipboardPasteFrom(text: string): void;
    addEventListener(type: string, listener: (e: CustomEvent) => void): void;
  }
}
