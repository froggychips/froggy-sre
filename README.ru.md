# froggy-sre 🐸

🌐 [English](README.md) · **Русский**

> **SRE-агент для macOS — запускает 5-этапный LLM-пайплайн на Kubernetes-алертах и сохраняет историю инцидентов локально.**

[Froggy](https://github.com/froggychips/Froggy) отвечает за локальный инференс и контекст экрана.
[froggy-mcp](https://github.com/froggychips/froggy-mcp) соединяет Froggy с Claude Code.
`froggy-sre` добавляет SRE-слой — передайте Prometheus-алерт и получите структурированный анализ
(что происходит, корневая причина, критика, фикс, оценка риска) одним вызовом `sre_analyze`.
Всё сохраняется локально в `~/.froggy-sre/incidents/`.

LLM-вызовы роутируются через локальный демон Froggy (приватно, без API-ключа);
если демон недоступен или модель не загружена — фоллбек на Anthropic API.

**Статус:** рабочий прототип. Не продукт.

💬 Контакт: [@froggychips](https://t.me/froggychips) в Telegram  
📜 Лицензия: [MIT](LICENSE)

---

## Экосистема

| Репо | Роль |
|---|---|
| [Froggy](https://github.com/froggychips/Froggy) | Локальный LLM-демон, OCR, управление памятью |
| [froggy-mcp](https://github.com/froggychips/froggy-mcp) | MCP-мост → Claude Code |
| **froggy-sre** | SRE-агент реагирования на инциденты |
| [sre-ai-copilot](https://github.com/froggychips/sre-ai-copilot) | Python K8s-бэкенд (облачный деплой) |

```
Claude Code  ←—stdio / JSON-RPC—→  froggy-sre
                                      ↓ LLMRouter
                              демон Froggy (локально, приватно)
                              Anthropic API (фоллбек)
                                      ↓
                               ~/.froggy-sre/incidents/
```

## Инструменты

| Инструмент | Что делает |
|---|---|
| `sre_analyze` | Запускает алерт через 5-этапный пайплайн. Результат сохраняется в историю. |
| `sre_history` | Возвращает последние инциденты, сохранённые на этом маке. |

## Пайплайн

```
sre_analyze
  → Analyzer     — что происходит, немедленный импакт
  → Hypothesis   — наиболее вероятная корневая причина
  → Critic       — слабые места гипотезы
  → Fix          — конкретный фикс (kubectl / config)
  → Risk         — оценка 0.0–1.0 + обоснование
```

Каждый этап вызывает `LLMRouter`: сначала Froggy, при недоступности — Anthropic API.

## Требования

- macOS 14+, Apple Silicon
- Swift 6
- демон [Froggy](https://github.com/froggychips/Froggy) **или** `ANTHROPIC_API_KEY` (достаточно одного)

## Сборка

```sh
git clone https://github.com/froggychips/froggy-sre
cd froggy-sre
swift build -c release
```

## Установка (Claude Code)

Добавить в `~/.claude.json` в раздел `mcpServers`:

```json
"froggy-sre": {
  "command": "/path/to/.build/release/froggy-sre",
  "env": {
    "ANTHROPIC_API_KEY": "sk-ant-..."
  }
}
```

`ANTHROPIC_API_KEY` не нужен, если демон Froggy запущен с загруженной моделью.

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Anthropic API-ключ (фоллбек) |
| `FROGGY_IPC_SOCKET` | `~/Library/Application Support/Froggy/froggy.sock` | Путь к сокету демона |
| `FROGGY_SRE_MODEL` | `claude-haiku-4-5-20251001` | Модель Anthropic для фоллбека |
| `FROGGY_SRE_MAX_TOKENS` | `1024` | Максимум токенов на вызов |

## Примеры

```
sre_analyze {
  "labels":      { "alertname": "PodCrashLooping", "namespace": "squad-prod", "pod": "api-7f9b" },
  "annotations": { "summary": "Под перезапускался 8 раз за 15 минут" },
  "startsAt":    "2026-05-10T12:00:00Z"
}
```

```
sre_history { "limit": 5 }
```

## Roadmap

- [x] MCP-сервер (stdio JSON-RPC 2.0)
- [x] `sre_analyze` — 5-этапный агентный пайплайн (все агенты работают)
- [x] `sre_history` — локальный JSON-архив в `~/.froggy-sre/incidents/`
- [x] `LLMRouter` — локальный инференс через Froggy, фоллбек на Anthropic
- [ ] Обогащение k8s-контекстом — логи подов и евенты через kubeconfig
- [ ] Режим демона через Unix-сокет

---
*Часть экосистемы [Froggy](https://github.com/froggychips/Froggy).*
