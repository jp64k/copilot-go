# copilot-go

Use your [OpenCode Go](https://opencode.ai/docs/go/) subscription in **VS 2026** GitHub Copilot.  
A zero-dependency PowerShell proxy that runs locally. Copilot thinks it's talking to Ollama. It's actually talking to opencode.ai.

## Quick Start

1. [Download](https://github.com/jp64k/copilot-go/archive/refs/heads/main.zip) and extract
2. Double-click `run.bat`
3. Paste your OpenCode Go API key when prompted
4. In VS 2026: **Copilot → Provider: Ollama → Endpoint: `http://localhost:11435`**

## Why?

Ollama Cloud and OpenCode Go serve similar open models — DeepSeek, GLM, Kimi, etc.  
But opencode.ai's infrastructure is consistently faster, while also being half the price ($10/mo vs. $20/mo), with generous usage limits. 
This proxy lets you use your OpenCode Go subscription directly in VS 2026's Copilot.

## What You Get

- **15 models** with thinking level variants for supported models
- **SSE streaming** and native tool calling — code search, file search, symbol lookup
- **Zero dependencies** — runs on PowerShell, built into every Windows 10/11 machine
- **Self-updating** — checks GitHub for new commits on startup, y/n prompt to update
- **Token speed** displayed in window title after each response

## Models

| Model | Context | Thinking |
|---|---|---|
| DeepSeek V4 Pro | 1M | auto · Low · Mid · High · Max |
| DeepSeek V4 Flash | 1M | auto · Low · Mid · High · Max |
| GLM 5.1 | 198K | auto |
| GLM 5 | 198K | auto |
| Kimi K2.6 | 256K | auto |
| Kimi K2.5 | 256K | auto |
| MiniMax M2.7 | 192K | auto |
| MiniMax M2.5 | 192K | auto |
| MiMo V2.5 Pro | 256K | auto · Low · Mid · High |
| MiMo V2.5 | 256K | auto · Low · Mid · High |
| Qwen 3.6 Plus | 128K | auto |
| Qwen 3.5 Plus | 128K | auto |

## FAQ
**Do I need a GitHub Copilot or Ollama subscription?**  
No — this replaces Ollama Cloud entirely. You only need an OpenCode Go subscription. No separate Ollama account, no extra Copilot plan.

**Do I need Ollama installed?** 
No — this replaces it.  

**Does this work with VS Code?**  
No — this doesn't work in VS Code yet. It wasn't a priority since there are already enough VS Code alternatives.

**Is my API key safe?**  
The key is stored locally in `.opencode_go_key` (git-ignored) and never leaves your machine except to authenticate with opencode.ai.

## Optional Arguments

```powershell
.\proxy.ps1                # start normally
.\proxy.ps1 -Update        # self-update from GitHub
.\proxy.ps1 -Log           # enable request logging (for troubleshooting)
.\proxy.ps1 -Port 11436    # custom port
```

## Optional Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OPENCODE_GO_API_KEY` | — | API key (instead of `.opencode_go_key`) |
| `PORT` | `11435` | Proxy listen port |

## License

[GPL 3.0](LICENSE)
