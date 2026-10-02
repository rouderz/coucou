// How risky a permission request is, in a few words (#21 on macOS).
// Port of ApprovalRiskClassifier in Approvals.swift — same rules on every platform.

import { absolutePath, patchText, parsePatch } from "./codex.ts";

export type Risk = "low" | "medium" | "high";

export interface RiskVerdict {
  risk: Risk;
  reason: string;
}

const RANK: Record<Risk, number> = { low: 0, medium: 1, high: 2 };

export function riskAtMost(risk: Risk, limit: Risk): boolean {
  return RANK[risk] <= RANK[limit];
}

const HIGH: [RegExp, string][] = [
  [/\brm\s+(-[a-z]*[rf][a-z]*\s+)+/, "deletes files recursively"],
  [/\bsudo\b/, "runs as administrator"],
  [/\bgit\s+push\b.*(--force\b|-f\b|--force-with-lease)/, "force-pushes"],
  [/\bgit\s+reset\s+--hard\b/, "discards changes"],
  [/\bgit\s+clean\s+-[a-z]*f/, "deletes untracked files"],
  [/\bgit\s+(branch\s+-d\b|checkout\s+--\s|restore\s)/, "discards work"],
  [/(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b/, "runs a downloaded script"],
  [/\b(iwr|invoke-webrequest|irm|invoke-restmethod)\b[^|]*\|\s*(iex|invoke-expression)\b/, "runs a downloaded script"],
  [/\bchmod\s+(-r\s+)?777\b/, "opens permissions to everyone"],
  [/\b(mkfs|diskutil\s+erase|dd\s+if=|format\s+[a-z]:)/, "writes a disk"],
  [/>\s*\/dev\/(disk|sd)/, "writes a disk"],
  [/\b(drop\s+(table|database)|truncate\s+table)\b/, "deletes data"],
  [/\b(kubectl\s+delete|terraform\s+(destroy|apply)|docker\s+system\s+prune)\b/, "changes infrastructure"],
  [/\b(npm|yarn|pnpm)\s+publish\b|\bgh\s+release\s+create\b/, "publishes"],
  [/\b(killall|pkill|kill\s+-9|taskkill)\b/, "kills processes"],
  [/\bfind\b.*\s-(delete|exec\s+rm)\b/, "deletes files"],
  [/\bremove-item\b.*-recurse|\brd\s+\/s|\brmdir\s+\/s|\bdel\s+\/[sq]/, "deletes files recursively"],
];

const MEDIUM: [RegExp, string][] = [
  [/\b(npm|yarn|pnpm|bun)\s+(i|install|add|remove|uninstall)\b|\b(pip3?|brew|gem|cargo|winget|choco|scoop|apt|apt-get|dnf)\s+(install|uninstall|remove)\b/, "installs packages"],
  [/\bgit\s+(push|commit|merge|rebase|checkout|switch|tag|stash)\b/, "changes the repository"],
  [/\b(rm|mv|cp|mkdir|touch|ln|chmod|chown|del|copy|move|ren|remove-item|copy-item|move-item|new-item)\b/, "changes files"],
  [/(^|[^>2&])>{1,2}\s*[^&\s]/, "writes a file"],
  [/\b(curl|wget|ssh|scp|rsync|nc|iwr|invoke-webrequest)\b/, "uses the network"],
  [/\b(docker|kubectl|terraform|gh|aws|gcloud|vercel|az)\b/, "talks to a service"],
];

const READ_ONLY = new Set([
  "ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "pwd", "echo", "which", "file", "stat", "du",
  "df", "tree", "diff", "sort", "uniq", "jq", "env", "date", "whoami", "uname", "ps", "top", "sed", "awk",
  "dir", "type", "where", "get-childitem", "get-content", "select-string", "get-location",
]);

export function classifyCommand(command: string): RiskVerdict {
  const cmd = command.toLowerCase();
  for (const [re, why] of HIGH) if (re.test(cmd)) return { risk: "high", reason: why };
  if (/\bsed\s+-i/.test(cmd)) return { risk: "medium", reason: "edits files" };
  for (const [re, why] of MEDIUM) if (re.test(cmd)) return { risk: "medium", reason: why };
  if (/^\s*git\s+(status|diff|log|show|branch|remote|blame)\b/.test(cmd)) {
    return { risk: "low", reason: "reads the repository" };
  }
  const first = cmd.split(/[ ;|&\n]/).find((p) => p.length > 0) ?? "";
  if (READ_ONLY.has(first)) return { risk: "low", reason: "read only" };
  if (/\b(npm|yarn|pnpm|bun)\s+(run\s+)?(test|lint|build|typecheck|check)\b|\b(swift|cargo|go)\s+(build|test)\b|\bxcodebuild\b|\bdotnet\s+(build|test)\b/.test(cmd)) {
    return { risk: "low", reason: "builds or tests" };
  }
  return { risk: "medium", reason: "runs a command" };
}

const SENSITIVE = [".env", ".ssh/", ".aws/", ".gnupg/", "id_rsa", ".netrc", ".npmrc", ".zshrc", ".bashrc",
  "/etc/", "/usr/", "/System/", "/Library/", "Keychains", "\\Windows\\", "\\Program Files", "AppData\\Roaming\\Microsoft"];

function normalize(p: string): string {
  return p.replace(/\\/g, "/").toLowerCase();
}

export function classifyWrite(path: string, cwd: string, home = ""): RiskVerdict {
  if (SENSITIVE.some((s) => path.includes(s) || normalize(path).includes(normalize(s)))) {
    return { risk: "high", reason: "sensitive file" };
  }
  const p = normalize(path);
  const root = normalize(cwd).replace(/\/+$/, "");
  const absolute = p.startsWith("/") || /^[a-z]:\//.test(p);
  if (root && p && absolute && !p.startsWith(root + "/")) {
    const h = normalize(home).replace(/\/+$/, "");
    return { risk: "high", reason: h && p.startsWith(h + "/") ? "outside the project" : "outside your home folder" };
  }
  return { risk: "medium", reason: "changes a file" };
}

export function classify(tool: string, input: Record<string, unknown>, cwd: string, home = ""): RiskVerdict {
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : "");
  switch (tool) {
    case "Read": case "Grep": case "Glob": case "LS": case "WebSearch": case "WebFetch": case "TodoWrite":
      return { risk: "low", reason: "read only" };
    case "Edit": case "MultiEdit": case "Write": case "NotebookEdit":
      return classifyWrite(str("file_path") || str("notebook_path"), cwd, home);
    case "Bash": case "PowerShell": case "shell": {
      const c = input.command;
      return classifyCommand(Array.isArray(c) ? c.join(" ") : str("command"));
    }
    case "apply_patch": {
      const patch = patchText(input);
      if (!patch) return { risk: "medium", reason: "changes a file" };
      const checks = parsePatch(patch).map((c) => classifyWrite(absolutePath(c.path, cwd), cwd, home));
      return checks.sort((a, b) => RANK[b.risk] - RANK[a.risk])[0] ?? { risk: "medium", reason: "changes a file" };
    }
    default:
      if (tool.startsWith("mcp__")) return { risk: "medium", reason: "external tool" };
      return { risk: "medium", reason: "unknown tool" };
  }
}
