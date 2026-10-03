// GitHub pull requests (#113, step 1): the read-only list, plus the pure rules the
// later steps (review, merge, delete) will use. Nothing here talks to GitHub or
// writes anything: the caller runs `gh` and passes the parsed JSON in.

export type CiState = "success" | "failure" | "pending" | "none";
export type ReviewState = "approved" | "changes" | "review" | "none";

export interface PrItem {
  repo: string; // owner/name
  number: number;
  title: string;
  url: string;
  author: string;
  draft: boolean;
  updatedAt: string;
}

export interface PrRow extends PrItem {
  ci: CiState;
  review: ReviewState;
}

export interface PrLists {
  toReview: PrRow[];
  mine: PrRow[];
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string => (typeof v === "string" ? v : "");

/** Parses `gh search prs --json number,title,url,repository,author,isDraft,updatedAt`
 *  or the REST search (`gh api search/issues?q=is:pr ...`, items[] or the bare array).
 *  Entries without a number or repo are skipped. */
export function parsePrSearch(json: unknown): PrItem[] {
  const list = Array.isArray(json) ? json : Array.isArray(obj(json).items) ? (obj(json).items as unknown[]) : [];
  const out: PrItem[] = [];
  for (const raw of list) {
    const o = obj(raw);
    const number = typeof o.number === "number" ? o.number : 0;
    let repo = str(obj(o.repository).nameWithOwner) || str(obj(o.repository).full_name);
    if (!repo) {
      const m = /repos\/([^/]+\/[^/]+)$/.exec(str(o.repository_url));
      if (m) repo = m[1];
    }
    if (!number || !repo) continue;
    const url = str(o.url).includes("/pull/") ? str(o.url) : str(o.html_url) || str(o.url);
    out.push({
      repo, number, url,
      title: str(o.title),
      author: str(obj(o.author).login) || str(obj(o.user).login),
      draft: o.isDraft === true || o.draft === true,
      updatedAt: str(o.updatedAt) || str(o.updated_at),
    });
  }
  return out;
}

/** CI from `GET /repos/{o}/{r}/commits/{sha}/check-runs` and the combined
 *  `GET .../commits/{sha}/status`: any failure wins, then anything still running,
 *  then success. Neither source having anything means "none". */
export function ciState(checkRuns: unknown, combined: unknown): CiState {
  const runs = Array.isArray(obj(checkRuns).check_runs) ? (obj(checkRuns).check_runs as unknown[]).map(obj) : [];
  const statuses = Array.isArray(obj(combined).statuses) ? (obj(combined).statuses as unknown[]).map(obj) : [];
  if (!runs.length && !statuses.length) return "none";
  const bad = new Set(["failure", "timed_out", "cancelled", "action_required", "startup_failure"]);
  const good = new Set(["success", "neutral", "skipped"]);
  let pending = false;
  for (const r of runs) {
    if (r.status !== "completed") { pending = true; continue; }
    const c = str(r.conclusion);
    if (bad.has(c)) return "failure";
    if (!good.has(c)) pending = true;
  }
  for (const s of statuses) {
    const st = str(s.state);
    if (st === "failure" || st === "error") return "failure";
    if (st !== "success") pending = true;
  }
  return pending ? "pending" : "success";
}

export const CI_SYMBOL: Record<CiState, string> = { success: "✓", failure: "✗", pending: "●", none: "" };

/** Review state from `GET /repos/{o}/{r}/pulls/{n}/reviews`: each reviewer's latest
 *  APPROVED / CHANGES_REQUESTED / DISMISSED counts (plain comments and pending drafts
 *  don't change it). Any outstanding "changes requested" wins over approvals.
 *  With no decisive review: "review" when a review was requested, else "none". */
export function reviewState(reviews: unknown, reviewRequested = false): ReviewState {
  const latest = new Map<string, string>();
  for (const r of Array.isArray(reviews) ? reviews : []) {
    const o = obj(r);
    const state = str(o.state).toUpperCase();
    const who = str(obj(o.user).login);
    if (!who || !["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].includes(state)) continue;
    latest.set(who, state);
  }
  const states = [...latest.values()];
  if (states.includes("CHANGES_REQUESTED")) return "changes";
  if (states.includes("APPROVED")) return "approved";
  return reviewRequested ? "review" : "none";
}

export const REVIEW_LABEL: Record<ReviewState, string> = {
  approved: "Approved", changes: "Changes requested", review: "Review required", none: "",
};

/** Joins the two searches with the per-PR details. `details` is keyed "owner/name#n";
 *  PRs without details show no CI or review state. "To review" hides drafts (nobody
 *  asked yet) and your own PRs; "Mine" keeps drafts (marked as such). Newest first. */
export function buildLists(
  requested: PrItem[], mine: PrItem[],
  details: Record<string, { ci?: CiState; review?: ReviewState }> = {},
): PrLists {
  const row = (p: PrItem): PrRow => {
    const d = details[`${p.repo}#${p.number}`] ?? {};
    return { ...p, ci: d.ci ?? "none", review: d.review ?? "none" };
  };
  const byRecent = (a: PrRow, b: PrRow) => b.updatedAt.localeCompare(a.updatedAt);
  const mineKeys = new Set(mine.map((p) => `${p.repo}#${p.number}`));
  return {
    toReview: requested.filter((p) => !p.draft && !mineKeys.has(`${p.repo}#${p.number}`)).map(row).sort(byRecent),
    mine: mine.map(row).sort(byRecent),
  };
}

/** The `gh` calls the list needs, so macOS and Windows/Linux ask for the same things. */
export const GH_REQUESTED_ARGS = [
  "search", "prs", "--review-requested=@me", "--state=open", "--limit", "30",
  "--json", "number,title,url,repository,author,isDraft,updatedAt",
];
export const GH_MINE_ARGS = [
  "search", "prs", "--author=@me", "--state=open", "--limit", "30",
  "--json", "number,title,url,repository,author,isDraft,updatedAt",
];

// ---- scopes ---------------------------------------------------------------

/** Scopes from `gh auth status` ("- Token scopes: 'delete_repo', 'repo'") or an
 *  `X-OAuth-Scopes: repo, read:org` header value. Fine-grained tokens have none. */
export function parseScopes(text: string): string[] {
  const line = /(?:Token scopes|X-OAuth-Scopes)[ \t]*:[ \t]*(.*)/i.exec(text);
  if (!line) return [];
  return line[1].split(/[,\s]+/).map((s) => s.replace(/['"`]/g, "").trim()).filter((s) => s && s !== "none");
}

const IMPLIES: Record<string, string[]> = {
  repo: ["public_repo", "repo:status", "repo_deployment", "repo:invite", "security_events"],
  "admin:org": ["write:org", "read:org"],
  "write:org": ["read:org"],
};

export function hasScope(granted: string[], needed: string): boolean {
  return granted.includes(needed) || granted.some((g) => IMPLIES[g]?.includes(needed));
}

export function missingScopes(granted: string[], needed: string[]): string[] {
  return needed.filter((n) => !hasScope(granted, n));
}

/** The exact command to show when a scope is missing (never ask for more up front). */
export function scopeHint(missing: string[]): string {
  return missing.length ? `gh auth refresh -s ${missing.join(",")}` : "";
}

// ---- merge ------------------------------------------------------------------

export type MergeMethod = "merge" | "squash" | "rebase";

/** Methods the repo allows (`allow_merge_commit`, `allow_squash_merge`, `allow_rebase_merge`
 *  from `GET /repos/{o}/{r}`), in the order the UI lists them. A payload with none of the
 *  flags (e.g. no admin view) is treated as merge-commit only. */
export function allowedMergeMethods(repo: unknown): MergeMethod[] {
  const r = obj(repo);
  const hasFlags = ["allow_merge_commit", "allow_squash_merge", "allow_rebase_merge"].some((k) => k in r);
  if (!hasFlags) return ["merge"];
  const out: MergeMethod[] = [];
  if (r.allow_merge_commit === true) out.push("merge");
  if (r.allow_squash_merge === true) out.push("squash");
  if (r.allow_rebase_merge === true) out.push("rebase");
  return out;
}

/** The method to preselect: the one asked for if allowed, else the first allowed. Never
 *  a method the repo forbids; null when none is allowed. */
export function defaultMergeMethod(allowed: MergeMethod[], preferred?: MergeMethod): MergeMethod | null {
  if (preferred && allowed.includes(preferred)) return preferred;
  return allowed[0] ?? null;
}

/** Why Merge is disabled (null when it can be clicked). The click itself is still required. */
export function mergeBlocker(pr: { draft: boolean; ci: CiState; review: ReviewState }, allowed: MergeMethod[]): string | null {
  if (!allowed.length) return "No merge method is allowed on this repository";
  if (pr.draft) return "Draft pull request";
  if (pr.ci === "failure") return "Checks are failing";
  if (pr.ci === "pending") return "Checks are still running";
  if (pr.review === "changes") return "Changes were requested";
  return null;
}

// ---- delete -----------------------------------------------------------------

/** GitHub's rule: the full `owner/name`, exactly (case and all). Only stray
 *  surrounding whitespace from a paste is forgiven. */
export function deleteConfirmed(typed: string, owner: string, name: string): boolean {
  return typed.trim() === `${owner}/${name}`;
}

// ---- review payload ----------------------------------------------------------

export type ReviewEvent = "APPROVE" | "REQUEST_CHANGES" | "COMMENT";

export interface ReviewRequest {
  method: "POST";
  path: string;
  body: { event: ReviewEvent; body?: string };
}

/** The request for `POST /repos/{o}/{r}/pulls/{n}/reviews`. Requesting changes or commenting
 *  needs text (GitHub answers 422 otherwise); approving may have none. Returns an error
 *  string instead of a request when it can't be built. The caller shows `path` + `body`
 *  to the user and sends only on an explicit click. */
export function buildReviewRequest(
  repo: string, number: number, event: ReviewEvent, text: string,
): ReviewRequest | { error: string } {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) return { error: "Repository must look like owner/name" };
  if (!Number.isInteger(number) || number <= 0) return { error: "Invalid pull request number" };
  const body = text.trim();
  if (event !== "APPROVE" && !body) return { error: "Write a comment first" };
  return {
    method: "POST",
    path: `repos/${repo}/pulls/${number}/reviews`,
    body: body ? { event, body } : { event },
  };
}
