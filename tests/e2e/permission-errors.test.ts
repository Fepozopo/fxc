/** Exercises permission outcomes through the built CLI and isolated local gateways. */
import { describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayPermissionDecision,
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 120_000;

type FxJson = {
  output: string;
  exit_code: number;
  tool_calls: Array<{ name: string; status: string }>;
};

type PermissionEcho = {
  type: string;
  tool_name: string;
  message: string;
  reason: string;
  denied: boolean;
};

/** Command input and expected permission and filesystem outcomes for one scenario. */
type CompoundPermissionCase = {
  name: string;
  command: string;
  reason: "policy_denied" | "permission_required" | null;
  created: string[];
};

function createIsolatedRoot(prefix: string) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home, { recursive: true });
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  return { root, home, workspace };
}

function parseFxJson(result: { stdout: string; stderr: string; code: number | null }): FxJson {
  if (result.code !== 0) {
    throw new Error(`fx exited ${result.code}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
  }
  return JSON.parse(result.stdout.trim()) as FxJson;
}

function executionDeniedReason(body: string, toolCallId: string): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const result = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((part) => part.type === "tool-result" && part.toolCallId === toolCallId);
  expect(result).toBeDefined();
  const output = result!.output as Record<string, unknown>;
  expect(output.type).toBe("execution-denied");
  expect(typeof output.reason).toBe("string");
  expect(output.value).toBeUndefined();
  return output.reason as string;
}

function permissionEnv(
  home: string,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "permission-error-fake-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

async function waitForPaneExit(
  session: TmuxSession,
  expectedStatus: number,
) {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    const status = session.paneStatus();
    if (status.dead) {
      expect(status.status).toBe(expectedStatus);
      return;
    }
    await Bun.sleep(25);
  }
  throw new Error(
    `Timed out waiting for fx ask to exit.\n${await session.captureFullScrollback()}`,
  );
}

async function runTtyPromptPermissionsCase(
  outputMode: "json" | "quiet",
  decision: "approve" | "deny",
) {
  const root = createIsolatedRoot(
    `fx-${outputMode}-prompt-permissions-${decision}-`,
  );
  const marker = join(root.workspace, `${decision}-marker.txt`);
  const stdoutPath = join(root.root, `${decision}.stdout`);
  writeFileSync(
    join(root.home, ".fx", "settings.json"),
    JSON.stringify({ permission_mode: "ask", sandbox: "none" }),
  );
  writeFileSync(stdoutPath, "");
  const gateway = startFakeGateway([
    fakeShellRun(`${decision}_${outputMode}_call`, `touch ${JSON.stringify(marker)}`, {
      timeout_ms: 600_000,
    }),
    fakeGatewayFinalText(`${decision} ${outputMode} complete`),
  ]);
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: `${JSON.stringify(FX_BIN)} ask --${outputMode} --prompt-permissions --no-save "Run the exact ${outputMode} fixture." > ${JSON.stringify(stdoutPath)}`,
      cwd: root.workspace,
      env: permissionEnv(root.home, gateway),
      remainOnExit: true,
    });
    const prompt = await session.waitForText("Approve? [y/N]", TIMEOUT);
    expect(prompt).toContain("fx wants to run:");
    expect(existsSync(marker)).toBe(false);
    await session.sendText(decision === "approve" ? "y" : "n");
    await waitForPaneExit(session, 0);

    const stdout = readFileSync(stdoutPath, "utf8");
    expect(stdout).not.toContain("Approve? [y/N]");
    if (outputMode === "json") {
      const json = JSON.parse(stdout) as FxJson;
      expect(json.exit_code).toBe(0);
      expect(json.tool_calls).toContainEqual(
        expect.objectContaining({
          name: "shell",
          status: decision === "approve" ? "success" : "error",
        }),
      );
    } else {
      expect(stdout).toBe("");
    }
    expect(existsSync(marker)).toBe(decision === "approve");
    expect(gateway.requests).toHaveLength(2);
  } finally {
    if (session) await session.kill();
    gateway.stop();
    rmSync(root.root, { recursive: true, force: true });
  }
}

describe("generic permission typed errors", () => {
  // This file remains in the PGSO training corpus: checking configured shell
  // rules is a common admission path, even when a particular outcome is denial.
  const compoundPermissionCases: CompoundPermissionCase[] = [
    { name: "allowed list", command: "touch first && touch second", reason: null, created: ["first", "second"] },
    { name: "shell short-circuiting", command: "false && touch first || touch second", reason: null, created: ["second"] },
    { name: "semicolon list", command: "touch first; touch second", reason: null, created: ["first", "second"] },
    { name: "newline list", command: "touch first\ntouch second", reason: null, created: ["first", "second"] },
    { name: "pipeline", command: "true | touch second", reason: null, created: ["second"] },
    { name: "stderr pipeline", command: "true |& touch second", reason: null, created: ["second"] },
    { name: "background list", command: "true & touch second", reason: null, created: ["second"] },
    { name: "denied later command", command: "touch first && git add protected", reason: "policy_denied", created: [] },
    { name: "approval-required later command", command: "touch first && rm protected", reason: "permission_required", created: [] },
    { name: "unsupported redirection", command: "touch first && printf one > second", reason: "permission_required", created: [] },
  ];
  test.each(compoundPermissionCases)("compound shell permissions: $name", async ({ command, reason, created }: CompoundPermissionCase) => {
    const root = createIsolatedRoot("fx-compound-permissions-");
    const toolCallId = "compound_command";
    const gateway = startFakeGateway([
      fakeShellRun(toolCallId, command, { timeout_ms: 600_000 }),
      fakeGatewayFinalText("compound permission observed"),
    ]);
    try {
      writeFileSync(join(root.workspace, "protected"), "keep");
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({
          permission_mode: "ask",
          permission: {
            "*": "allow",
            delete_file: { "*": "ask" },
            bash: {
              "*": "allow",
              "git add *": "deny",
              "git commit *": "deny",
              "git push *": "deny",
              "rm *": "ask",
            },
          },
        }),
      );
      const result = await runFx(["ask", "--json", "--quiet", "--no-save", "Run the compound command."], {
        cwd: root.workspace,
        env: permissionEnv(root.home, gateway),
        timeoutMs: TIMEOUT,
      });
      const requiresApproval = reason === "permission_required";
      expect(result.code, `${command}: exit status`).toBe(requiresApproval ? 1 : 0);
      const json = JSON.parse(result.stdout.trim()) as FxJson & { error?: string };
      if (requiresApproval) {
        expect(json.error).toBe("NonInteractivePermissionRequired");
        expect(result.stderr).toContain("reason=noninteractive_permission_prompt_unavailable");
      } else {
        expect(result.stderr).not.toContain("permission required");
      }
      expect(json.tool_calls).toContainEqual(expect.objectContaining({
        name: "shell",
        status: reason === null ? "success" : "error",
      }));
      for (const name of ["first", "second"]) {
        expect(existsSync(join(root.workspace, name)), `${command}: ${name}`).toBe(created.includes(name));
      }
      expect(readFileSync(join(root.workspace, "protected"), "utf8")).toBe("keep");
      expect(gateway.requests).toHaveLength(requiresApproval ? 1 : 2);
      expect(gateway.classifierRequests).toHaveLength(0);
      if (reason === "policy_denied") {
        const echo = JSON.parse(executionDeniedReason(gateway.requests[1]!.body, toolCallId)) as { error: PermissionEcho };
        expect(echo.error.reason).toBe(reason);
      }
    } finally {
      gateway.stop();
      rmSync(root.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test("configured bash wildcard approves a double-quoted regex in ask mode", async () => {
    const root = createIsolatedRoot("fx-quoted-command-permissions-");
    const literal = "usage|token.*update|turn_summary|token_progress|input_tokens";
    const toolCallId = "quoted_literal_command";
    // The local gateway emits the exact shell call, avoiding model-dependent quoting.
    const gateway = startFakeGateway([
      fakeShellRun(toolCallId, `printf "%s" "${literal}"`, { timeout_ms: 600_000 }),
      fakeGatewayFinalText("literal command observed"),
    ]);
    try {
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "ask", permission: { bash: { "*": "allow" } } }),
      );
      const result = await runFx(["ask", "--json", "--quiet", "--no-save", "Run the literal command."], {
        cwd: root.workspace,
        env: { ...permissionEnv(root.home, gateway), FX_SOUND: "0" },
        timeoutMs: TIMEOUT,
      });
      const json = parseFxJson(result);
      expect(json.exit_code).toBe(0);
      expect(result.stderr).not.toContain("permission required");
      expect(json.tool_calls).toContainEqual(expect.objectContaining({ name: "shell", status: "success" }));
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      const continuation = JSON.parse(gateway.requests[1]!.body) as {
        prompt: Array<{ content: Array<{ type: string; toolCallId?: string; output?: { value?: string } }> }>;
      };
      const resultPart = continuation.prompt.flatMap((message) => message.content)
        .find((part) => part.type === "tool-result" && part.toolCallId === toolCallId);
      expect(resultPart?.output?.value).toContain(literal);
    } finally {
      gateway.stop();
      rmSync(root.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test(
    "returns typed JSON for denied terminal",
    async () => {
      const root = createIsolatedRoot("fx-permission-error-");
      const marker = join(root.workspace, "denied-marker.txt");
      const toolCallId = "permission_denied_call";
      const gateway = startFakeGateway([
        fakeShellRun(toolCallId, `touch ${JSON.stringify(marker)}`, {
          timeout_ms: 600_000,
        }),
        fakeGatewayFinalText("permission error observed"),
      ]);
      try {
        writeFileSync(
          join(root.home, ".fx", "settings.json"),
          JSON.stringify({
            workspaces: {
              [root.workspace]: {
                permission: {
                  bash: {
                    "touch *denied-marker.txt*": "deny",
                  },
                },
              },
            },
          }),
        );

        const result = await runFx(["ask", "--json", "--no-save", "--auto", "Run the denied command."], {
          cwd: root.workspace,
          env: {
            HOME: root.home,
            AI_GATEWAY_API_KEY: "permission-error-fake-key",
            VERCEL_OIDC_TOKEN: undefined,
            FX_GATEWAY_BASE_URL: gateway.baseUrl,
            FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
            FX_MODEL: FAKE_GATEWAY_MODEL,
            FX_AUTO_UPGRADE: "0",
          },
          timeoutMs: TIMEOUT,
        });
        const json = parseFxJson(result);
        expect(result.stderr).toBe('Running touch "./denied-marker.txt"\n');
        expect(json.tool_calls).toContainEqual({
          name: "shell",
          status: "error",
          action: "run",
          error: {
            category: "rejected",
            code: "rejected",
          },
        });
        expect(existsSync(marker)).toBe(false);
        expect(gateway.requests).toHaveLength(2);

        const toolResult = JSON.parse(
          executionDeniedReason(gateway.requests[1]!.body, toolCallId),
        ) as { error: PermissionEcho };
        const echo = toolResult.error;
        expect(echo.type).toBe("tool_permission_denied");
        expect(echo.tool_name).toBe("shell");
        expect(echo.message).toBe("Tool access was denied by configured policy");
        expect(echo.reason).toBe("policy_denied");
        expect(echo.denied).toBe(true);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "JSON prompt-permissions approval and denial preserve stdout and exact execution",
    async () => {
      for (const decision of ["approve", "deny"] as const) {
        await runTtyPromptPermissionsCase("json", decision);
      }
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "JSON prompt-permissions does not prompt after repeated advisory cautions",
    async () => {
      const root = createIsolatedRoot("fx-json-auto-prompt-permissions-");
      const markers = Array.from(
        { length: 4 },
        (_, index) => join(root.workspace, `auto-marker-${index + 1}.txt`),
      );
      const stdoutPath = join(root.root, "auto.stdout");
      writeFileSync(
        join(root.home, ".fx", "settings.json"),
        JSON.stringify({ permission_mode: "auto", sandbox: "none" }),
      );
      writeFileSync(stdoutPath, "");
      const gateway = startFakeGateway(
        [
          ...markers.map((marker, index) => (body?: string) => {
            if (index > 0) expect(body).toContain("review_caution");
            return fakeShellRun(
              `auto_call_${index + 1}`,
              `touch ${JSON.stringify(marker)}`,
              { timeout_ms: 600_000 },
            );
          }),
          fakeGatewayFinalText("Advisory cautions handled normally."),
        ],
        {
          classifierResponses: Array.from(
            { length: 4 },
            (_, index) => fakeGatewayPermissionDecision(
              "caution",
              `auto_review_${index + 1}`,
            ),
          ),
        },
      );
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: `${JSON.stringify(FX_BIN)} ask --auto --json --prompt-permissions --no-save "Run the advisory caution fixture." > ${JSON.stringify(stdoutPath)}`,
          cwd: root.workspace,
          env: permissionEnv(root.home, gateway),
          remainOnExit: true,
        });
        await waitForPaneExit(session, 0);
        const scrollback = await session.captureFullScrollback();
        expect(scrollback).not.toContain("Approve? [y/N]");
        for (const marker of markers) expect(existsSync(marker)).toBe(false);
        expect(gateway.classifierRequests).toHaveLength(4);

        const stdout = readFileSync(stdoutPath, "utf8");
        expect(stdout).not.toContain("Approve? [y/N]");
        const json = JSON.parse(stdout) as FxJson;
        expect(json.output).toContain("Advisory cautions handled normally.");
        expect(json.tool_calls.filter((call) => call.status === "error")).toHaveLength(4);
        expect(json.tool_calls.filter((call) => call.status === "success")).toHaveLength(0);
        expect(gateway.requests).toHaveLength(5);
        expect(gateway.classifierRequests).toHaveLength(4);
      } finally {
        if (session) await session.kill();
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "quiet prompt-permissions approval and denial keep stdout empty",
    async () => {
      for (const decision of ["approve", "deny"] as const) {
        await runTtyPromptPermissionsCase("quiet", decision);
      }
    },
    TIMEOUT,
  );

  test(
    "JSON and quiet permission prompting remain fail-closed without a TTY or explicit opt in",
    async () => {
      const cases = [
        { mode: "json", args: ["--json"], optIn: false },
        { mode: "json", args: ["--json", "--prompt-permissions"], optIn: true },
        { mode: "quiet", args: ["--quiet"], optIn: false },
        { mode: "quiet", args: ["--quiet", "--prompt-permissions"], optIn: true },
      ] as const;

      for (const testCase of cases) {
        const root = createIsolatedRoot(
          `fx-${testCase.mode}-${testCase.optIn ? "opt-in" : "default"}-non-tty-`,
        );
        const marker = join(root.workspace, "must-not-run.txt");
        writeFileSync(
          join(root.home, ".fx", "settings.json"),
          JSON.stringify({ permission_mode: "ask", sandbox: "none" }),
        );
        const gateway = startFakeGateway([
          fakeShellRun("non_tty_call", `touch ${JSON.stringify(marker)}`, {
            timeout_ms: 600_000,
          }),
        ]);
        try {
          const result = await runFx(
            [
              "ask",
              ...testCase.args,
              "--no-save",
              "Run the non-TTY fixture.",
            ],
            {
              cwd: root.workspace,
              env: permissionEnv(root.home, gateway),
              timeoutMs: TIMEOUT,
            },
          );

          expect(result.timedOut).toBe(false);
          expect(result.code).toBe(1);
          expect(result.stderr).toContain("noninteractive_permission_prompt_unavailable");
          expect(result.stderr).not.toContain("Approve? [y/N]");
          if (testCase.mode === "json") {
            const json = JSON.parse(result.stdout) as FxJson & {
              error: string;
            };
            expect(json.error).toBe("NonInteractivePermissionRequired");
          } else {
            expect(result.stdout).toBe("");
          }
          expect(gateway.requests).toHaveLength(1);
          expect(existsSync(marker)).toBe(false);
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT,
  );
});
