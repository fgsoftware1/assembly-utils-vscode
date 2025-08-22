an assembly utils extension for vscode based IDEs, it contains syntax highlighting and snippets.

This extension previously shipped a full VS Code theme. To avoid changing the user's entire theme, it now exposes a command that merges only the assembly syntax token colors into the user's `editor.tokenColorCustomizations.textMateRules` setting.

Use the command palette and run: "Assembly: Apply Syntax Colors" to install the syntax-only colors without switching your theme.