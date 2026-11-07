import { describe, expect, it } from "vitest";
import { Transcript, asksForTakeover, isScreenTool, stripBoxDrawing } from "../src/shared/transcript";
import { ScreenError, parseStatus, ticketPath } from "../src/main/hermes/screen";
import { RPCError } from "../src/main/hermes/rpc";
import { fingerprint, hostId } from "../src/main/hermes/ssh";
import { shq } from "../src/main/hermes/backend";

describe("Transcript", () => {
  it("streams deltas and the final text wins", () => {
    const t = new Transcript();
    t.apply({ type: "message.start", sessionId: "s", seq: 1, payload: {} });
    t.apply({ type: "message.delta", sessionId: "s", seq: 2, payload: { text: "Hel" } });
    t.apply({ type: "message.delta", sessionId: "s", seq: 3, payload: { text: "lo" } });
    expect(t.busy).toBe(true);
    t.apply({ type: "message.complete", sessionId: "s", seq: 4, payload: { text: "Hello!" } });
    const last = t.items[t.items.length - 1];
    expect(last.kind === "assistant" && last.text).toBe("Hello!");
    expect(t.busy).toBe(false);
    expect(t.apply({ type: "message.delta", sessionId: "s", seq: 3, payload: { text: "dup" } })).toBe(false);
    expect(t.lastSeq).toBe(4);
  });

  it("tracks tools, approvals (both styles) and resolution", () => {
    const t = new Transcript();
    t.apply({ type: "tool.start", payload: { tool_id: "1", name: "browser_navigate", context: "example.com" } });
    t.apply({ type: "tool.complete", payload: { tool_id: "1", result: { output: "ok" }, duration_s: 1.5 } });
    const tool = t.items.find((i) => i.kind === "tool");
    expect(tool?.kind === "tool" && tool.tool.status).toBe("done");
    t.apply({ type: "approval.request", payload: { request_id: "r1", command: "rm -rf x", choices: ["once", "deny"] } });
    t.apply({ type: "server.request", payload: { id: "srq-1", method: "clarify", params: { questions: [{ qid: "q1", question: "Which?", choices: ["a", "b"] }] } } });
    expect(t.pendingRequests.map((r) => r.requestId)).toEqual(["r1", "srq-1"]);
    expect(t.pendingRequests[1].serverRequestId).toBe("srq-1");
    t.resolve("r1", "Approved (once)");
    t.apply({ type: "request.cancel", payload: { id: "srq-1" } });
    expect(t.pendingRequests).toHaveLength(0);
  });

  it("hydrates history and spots takeover asks", () => {
    const t = new Transcript();
    t.hydrate([{ role: "user", text: "log in to meta" }, { role: "tool", name: "browser_navigate", text: "loaded" },
               { role: "assistant", text: "I reached the login page. Please take over and sign in." }]);
    expect(t.items.map((i) => i.kind)).toEqual(["user", "tool", "assistant"]);
    expect(asksForTakeover("Please take over and sign in.", t.snapshot())).toBe(true);
    expect(asksForTakeover("All done.", t.snapshot())).toBe(false);
    expect(isScreenTool("computer_use")).toBe(true);
    expect(isScreenTool("terminal")).toBe(false);
    expect(stripBoxDrawing("+---+\n|  hi  |\n+---+")).toBe("hi");
  });
});

describe("helpers", () => {
  it("screen status, ticket path and errors", () => {
    const s = parseStatus({ supported: true, installed: false, missing: ["Xvnc"], running: false, lease: { holder: "human", epoch: 2, since: 1 } });
    expect(s.installed).toBe(false);
    expect(s.lease.holder).toBe("human");
    expect(ticketPath({ ticket: "a+b/=", path: "/api/display/ws" })).toBe("/api/display/ws?display_ticket=a%2Bb%2F%3D");
    expect(ScreenError.fromClose(1000, "")).toBeUndefined();
    expect(ScreenError.fromClose(4000, "")?.code).toBe("controlTaken");
    expect((ScreenError.from(new RPCError(-32601, "unknown method")) as ScreenError).code).toBe("unsupportedHermes");
    expect((ScreenError.from(new RPCError(5300, "x", { code: "viewer_mismatch" })) as ScreenError).code).toBe("staleViewer");
  });

  it("ssh helpers", () => {
    expect(hostId({ host: "VPS.example", port: 22, username: "root" })).toBe("vps.example");
    expect(hostId({ host: "h", port: 2222, username: "root" })).toBe("[h]:2222");
    expect(fingerprint(Buffer.from("abc").toString("base64"))).toMatch(/^SHA256:[A-Za-z0-9+/]+$/);
    expect(shq("it's")).toBe("'it'\\''s'");
  });
});

describe("turns from another device", () => {
  it("places the other device's prompt above its reply, once", () => {
    const t = new Transcript();
    t.addUser("mine");
    t.apply({ type: "message.start", payload: {} });
    expect(t.remoteTurn).toBe(false);
    t.apply({ type: "message.complete", payload: { text: "Echo: mine" } });

    t.apply({ type: "message.start", payload: {} });
    expect(t.remoteTurn).toBe(true);
    t.apply({ type: "message.delta", payload: { text: "Echo: theirs" } });
    const history = [{ role: "user", text: "mine" }, { role: "assistant", text: "Echo: mine" }, { role: "user", text: "theirs" }];
    expect(t.placeRemotePrompt(history)).toBe(true);
    expect(t.placeRemotePrompt(history)).toBe(false);
    t.apply({ type: "message.complete", payload: { text: "Echo: theirs" } });
    expect(t.items.map((i) => i.kind + ":" + ("text" in i ? i.text : ""))).toEqual(
      ["user:mine", "assistant:Echo: mine", "user:theirs", "assistant:Echo: theirs"]);
  });
});
