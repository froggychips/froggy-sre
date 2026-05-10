# froggy-sre 🐸

🌐 [English](README.md) · **Русский**

> **SRE-агент для macOS — получает контекст k8s, запускает 5-этапный LLM-пайплайн, сохраняет историю локально.**

[Froggy](https://github.com/froggychips/Froggy) отвечает за локальный инференс и контекст экрана.
[froggy-mcp](https://github.com/froggychips/froggy-mcp) соединяет Froggy с Claude Code.
`froggy-sre` добавляет SRE-слой — передайте Prometheus-алерт и инструмент автоматически тянет
логи подов и события k8s через `kubectl`, запускает 5-этапный анализ, сохраняет всё локально.

LLM-вызовы роутируются через демон Froggy (приватно, без API-ключа); фоллбек на Anthropic API.

**Статус:** рабочий прототип. Не продукт.

💬 Контакт: [@froggychips](https://t.me/froggychips) в Telegram  
📜 Лицензия: [MIT](LICENSE)

---

## Экосистема

| Репо | Роль |
|---|---|
| [Froggy](https://github.com/froggychips/Froggy) | Локальный LLM-демон, OCR, управление памятью |
| [FroggyKit](https://github.com/froggychips/FroggyKit) | Общий Swift-пакет — FroggyClient IPC |
| [froggy-mcp](https://github.com/froggychips/froggy-mcp) | MCP-мост → Claude Code |
| **froggy-sre** | SRE-агент реагирования на инциденты |
| [sre-ai-copilot](https://github.com/froggychips/sre-ai-copilot) | Python K8s-бэкенд (облачный деплой) |

## Инструменты

| Инструмент | Что делает |
|---|---|
| `sre_analyze` | Получает k8s-контекст + запускает 5-этапный пайплайн. Результат сохраняется. |
| `sre_history` | Возвращает последние инциденты, сохранённые на этом маке. |

## Пайплайн

```
sre_analyze
  → K8sContextFetcher  — логи пода, события, describe (kubectl)
  → Analyzer           — что происходит, немедленный импакт
  → Hypothesis         — наиболее вероятная корневая причина
  → Critic             — слабые места гипотезы
  → Fix                — конкретный фикс (kubectl / config)
  → Risk               — оценка 0.0–1.0 + обоснование
```

## Требования

- macOS 14+, Apple Silicon
- Swift 6
- `kubectl` в PATH (опционально — для обогащения контекстом)
- демон [Froggy](https://github.com/froggychips/Froggy) **или** `ANTHROPIC_API_KEY` (достаточно одного)

## Сборка

```sh
git clone https://github.com/froggychips/froggy-sre
cd froggy-sre
swift build -c release
```

## Установка (Claude Code MCP)

Добавить в `~/.claude.json` в раздел `mcpServers`:

```json
"froggy-sre": {
  "command": "/path/to/.build/release/froggy-sre",
  "env": { "ANTHROPIC_API_KEY": "sk-ant-..." }
}
```

## Установка (режим демона)

```sh
.build/release/froggy-sre --daemon

echo '{"labels":{"alertname":"PodCrashLooping","namespace":"squad-prod","pod":"api-7f9b"},"annotations":{},"startsAt":"2026-05-10T12:00:00Z"}' \
  | nc -U /tmp/froggy-sre.sock
```

## Переменные окружения

| Переменная | По умолчанию | Описание |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Anthropic API-ключ (фоллбек) |
| `FROGGY_IPC_SOCKET` | `~/Library/Application Support/Froggy/froggy.sock` | Сокет демона Froggy |
| `FROGGY_SRE_SOCKET` | `/tmp/froggy-sre.sock` | Сокет режима демона |
| `FROGGY_SRE_MODEL` | `claude-haiku-4-5-20251001` | Модель Anthropic для фоллбека |
| `FROGGY_SRE_MAX_TOKENS` | `1024` | Максимум токенов на вызов |

## Roadmap

- [x] MCP-сервер (stdio JSON-RPC 2.0)
- [x] `sre_analyze` — 5-этапный агентный пайплайн
- [x] `sre_history` — локальный JSON-архив в `~/.froggy-sre/incidents/`
- [x] `LLMRouter` — локальный инференс через Froggy, фоллбек на Anthropic
- [x] `K8sContextFetcher` — логи, события, describe через kubectl
- [x] `FroggyKit` — общий IPC-пакет
- [x] Режим демона — Unix-сокет-сервер (`--daemon`)
- [ ] Исторический контекст — похожие инциденты из `sre_history` в Hypothesis-агент
- [ ] Перевод froggy-mcp на FroggyKit

---
*Часть экосистемы [Froggy](https://github.com/froggychips/Froggy).*
