# froggy-sre

macOS daemon for SRE incident response — part of the [Froggy](https://github.com/froggychips/Froggy) ecosystem.

## Architecture

```
Prometheus alert / k8s event
  → froggy-sre daemon (Unix socket)
  → AgentPipeline: Analyzer → Hypothesis → Critic → Fix → Risk
  → human approval
  → kubectl intent (deterministic DSL, no raw commands)
```

LLM inference is routed to the local [Froggy](https://github.com/froggychips/Froggy) daemon (on-device, no cloud upload) or Anthropic API as fallback.

## Ecosystem

| Repo | Role |
|---|---|
| [Froggy](https://github.com/froggychips/Froggy) | Local LLM daemon, OCR, memory management |
| [froggy-mcp](https://github.com/froggychips/froggy-mcp) | MCP bridge → Claude Code |
| **froggy-sre** | SRE incident response agent |
| [sre-ai-copilot](https://github.com/froggychips/sre-ai-copilot) | Python K8s backend (cloud deploy) |

## Requirements

- macOS 14+, Apple Silicon
- Swift 6
- [Froggy](https://github.com/froggychips/Froggy) daemon running

## Build

```bash
swift build
swift test
```
