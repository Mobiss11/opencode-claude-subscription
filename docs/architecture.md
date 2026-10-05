# Архитектура решения

Дополняет [README](../README.md); движок — в репозитории
[`Mobiss11/ai-gateway`](https://github.com/Mobiss11/ai-gateway) (его
`docs/architecture.md` описывает шлюз изнутри — каталог, кэш, streaming).

## Поток запроса

```
OpenCode (любая машина в tailnet/LAN)
   │  POST /v1/chat/completions, OpenAI-формат, Bearer AI_GATEWAY_TOKEN
   ▼
ai-gateway (хост, :8130, LaunchAgent com.alluc.ai-gateway)
   │  resolve alias → upstream
   │  anthropic_bridge.openai_to_anthropic():
   │    - system/developer → поле system (блоки + cache_control)
   │    - move_env_to_user: env-секция OpenCode → первое user-сообщение
   │    - reasoning_effort → thinking.budget_tokens
   │    - tools/tool_calls ↔ tool_use/tool_result
   │  POST /v1/messages, Bearer KRAUBE_SERVE_KEY
   ▼
kraube serve (хост, :8787, loopback, com.alluc.kraube-serve)
   │  OAuth-токен подписки, заголовки Claude Code
   │  (опц. через SSH-SOCKS-туннель socks5h://127.0.0.1:1080)
   ▼
Anthropic Messages API — лимиты плана, не extra-usage
```

Ответ идёт обратно тем же путём: Anthropic → OpenAI-формат (или SSE →
`chat.completion.chunk`), usage с cache-полями сохраняется.

## Размещение и файлы

| Машина | Что | Файлы |
| --- | --- | --- |
| хост (mini) | шлюз | `~/ai-gateway/` (git), `~/.config/ai-gateway/{config.json,env}` |
| хост (mini) | kraube | `~/.local/bin/kraube`, `~/.config/kraube/{env,credentials.json}` |
| хост (mini) | агенты | `~/Library/LaunchAgents/com.alluc.{ai-gateway,kraube-serve}.plist` |
| хост (mini) | логи | `~/ai-gateway/logs/`, `~/Library/Logs/kraube-serve.*.log` |
| клиент | OpenCode | `~/.config/opencode/opencode.json` → провайдер `homelab` |

Клиенту нужен только HTTP-доступ к `:8130` и токен шлюза. kraube наружу
не публикуется (loopback), OAuth-credentials не покидают хост.

## Порты

| Порт | Кто | Доступ |
| --- | --- | --- |
| 8130 | ai-gateway | tailnet/LAN (listen 0.0.0.0, auth по токену) |
| 8787 | kraube serve | только loopback |
| 1080 | SSH-SOCKS-туннель (опц.) | только loopback |

## Почему это работает и что держит стек живым

1. **Формат**: OpenCode говорит на OpenAI API; мост шлюза переводит в
   Anthropic Messages и обратно, включая streaming и tool-calls.
2. **Биллинг**: kraube проксирует через OAuth-подписку с заголовками
   Claude Code; env-секция OpenCode переносится из system в user
   (`move_env_to_user`), чтобы Anthropic не классифицировал запрос как
   third-party app — [диагноз и пробы](third-party-app-400.md).
3. **Экономия**: мост ставит `cache_control`-брейкпоинты (system →
   инструменты → история), повторяющийся префикс тарифицируется ~0.1x.
4. **Управляемость**: один токен на клиентов; rotate = правка env-файла
   и рестарт шлюза; usage-логи видны в логах шлюза.

## Ротация/откат

- Токен шлюза: `AI_GATEWAY_TOKEN` в `~/.config/ai-gateway/env` →
  `launchctl kickstart -k gui/$(id -u)/com.alluc.ai-gateway` → обновить
  `apiKey` у провайдера в OpenCode.
- Откат кода шлюза: `git -C ~/ai-gateway checkout <коммит>` + тот же
  kickstart.
- Credentials подписки: `launchctl bootout gui/$(id -u)/com.alluc.kraube-serve`
  → `~/.local/bin/kraube login` → bootstrap обратно (refresh-токен
  одноразовый, поэтому демона на время логина глушим).
