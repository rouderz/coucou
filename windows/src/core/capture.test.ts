import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseCapture, parseDue, buildChip, buildIssueCreateVariables, parseIssueCreate, parseTeams,
  reduce, initialCapture, branchToCopy, slug, describeSource, draftFromAnswer, type CaptureState, type CaptureContext, type CaptureEvent, type TeamInfo,
} from "./capture.ts";

const SAT = new Date(2026, 9, 3, 15, 0); // Saturday 3 Oct 2026
const teams: TeamInfo[] = [{ id: "t-sho", key: "SHO", name: "Shop" }, { id: "t-eng", key: "ENG", name: "Engineering" }];
const ctx: CaptureContext = { teams, defaultTeamKey: "ENG", now: SAT };

test("parser: the example from the issue", () => {
  assert.deepEqual(parseCapture("Fix the cart total rounding #SHO p2 @me", SAT), {
    title: "Fix the cart total rounding", teamKey: "SHO", priority: 2, assignToMe: true, dueDate: null,
  });
});

test("parser: tokens anywhere, case-insensitive, extra spaces", () => {
  const p = parseCapture("  #sho   P1 fix  @ME the thing !tomorrow ", SAT);
  assert.equal(p.title, "fix the thing");
  assert.equal(p.teamKey, "SHO");
  assert.equal(p.priority, 1);
  assert.equal(p.assignToMe, true);
  assert.equal(p.dueDate, "2026-10-04");
});

test("parser: lookalikes stay in the title", () => {
  const p = parseCapture("Handle issue #123 and p5 and p12 and @mex !someday email@me.com", SAT);
  assert.equal(p.title, "Handle issue #123 and p5 and p12 and @mex !someday email@me.com");
  assert.equal(p.teamKey, null);
  assert.equal(p.priority, 0);
  assert.equal(p.assignToMe, false);
  assert.equal(p.dueDate, null);
});

test("parser: last token of a kind wins; empty line", () => {
  const p = parseCapture("a p4 b p1 #ENG #SHO", SAT);
  assert.equal(p.priority, 1);
  assert.equal(p.teamKey, "SHO");
  assert.equal(parseCapture("   ", SAT).title, "");
});

test("due dates: today, weekdays are always in the future, ISO dates", () => {
  assert.equal(parseDue("today", SAT), "2026-10-03");
  assert.equal(parseDue("fri", SAT), "2026-10-09");
  assert.equal(parseDue("Friday", SAT), "2026-10-09");
  assert.equal(parseDue("sat", SAT), "2026-10-10", "same weekday means next week");
  assert.equal(parseDue("sun", SAT), "2026-10-04");
  assert.equal(parseDue("mon", new Date(2026, 11, 31)), "2027-01-04", "crosses the year");
  assert.equal(parseDue("2026-02-30", SAT), null);
  assert.equal(parseDue("2026-11-15", SAT), "2026-11-15");
  assert.equal(parseDue("later", SAT), null);
});

test("chip: team from #KEY, then the default, then the only team", () => {
  assert.equal(buildChip(parseCapture("x #sho", SAT), teams, "ENG").team?.id, "t-sho");
  assert.equal(buildChip(parseCapture("x", SAT), teams, "eng").team?.id, "t-eng");
  assert.equal(buildChip(parseCapture("x", SAT), [teams[0]], null).team?.id, "t-sho");
  const none = buildChip(parseCapture("x", SAT), teams, null);
  assert.deepEqual(none.problems, ["no-team"]);
  assert.equal(none.ready, false);
});

test("chip: problems block readiness", () => {
  assert.deepEqual(buildChip(parseCapture("x #zzz", SAT), teams, null).problems, ["unknown-team"]);
  assert.deepEqual(buildChip(parseCapture("#sho p1", SAT), teams, null).problems, ["empty-title"]);
  assert.deepEqual(buildChip(parseCapture("x", SAT), [], null).problems, ["no-teams-loaded"]);
  const ok = buildChip(parseCapture("Fix it p3 @me", SAT), teams, "SHO");
  assert.equal(ok.ready, true);
  assert.equal(ok.priorityLabel, "Medium");
  assert.equal(ok.assignee, "Me");
});

