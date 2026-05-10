# froggy-sre 🐸

🌐 [English](README.md) · **Русский**

> **SRE-агент для macOS — запускает 5-этапный LLM-пайплайн на Kubernetes-алертах и сохраняет историю инцидентов локально.**

[Froggy](https://github.com/froggychips/Froggy) отвечает за локальный инференс и контекст экрана.
[froggy-mcp](https://github.com/froggychips/froggy-mcp) соединяет Froggy с Claude Code.
`froggy-sre` добавляет SRE-слой — передайте Prometheus-алерт и получите структурированный анализ
(что происходит, корневая причина, критика, фикс, оценка риска) одним вызовом `sre_analyze`.
Всё сохраняется локально в `~/.froggy-sre/incidents/`.

**Статус:** рабочий прототип. Не продукт. Для LLM-вызовов используется Anthropic API;
роутинг на локальный инференс Froggy — в планах.

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
Claude Code  ←—stdio / JSON-RPC—→  froggy-sre  ←—HTTPS—→  Anthropic API
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

## Требования

- macOS 14+, Apple Silicon
- Swift 6
- переменная `ANTHROPIC_API_KEY`

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

После перезапуска Claude Code инструменты `sre_analyze` и `sre_history` будут доступны в каждой сессии.

Опционально: модель переопределяется через `FROGGY_SRE_MODEL` (по умолчанию: `claude-haiku-4-5-20251001`).

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
- [ ] Роутинг LLM-вызовов в локальный демон Froggy (без облака, без API-ключа)
- [ ] Обогащение k8s-контекстом — логи подов и евенты через kubeconfig
- [ ] Режим демона через Unix-сокет

---
*Часть экосистемы [Froggy](https://github.com/froggychips/Froggy).*
