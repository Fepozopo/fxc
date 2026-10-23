// `bun run verify` from tests/tla/image_route/: the one gate for the image
// route design. In order, and every step must pass:
//
//   1. the pinned TLC and the Java that runs it;
//   2. TLC on ImageRoute.tla with MCImageRoute.cfg, which also writes the
//      state graph;
//   3. the harness, built from the real src/core/images/image_route.zig;
//   4. spec to code: every graph edge replayed against the real core;
//   5. code to spec: scripted and random traces with faults, checked by TLC;
//   6. every planted bug in the spec caught by its property;
//   7. every planted bug in the code caught in both directions;
//   8. traceability: DESIGN.md accounts for every question, rule, and law.
//
// Settings: FX_IMAGE_ROUTE_SEED (default 20261019), FX_IMAGE_ROUTE_TRACES
// (random traces, default 300), FX_TLA_OUT (where the report goes).
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { outDir, writeJson } from "../lib/tlc.ts";
import { codeToSpec } from "./code-to-spec.ts";
import { MODEL_DIR, PINNED_TLC_VERSION, buildHarness, checkTlc, pinnedToolchain, specFiles } from "./lib.ts";
import { codeMutations, specMutations } from "./mutations.ts";
import { specToCode } from "./spec-to-code.ts";
import { checkTraceability } from "./traceability.ts";

const seed = Number(process.env.FX_IMAGE_ROUTE_SEED ?? "20261019");
const randomTraces = Number(process.env.FX_IMAGE_ROUTE_TRACES ?? "300");
const out = outDir("image-route");
const report: Record<string, unknown> = { started: new Date().toISOString(), seed, randomTraces, out };
const failures: string[] = [];
const started = performance.now();
const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;

function stage(name: string, ok: boolean, summary: string) {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  if (!ok) failures.push(name);
}

try {
  const toolchain = pinnedToolchain();
  report.toolchain = toolchain;
  stage("toolchain", true, `tla2tools.jar sha256 ${toolchain.jarSha256.slice(0, 12)}, ${toolchain.javaVersion}`);

  let at = performance.now();
  const model = await checkTlc(join(out, "model"), "ImageRoute", "MCImageRoute.cfg", specFiles(), ["-dump", "dot,actionlabels", join(out, "model", "graph")]);
  report.model = { verdict: model.verdict, property: model.property, distinctStates: model.distinctStates, depth: model.depth, durationMs: model.durationMs, tlcVersion: model.tlcVersion, generated: Number(/^(\d+) states generated, \d+ distinct states found/m.exec(model.output)?.[1] ?? NaN) };
  const versionOk = model.tlcVersion === PINNED_TLC_VERSION;
  stage("model check", model.verdict === "pass" && versionOk,
    `${model.verdict}${model.property ? ` (${model.property})` : ""}, ${model.distinctStates} distinct of ${(report.model as { generated: number }).generated} generated states, depth ${model.depth}, ${model.durationMs} ms, ${model.tlcVersion}`);
  const graphPath = join(out, "model", "graph.dot");

  at = performance.now();
  const bin = buildHarness(join(out, "harness"));
  stage("harness", true, `built from src/core/images/image_route.zig in ${elapsed(at)}`);

  at = performance.now();
  const sweep = await specToCode(bin, graphPath);
  report.specToCode = sweep;
  stage("spec to code", sweep.failure === null,
    sweep.failure
      ? `the core left the model after ${sweep.failure.path.join(" > ")}: expected ${sweep.failure.expected}, shown ${sweep.failure.shown}`
      : `${sweep.edges} of ${sweep.edges} edges over ${sweep.states} states, ${sweep.steps} steps, ${elapsed(at)}`);

  at = performance.now();
  const traces = await codeToSpec({ bin, dir: join(out, "code-to-spec"), seed, randomTraces, maxLength: 30 });
  report.codeToSpec = { traces: traces.traces, steps: traces.steps, tracesPath: traces.tracesPath, verdict: traces.tlc.verdict, property: traces.tlc.property, distinctStates: traces.tlc.distinctStates, durationMs: traces.tlc.durationMs };
  stage("code to spec", traces.tlc.verdict === "pass",
    `${traces.traces} traces, ${traces.steps} steps, TLC ${traces.tlc.verdict}${traces.tlc.property ? ` (${traces.tlc.property})` : ""}, ${traces.tlc.distinctStates} distinct states, ${elapsed(at)}`);

  at = performance.now();
  const specBugs = await specMutations(join(out, "spec-mutations"));
  report.specMutations = specBugs;
  for (const bug of specBugs) console.log(`  ${bug.caught ? "caught" : "MISSED"} ${bug.id} by ${bug.expect}: alone ${bug.detail.alone}, full ${bug.detail.full}`);
  stage("spec mutations", specBugs.every((bug) => bug.caught), `${specBugs.filter((bug) => bug.caught).length} of ${specBugs.length} caught, ${elapsed(at)}`);

  at = performance.now();
  const codeBugs = await codeMutations(join(out, "code-mutations"), graphPath, seed, Math.min(randomTraces, 150));
  report.codeMutations = codeBugs;
  for (const bug of codeBugs) console.log(`  ${bug.caught ? "caught" : "MISSED"} ${bug.id} by ${bug.expect}: alone ${bug.detail.alone}, full ${bug.detail.full}; spec to code ${bug.detail.specToCode}`);
  stage("code mutations", codeBugs.every((bug) => bug.caught), `${codeBugs.filter((bug) => bug.caught).length} of ${codeBugs.length} caught, ${elapsed(at)}`);

  const trace = checkTraceability();
  report.traceability = trace;
  for (const problem of trace.problems) console.log(`  ${problem}`);
  // The check itself must reject a design that drops a rule, names a check
  // that does not exist, or leaves a question unanswered.
  const design = readFileSync(join(MODEL_DIR, "design", "DESIGN.md"), "utf8");
  const broken = [
    ["a missing rule row", design.replace(/^\| R5 \|.*\n/m, "")],
    ["an invariant that does not exist", design.replace("`inv:OneSnapshot`, `trace:OneSnapshot`", "`inv:OneSnapshots`, `trace:OneSnapshot`")],
    ["an unanswered question", design.replace(/^- Q24:.*\n/m, "")],
  ] as const;
  const rejected = broken.filter(([, text]) => {
    const path = join(out, "traceability", "DESIGN.md");
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
    return text !== design && checkTraceability(path).problems.length > 0;
  });
  report.traceabilitySelfCheck = rejected.map(([name]) => name);
  stage("traceability", trace.problems.length === 0 && rejected.length === broken.length,
    `${trace.questions} questions, ${trace.rules} rules, ${trace.laws} laws, ${trace.entries} enforcement entries, ${trace.problems.length} problems; rejects ${rejected.length} of ${broken.length} broken designs`);
} catch (error) {
  failures.push("verify");
  console.error(`FAIL verify: ${(error as Error).message}`);
  report.error = (error as Error).stack;
}

report.failures = failures;
report.durationMs = Math.round(performance.now() - started);
writeJson(join(out, "report.json"), report);
console.log(`${failures.length === 0 ? "verify passed" : `verify failed: ${failures.join(", ")}`} in ${elapsed(started)}; report ${join(out, "report.json")}`);
process.exitCode = failures.length === 0 ? 0 : 1;
