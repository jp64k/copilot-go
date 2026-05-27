# copilot-go

Copilot bridge for using [OpenCode Go](https://opencode.ai/docs/go/) models in Visual Studio 2026.  
A PowerShell proxy with no external dependencies that runs locally.  
Copilot sees Ollama, you see OpenCode.

## Quick Start

1. [Download](https://github.com/jp64k/copilot-go/archive/refs/heads/main.zip) and extract
2. Double-click `run.bat`
3. Paste your OpenCode Go API key when prompted
4. In VS 2026: **Copilot → Provider: Ollama → Endpoint: `http://localhost:11435`**

## Why?

Ollama Cloud and OpenCode Go serve similar open models: DeepSeek, GLM, Kimi, etc.  
But OpenCode's infrastructure is consistently faster, while also being half the price ($10/mo vs. $20/mo).  
This proxy lets you use your OpenCode Go subscription directly in VS 2026's Copilot.

## What You Get

- **16 models** with thinking level variants for supported models
- **SSE streaming** and native tool calling — code search, file search, symbol lookup
- **Zero dependencies** — runs on PowerShell, built into every Windows 10/11 machine
- **Self-updating** — checks GitHub for new commits on startup, y/n prompt to update
- **Real-time token speed** in window title
- **Custom harness** — auto-exports harness per-mode (agent/ask/plan) on first model run, edit to customize Copilot's system prompt
- **Multi-key rotation** — store multiple API keys (one per line) in `.opencode_go_key`, auto-switches on rate limit

## Demo

### Proxy

<img width="500" alt="Demo" src="https://github.com/user-attachments/assets/acafc6a2-5c88-4e27-848a-b50295eca3dc" />  

### Model Selector

<img width="500" alt="ModelSelection" src="https://github.com/user-attachments/assets/9dea953c-5545-4835-a989-33f2d9603000" />

### Chat Mode

<img width="500" alt="ChatMode" src="https://github.com/user-attachments/assets/a22ed780-71f9-4a16-b4b6-a4b5d80a242f" />

### Agent Mode

<img width="500" alt="AgentMode" src="https://github.com/user-attachments/assets/68cc0e19-119c-4818-af61-1ef3853690b6" />

## Models

| Model | Context | Thinking |
|---|---|---|
| DeepSeek V4 Pro | 1M | auto · Low · Mid · High · Max |
| DeepSeek V4 Flash | 1M | auto · Low · Mid · High · Max |
| GLM 5.1 | 203K | auto |
| GLM 5 | 203K | auto |
| Kimi K2.6 | 262K | auto |
| Kimi K2.5 | 262K | auto |
| MiniMax M2.7 | 205K | auto |
| MiniMax M2.5 | 205K | auto |
| MiMo V2.5 Pro | 1M | auto · Low · Mid · High |
| MiMo V2.5 | 1M | auto · Low · Mid · High |
| MiMo V2 Pro | 1M | auto |
| MiMo V2 Omni | 262K | auto |
| Qwen 3.7 Max | 1M | auto |
| Qwen 3.6 Plus | 1M | auto |
| Qwen 3.5 Plus | 1M | auto |
| HY3 Preview | 262K | auto |

## FAQ
**Do I need Ollama installed?**  
- No, this replaces it.  

**Do I need GitHub Copilot or Ollama subscriptions?**  
- No, this replaces Ollama Cloud entirely. You only need an [OpenCode Go](https://opencode.ai/docs/go/) subscription.  
- No separate Ollama account, no extra Copilot plan needed.

**Does this work with VS Code?**  
- No, this doesn't work in VS Code yet. It wasn't a priority since there are already enough VS Code alternatives.

**Is my API key safe?**  
- Yes, keys are stored locally in `.opencode_go_key` (git-ignored) and never leave your machine except to authenticate with opencode.ai.
- **Multiple keys**: add one per line to `.opencode_go_key`. If a request gets rate-limited (HTTP 429), the proxy automatically rotates to the next key and retries.

## Optional: Arguments

```powershell
.\proxy.ps1                # start normally
.\proxy.ps1 -Update        # self-update from GitHub
.\proxy.ps1 -Log           # enable request logging (for troubleshooting)
.\proxy.ps1 -Port 11436    # custom port
```

## Optional: Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OPENCODE_GO_API_KEY` | — | API key(s) (instead of `.opencode_go_key`) — separate multiple keys with `,` |
| `PORT` | `11435` | Proxy listen port |

## License

[GPL 3.0](LICENSE)
