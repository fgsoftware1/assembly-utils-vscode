const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

/**
 * Read tokenColors from bundled theme and merge into user's token customizations.
 */
function activate(context) {
  const cmd = vscode.commands.registerCommand('assembly-utils.applySyntaxColors', async () => {
    const themePath = context.extensionPath && path.join(context.extensionPath, 'themes', 'assembly-colours.json')
      || path.join(__dirname, 'themes', 'assembly-colours.json');

    let content;
    try {
      content = JSON.parse(fs.readFileSync(themePath, 'utf8'));
    } catch (err) {
      vscode.window.showErrorMessage('Failed to read assembly theme token colors: ' + err.message);
      return;
    }

    const tokenColors = content.tokenColors || content.settings || [];

    const config = vscode.workspace.getConfiguration();
    const current = config.get('editor.tokenColorCustomizations') || {};
    const existingRules = current.textMateRules || [];

    // Filter out existing rules that target our scopes to avoid duplicates
    const scopesSet = new Set();
    tokenColors.forEach(tc => {
      if (tc.scope) {
        if (Array.isArray(tc.scope)) tc.scope.forEach(s => scopesSet.add(s));
        else scopesSet.add(tc.scope);
      }
    });

    const filtered = existingRules.filter(r => {
      const sc = r.scope;
      if (!sc) return true;
      if (Array.isArray(sc)) return sc.every(s => !scopesSet.has(s));
      return !scopesSet.has(sc);
    });

    const merged = filtered.concat(tokenColors.map(tc => ({
      scope: tc.scope,
      settings: tc.settings
    })));

    const newVal = Object.assign({}, current, { textMateRules: merged });

    try {
      await config.update('editor.tokenColorCustomizations', newVal, vscode.ConfigurationTarget.Global);
      vscode.window.showInformationMessage('Assembly syntax colors applied to Settings > Text Mate Rules.');
    } catch (err) {
      vscode.window.showErrorMessage('Failed to update settings: ' + err.message);
    }
  });

  context.subscriptions.push(cmd);
}

function deactivate() {}

module.exports = { activate, deactivate };
