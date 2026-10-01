// Coucou editor extension: sends the active editor's context to Coucou over its local Unix
// socket (~/Library/Application Support/NotchBuddy/nb.sock). Nothing leaves the Mac.
//
//   EditorContext  on editor / selection / diagnostics changes (debounced) — Coucou keeps the
//                  latest one and uses it when you press ⌃⌥M or drop Mochi on the window.
//   EditorAsk      "Ask Mochi about this" — Coucou opens its chat with this context attached.
'use strict';
const vscode = require('vscode');
const net = require('net');
const os = require('os');
const path = require('path');

const SOCKET = path.join(os.homedir(), 'Library', 'Application Support', 'NotchBuddy', 'nb.sock');
const MAX_SELECTION = 8000;
let timer = null;
let statusItem = null;

function send(event, payload) {
  return new Promise((resolve) => {
    const client = net.createConnection({ path: SOCKET });
    client.setTimeout(1500);
    client.on('connect', () => {
      client.end(JSON.stringify({ hook_event_name: event, ...payload }) + '\n');
      resolve(true);
    });
    client.on('error', () => resolve(false));   // Coucou isn't running: nothing to do
    client.on('timeout', () => { client.destroy(); resolve(false); });
  });
}

function severityName(s) {
  switch (s) {
    case vscode.DiagnosticSeverity.Error: return 'error';
    case vscode.DiagnosticSeverity.Warning: return 'warning';
    case vscode.DiagnosticSeverity.Information: return 'info';
    default: return 'hint';
  }
}

function currentContext() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.uri.scheme !== 'file') return null;
  const doc = editor.document;
  const sel = editor.selection;
  let selection = sel && !sel.isEmpty ? doc.getText(sel) : '';
  if (selection.length > MAX_SELECTION) selection = selection.slice(0, MAX_SELECTION);
  const folder = vscode.workspace.getWorkspaceFolder(doc.uri);
  const diagnostics = vscode.languages.getDiagnostics(doc.uri)
    .filter((d) => d.severity <= vscode.DiagnosticSeverity.Warning)
    .slice(0, 20)
    .map((d) => ({
      line: d.range.start.line + 1,
      severity: severityName(d.severity),
      message: String(d.message).split('\n')[0].slice(0, 300),
      source: d.source || undefined,
    }));
  return {
    appName: vscode.env.appName,
    file: doc.uri.fsPath,
    workspace: folder ? folder.uri.fsPath : undefined,
    language: doc.languageId,
    line: sel ? sel.active.line + 1 : undefined,
    selection,
    diagnostics,
  };
}

function schedule() {
  if (!vscode.workspace.getConfiguration('coucou').get('shareContext', true)) return;
  clearTimeout(timer);
  timer = setTimeout(() => {
    const ctx = currentContext();
    if (ctx) send('EditorContext', ctx);
  }, 400);
}

async function ask() {
  const ctx = currentContext();
  if (!ctx) {
    vscode.window.showInformationMessage('Coucou: open a file first.');
    return;
  }
  const ok = await send('EditorAsk', ctx);
  if (!ok) vscode.window.showWarningMessage('Coucou isn\'t running. Open Coucou and try again.');
}

function updateStatusBar() {
  const show = vscode.workspace.getConfiguration('coucou').get('showStatusBar', true);
  if (show) statusItem.show(); else statusItem.hide();
}

function activate(context) {
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusItem.text = '$(comment-discussion) Mochi';
  statusItem.tooltip = 'Ask Mochi about this file (⌃⌥M)';
  statusItem.command = 'coucou.ask';
  updateStatusBar();

  context.subscriptions.push(
    statusItem,
    vscode.commands.registerCommand('coucou.ask', ask),
    vscode.window.onDidChangeActiveTextEditor(schedule),
    vscode.window.onDidChangeTextEditorSelection(schedule),
    vscode.languages.onDidChangeDiagnostics(schedule),
    vscode.window.onDidChangeWindowState((s) => { if (s.focused) schedule(); }),
    vscode.workspace.onDidChangeConfiguration((e) => { if (e.affectsConfiguration('coucou')) updateStatusBar(); }),
  );
  schedule();
}

function deactivate() { clearTimeout(timer); }

module.exports = { activate, deactivate };
