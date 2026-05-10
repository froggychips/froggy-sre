# froggy-sre

macOS daemon for SRE incident response — part of the [Froggy](https://github.com/froggychips/Froggy) ecosystem.

## Architecture

```
Claude Code  →  froggy-sre (MCP stdio)
                  ↓  sre_analyze
             AgentPipeline
               Analyzer      →  Anthropic API (v0.1)
               Hypothesis        Froggy local LLM (v0.2)
               Critic
               Fix
               Risk
                  ↓
             IncidentReport
```

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
- `ANTHROPIC_API_KEY` env var

## Build

```bash
swift build -c release
```

## Claude Code MCP setup

Add to `~/.claude.json` under `mcpServers`:

```json
"froggy-sre": {
  "command": "/path/to/froggy-sre",
  "env": {
    "ANTHROPIC_API_KEY": "..."
  }
}
```

Optional: override model via `FROGGY_SRE_MODEL` (default: `claude-haiku-4-5-20251001`).

## Tools

### `sre_analyze`

Analyzes a Kubernetes incident through the 5-stage pipeline.

```json
{
  "labels":      { "alertname": "PodCrashLooping", "namespace": "squad-prod", "pod": "api-7f9b" },
  "annotations": { "summary": "Pod has restarted 8 times in 15 minutes" },
  "startsAt":    "2026-05-10T12:00:00Z"
}
```

## Roadmap

- [x] MCP server (stdio JSON-RPC 2.0)
- [x] `sre_analyze` tool
- [x] Analyzer agent (real LLM call)
- [ ] Hypothesis / Critic / Fix / Risk agents (real LLM)
- [ ] Route LLM calls to Froggy local daemon
- [ ] Unix socket mode for standalone daemon usage
- [ ] k8s context enrichment (pod logs, events via kubeconfig)