test("issueCreate variables: only what was typed", () => {
  const chip = buildChip(parseCapture("Fix it #SHO p2 @me !today", SAT), teams, null);
  assert.deepEqual(buildIssueCreateVariables(chip, "u-1"), {
    input: { teamId: "t-sho", title: "Fix it", priority: 2, assigneeId: "u-1", dueDate: "2026-10-03" },
  });
  const bare = buildChip(parseCapture("Fix it", SAT), teams, "ENG");
  assert.deepEqual(buildIssueCreateVariables(bare, null), { input: { teamId: "t-eng", title: "Fix it" } });
  assert.throws(() => buildIssueCreateVariables(chip, null), /who you are/);
  assert.throws(() => buildIssueCreateVariables(buildChip(parseCapture("", SAT), teams, "ENG"), null), /ready/);
});

test("responses: teams and issueCreate", () => {
  const t = parseTeams({ viewer: { id: "u-1" }, teams: { nodes: [{ id: "a", key: "SHO", name: "Shop" }, { id: 3 }, { id: "b", key: "ENG" }] } });
  assert.equal(t.viewerId, "u-1");
  assert.deepEqual(t.teams, [{ id: "a", key: "SHO", name: "Shop" }, { id: "b", key: "ENG", name: "ENG" }]);
  assert.deepEqual(parseTeams({}), { viewerId: null, teams: [] });
  const issue = parseIssueCreate({ issueCreate: { success: true, issue: { id: "i", identifier: "SHO-9", title: "T", url: "https://linear.app/x", branchName: "me/sho-9-t" } } });
  assert.equal(issue?.identifier, "SHO-9");
  assert.equal(branchToCopy(issue!), "me/sho-9-t");
  assert.equal(parseIssueCreate({ issueCreate: { success: false, issue: null } }), null);
  assert.equal(parseIssueCreate({}), null);
  assert.equal(branchToCopy({ id: "i", identifier: "SHO-9", title: "", url: "", branchName: null }), "sho-9");
});

test("flow: nothing is created before the second Enter", () => {
  let s: CaptureState = initialCapture;
  const effects: string[] = [];
  const send = (e: CaptureEvent) => {
    const r = reduce(s, e, ctx);
    s = r.state;
    if (r.effect) effects.push(r.effect.type);
  };
  send({ type: "enter" }); // empty line: nothing
  assert.equal(s.phase, "editing");
  send({ type: "type", line: "Fix cart #SHO p2" });
  assert.equal(s.phase, "editing");
  send({ type: "enter" }); // first Enter: preview only
  assert.equal(s.phase, "preview");
  assert.deepEqual(effects, []);
  send({ type: "type", line: "Fix cart #SHO p1" }); // editing during the preview un-confirms it
  assert.equal(s.phase, "editing");
  send({ type: "enter" });
  assert.deepEqual(effects, []);
  send({ type: "enter" }); // second Enter: create
  assert.equal(s.phase, "creating");
  assert.deepEqual(effects, ["create"]);
  send({ type: "enter" }); // no double send
  send({ type: "type", line: "other" });
  assert.deepEqual(effects, ["create"]);
  assert.equal(s.phase, "creating");
  send({ type: "created", issue: { id: "i", identifier: "SHO-1", title: "t", url: "u", branchName: null } });
  assert.equal(s.phase, "done");
  send({ type: "enter" });
  assert.deepEqual(effects, ["create", "close"]);
});

