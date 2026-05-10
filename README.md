# froggy-sre 🐸

🌐 **English** · [Русский](README.ru.md)

> **SRE incident response agent for macOS — fetches live k8s context, runs a 5-stage LLM pipeline, saves history locally.**

[Froggy](https://github.com/froggychips/Froggy) handles local inference and screen context.
[froggy-mcp](https://github.com/froggychips/froggy-mcp) connects Froggy to Claude Code.
`froggy-sre` adds the SRE layer — feed it a Prometheus alert and it automatically pulls pod logs
and k8s events via `kubectl`, runs a 5-stage analysis pipeline, and returns a structured report
(what's happening, root cause, critique, proposed fix, risk score). Everything saved locally.

LLM calls go to the Froggy daemon first (private, no API key); falls back to Anthropic API.

**Status:** working prototype. Not a product.

💬 Contact: [@froggychips](https://t.me/froggychips) on Telegram  
📜 License: [MIT](LICENSE)

---

## Ecosystem

| Repo | Role |
|---|---|
| [Froggy](https://github.com/froggychips/Froggy) | Local LLM daemon, OCR, memory management |
| [FroggyKit](https://github.com/froggychips/FroggyKit) | Shared Swift package — FroggyClient IPC |
| [froggy-mcp](https://github.com/froggychips/froggy-mcp) | MCP bridge → Claude Code |
| **froggy-sre** | SRE incident response agent |
| [sre-ai-copilot](https://github.com/froggychips/sre-ai-copilot) | Python K8s backend (cloud deploy) |

```
Claude Code  ←—stdio / JSON-RPC—→  froggy-sre
                                      ↓ K8sContextFetcher (kubectl)
                                      ↓ AgentPipeline
                                      ↓ LLMRouter
                              Froggy daemon (local, private)
                              Anthropic API (fallback)
                                      ↓
                               ~/.froggy-sre/incidents/
```

## Tools

| Tool | What it does |
|---|---|
| `sre_analyze` | Fetch k8s context + run 5-stage pipeline. Result saved to history. |
| `sre_history` | Return recent incident reports saved on this machine. |

## Pipeline

```
sre_analyze
  → K8sContextFetcher  — pod logs, warning events, pod description (via kubectl)
  → Analyzer           — what's happening, immediate impact
  → Hypothesis         — most likely root cause
  → Critic             — weaknesses in the hypothesis
  → Fix                — concrete kubectl / config remediation
  → Risk               — score 0.0–1.0 + rationale
```

All LLM calls use `LLMRouter`: Froggy local inference first, Anthropic API as fallback.

## Requirements

- macOS 14+, Apple Silicon
- Swift 6
- `kubectl` in PATH (optional — used for context enrichment)
- [Froggy daemon](https://github.com/froggychips/Froggy) running **or** `ANTHROPIC_API_KEY` (at least one required)

## Build

```sh
git clone https://github.com/froggychips/froggy-sre
cd froggy-sre
swift build -c release
```

## Install (Claude Code MCP)

Add to `~/.claude.json` under `mcpServers`:

```json
"froggy-sre": {
  "command": "/path/to/.build/release/froggy-sre",
  "env": {
    "ANTHROPIC_API_KEY": "sk-ant-..."
  }
}
```

`ANTHROPIC_API_KEY` is optional if the Froggy daemon is running with a model loaded.

## Install (daemon mode)

```sh
# Run as a standalone Unix socket daemon
.build/release/froggy-sre --daemon

# Send an incident (newline-delimited JSON)
echo '{"labels":{"alertname":"PodCrashLooping","namespace":"squad-prod","pod":"api-7f9b"},"annotations":{},"startsAt":"2026-05-10T12:00:00Z"}' \
  | nc -U /tmp/froggy-sre.sock
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Anthropic API key (fallback when Froggy unavailable) |
| `FROGGY_IPC_SOCKET` | `~/Library/Application Support/Froggy/froggy.sock` | Froggy daemon socket |
| `FROGGY_SRE_SOCKET` | `/tmp/froggy-sre.sock` | Daemon mode listen socket |
| `FROGGY_SRE_MODEL` | `claude-haiku-4-5-20251001` | Anthropic model for fallback |
| `FROGGY_SRE_MAX_TOKENS` | `1024` | Max tokens per LLM call |

## froggy-sre vs sre-ai-copilot

Both run the same 5-stage incident pipeline. Choose based on your context:

| | froggy-sre | [sre-ai-copilot](https://github.com/froggychips/sre-ai-copilot) |
|---|---|---|
| **Trigger** | MCP tool call from Claude Code | AlertManager webhook (headless) |
| **Runtime** | macOS dev machine | Any server / k8s pod |
| **LLM** | Froggy local → Anthropic fallback | Anthropic API |
| **k8s context** | `kubectl` via kubeconfig | In-cluster k8s SDK |
| **Storage** | `~/.froggy-sre/incidents/` (local JSON) | SQLite + Celery queue |
| **Notifications** | Structured response in Claude Code | Discord webhook |
| **Use when** | You're at your Mac and want Claude to analyse an incident interactively | You need always-on headless alerting running in production |

## Roadmap

- [x] MCP server (stdio JSON-RPC 2.0)
- [x] `sre_analyze` — 5-stage agent pipeline (all agents live)
- [x] `sre_history` — local JSON incident archive in `~/.froggy-sre/incidents/`
- [x] `LLMRouter` — Froggy local inference with Anthropic fallback
- [x] `K8sContextFetcher` — pod logs, k8s events, pod description via kubectl
- [x] `FroggyKit` — shared IPC package (extracted from froggy-mcp + froggy-sre)
- [x] Daemon mode — Unix socket server (`--daemon` flag)
- [ ] Historical context — similar past incidents fed into Hypothesis agent
- [ ] froggy-mcp integration — migrate froggy-mcp to use FroggyKit

---
*Part of the [Froggy](https://github.com/froggychips/Froggy) ecosystem.*
