const { workspace, window } = require('vscode');
const path = require('path');
const os = require('os');
const fs = require('fs');

let client;
let outputChannel;

function activate(context) {
    outputChannel = window.createOutputChannel('GAS Assembly LSP');
    context.subscriptions.push(outputChannel);

    const bin = process.env.GASLSP_BIN
        || path.join(os.homedir(), '.local', 'bin', 'gaslsp');

    log(`binary path: ${bin}`);
    log(`binary exists: ${fs.existsSync(bin)}`);

    if (!fs.existsSync(bin)) {
        window.showErrorMessage(`gaslsp: binary not found at ${bin}`);
        return;
    }

    let LanguageClient, TransportKind;
    try {
        ({ LanguageClient, TransportKind } = require('vscode-languageclient/node'));
    } catch (e) {
        log(`failed to load vscode-languageclient: ${e.message}`);
        window.showErrorMessage('gaslsp: run npm install');
        return;
    }

    const serverOptions = {
        command: bin,
        transport: TransportKind.stdio,
        options: { env: process.env }
    };

    const clientOptions = {
        documentSelector: [
            { scheme: 'file', language: '{asm,gas}' },
            { scheme: 'file', pattern: '**/*.{s,S,asm}' },
        ],
        synchronize: {
            fileEvents: workspace.createFileSystemWatcher('**/*.{s,S,asm}')
        },
        outputChannel: outputChannel,
    };

    try {
        client = new LanguageClient('gaslsp', 'GAS Assembly LSP', serverOptions, clientOptions);
        const disposable = client.start();
        context.subscriptions.push(disposable);
        log('client started');
    } catch (e) {
        log(`error: ${e.message}`);
        window.showErrorMessage(`gaslsp error: ${e.message}`);
    }
}

function log(msg) {
    const ts = new Date().toISOString().split('T')[1].slice(0, -1);
    outputChannel.appendLine(`[${ts}] ${msg}`);
}

function deactivate() {
    if (client) return client.stop();
}

module.exports = { activate, deactivate };