test("flow: a chip with problems can't be confirmed; Escape backs out; failure needs a new confirmation", () => {
  const noDefault: CaptureContext = { ...ctx, defaultTeamKey: null };
  let r = reduce({ phase: "editing", line: "Fix cart" }, { type: "enter" }, noDefault);
  assert.equal(r.state.phase, "preview");
  r = reduce(r.state, { type: "enter" }, noDefault);
  assert.equal(r.state.phase, "preview");
  assert.equal(r.effect, null);
  r = reduce(r.state, { type: "escape" }, noDefault);
  assert.equal(r.state.phase, "editing");
  assert.deepEqual(reduce(r.state, { type: "escape" }, noDefault).effect, { type: "close" });

  let s: CaptureState = { phase: "editing", line: "Fix cart #SHO" };
  s = reduce(s, { type: "enter" }, ctx).state;
  s = reduce(s, { type: "enter" }, ctx).state;
  s = reduce(s, { type: "failed", message: "Can't reach Linear" }, ctx).state;
  assert.equal(s.phase, "failed");
  r = reduce(s, { type: "enter" }, ctx);
  assert.equal(r.state.phase, "preview", "retry goes through the preview again");
  assert.equal(r.effect, null);
});

test("branch to copy: Linear's name, else identifier + slug of the title", () => {
  assert.equal(slug("Fix the cart total rounding!"), "fix-the-cart-total-rounding");
  assert.equal(slug("Arreglar el menú — ¿ya?"), "arreglar-el-menu-ya");
  assert.equal(slug("x".repeat(30) + " " + "y".repeat(30)), "x".repeat(30) + "-" + "y".repeat(19));
  assert.equal(slug("***"), "");
  const issue = { id: "i", identifier: "SHO-9", title: "Fix the cart", url: "", branchName: null };
  assert.equal(branchToCopy(issue), "sho-9-fix-the-cart");
  assert.equal(branchToCopy({ ...issue, branchName: "me/sho-9-fix" }), "me/sho-9-fix");
});

test("description: only sent when there is text", () => {
  const chip = buildChip(parseCapture("Fix it", SAT), teams, "ENG");
  assert.equal(buildIssueCreateVariables(chip, null, "  ").input.description, undefined);
  assert.equal(buildIssueCreateVariables(chip, null, " `a.ts:3` ").input.description, "`a.ts:3`");
});

test("context: the editor's file and selection, or a window", () => {
  assert.deepEqual(describeSource({ kind: "code", file: "/p/src/app.ts", line: 42, selection: " x = 1 " }),
    { label: "app.ts:42", text: "`/p/src/app.ts:42`\n\n```\nx = 1\n```" });
  assert.deepEqual(describeSource({ kind: "code", file: "C:\\p\\main.rs" }), { label: "main.rs", text: "`C:\\p\\main.rs`" });
  assert.equal(describeSource({ kind: "code", file: "" }), null);
  assert.deepEqual(describeSource({ kind: "window", app: "Safari", title: "Pricing", url: "https://x.dev" }),
    { label: "Safari — Pricing", text: "Safari: Pricing\n\nhttps://x.dev" });
  assert.deepEqual(describeSource({ kind: "window", app: "Finder", title: "" }), { label: "Finder", text: "Finder" });
  assert.equal(describeSource({ kind: "window", app: "", title: " " }), null);
  const long = describeSource({ kind: "code", file: "a.ts", selection: "y".repeat(5000) })!;
  assert.ok(long.text.length < 4100);
});

test("chat draft: first line as the title, the answer as the description", () => {
  assert.deepEqual(draftFromAnswer("\n## **Fix** the `cart` rounding\n\nUse cents."),
    { line: "Fix the cart rounding", description: "## **Fix** the `cart` rounding\n\nUse cents." });
  assert.equal(draftFromAnswer("- 1. Step one")?.line, "Step one");
  assert.equal(draftFromAnswer("   "), null);
  assert.equal(draftFromAnswer("a".repeat(200))!.line.length, 120);
  // The draft still goes through the same two Enters.
  const r = reduce({ phase: "editing", line: draftFromAnswer("Fix it #SHO")!.line }, { type: "enter" }, ctx);
  assert.equal(r.state.phase, "preview");
  assert.equal(r.effect, null);
});
