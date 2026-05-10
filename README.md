# froggy-sre 🐸

🌐 **English** · [Русский](README.ru.md)

> **SRE incident response agent for macOS — runs a 5-stage LLM pipeline on Kubernetes alerts and saves incident history locally.**

[Froggy](https://github.com/froggychips/Froggy) handles local inference and screen context.
[froggy-mcp](https://github.com/froggychips/froggy-mcp) connects Froggy to Claude Code.
`froggy-sre` adds the SRE layer — feed it a Prometheus alert and get back a structured analysis
(what’s happening, root cause, critique, proposed fix, risk score) in one `sre_analyze` call.
Everything is saved locally under `~/.froggy-sre/incidents/`.

LLM calls are routed to the local Froggy daemon first (private, no API key needed);
if the daemon isn’t running or no model is loaded, it falls back to the Anthropic API.

**Status:** working prototype. Not a product.

💬 Contact: [@froggychips](https://t.me/froggychips) on Telegram  
📜 License: [MIT](LICENSE)

---

## Ecosystem

| Repo | Role |
|---|---|
| [Froggy](https://github.com/froggychips/Froggy) | Local LLM daemon, OCR, memory management |
| [froggy-mcp](https://github.com/froggychips/froggy-mcp) | MCP bridge → Claude Code |
| **froggy-sre** | SRE incident response agent |
| [sre-ai-copilot](https://github.com/froggychips/sre-ai-copilot) | Python K8s backend (cloud deploy) |

```
Claude Code  ←—stdio / JSON-RPC—→  froggy-sre
                                      ↓ LLMRouter
                              Froggy daemon (local, private)
                              Anthropic API (fallback)
                                      ↓
                               ~/.froggy-sre/incidents/
```

## Tools

| Tool | What it does |
|---|---|
| `sre_analyze` | Run a Kubernetes alert through the 5-stage pipeline. Result is saved to incident history. |
| `sre_history` | Return recent incident reports saved on this machine. |

## Pipeline

```
sre_analyze
  → Analyzer     — what’s happening, immediate impact
  → Hypothesis   — most likely root cause
  → Critic       — weaknesses in the hypothesis
  → Fix          — concrete kubectl / config remediation
  → Risk         — score 0.0–1.0 + rationale
```

Each stage calls `LLMRouter`: tries Froggy local inference first, falls back to Anthropic API.

## Requirements

- macOS 14+, Apple Silicon
- Swift 6
- [Froggy daemon](https://github.com/froggychips/Froggy) running **or** `ANTHROPIC_API_KEY` set (at least one required)

## Build

```sh
git clone https://github.com/froggychips/froggy-sre
cd froggy-sre
swift build -c release
```

## Install (Claude Code)

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

After restarting Claude Code the `sre_analyze` and `sre_history` tools will be available in every session.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Anthropic API key (fallback when Froggy unavailable) |
| `FROGGY_IPC_SOCKET` | `~/Library/Application Support/Froggy/froggy.sock` | Froggy daemon socket path |
| `FROGGY_SRE_MODEL` | `claude-haiku-4-5-20251001` | Anthropic model for fallback |
| `FROGGY_SRE_MAX_TOKENS` | `1024` | Max tokens per LLM call |

## Usage

```
sre_analyze {
  "labels":      { "alertname": "PodCrashLooping", "namespace": "squad-prod", "pod": "api-7f9b" },
  "annotations": { "summary": "Pod has restarted 8 times in 15 minutes" },
  "startsAt":    "2026-05-10T12:00:00Z"
}
```

```
sre_history { "limit": 5 }
```

## Roadmap

- [x] MCP server (stdio JSON-RPC 2.0)
- [x] `sre_analyze` — 5-stage agent pipeline (all agents live)
- [x] `sre_history` — local JSON incident archive in `~/.froggy-sre/incidents/`
- [x] `LLMRouter` — Froggy local inference with Anthropic fallback
- [ ] k8s context enrichment — pod logs and events via kubeconfig
- [ ] Unix socket mode for standalone daemon usage

---
*Part of the [Froggy](https://github.com/froggychips/Froggy) ecosystem.*
