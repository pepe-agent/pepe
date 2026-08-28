---
title: Inicio rápido
description: Instala Pepe, crea un agente y arranca la primera conversación.
---

Con pocos comandos instalas Pepe, creas un agente y empiezas a hablar con él. `pepe setup` toma el camino más corto: modelo, clave, primer agente y, si quieres, un canal.

## 1. Instala

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
pepe help
```

## 2. Configura

```bash
pepe setup
```

El asistente guiado escribe `~/.pepe/config.json`. Cuando te pida una clave, dale preferencia a una referencia como `${OPENROUTER_API_KEY}` para que el secreto nunca quede escrito en el archivo.

## 3. Habla

```bash
pepe run assistant "¿qué archivos hay en este directorio?"
```

Si ya marcaste un agente como predeterminado, puedes omitir el nombre:

```bash
pepe run "resume el README en tres puntos"
```

Para una conversación que se mantiene en el tiempo:

```bash
pepe chat assistant
```

`pepe run` responde una vez y se olvida de todo: nada pasa a la siguiente ejecución. Si quieres retomar una conversación más tarde en la terminal, dale un nombre a la sesión:

```bash
pepe chat assistant --session mi-sesion
```

Cuando una herramienta necesita actuar sobre tu máquina, como ejecutar un comando o escribir un archivo, Pepe primero te pide aprobación.

## 4. Levanta la API y el panel

```bash
pepe serve --port 4000
```

El mismo agente queda ahora accesible en tres frentes:

- Panel local: `http://localhost:4000`
- API compatible con OpenAI: `POST /v1/chat/completions`
- WebSocket: `ws://localhost:4000/socket/websocket`

Prueba la API:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hola"}]}'
```

<div class="note"><strong>La API arranca local.</strong> Hasta que crees un token, solo esta máquina puede llamar a <code>/v1</code>: nadie más llega a tu agente. Crea uno con <code>pepe token add</code> antes de exponer el servidor.</div>

## 5. Conecta un canal

Telegram es la prueba más rápida porque no exige una URL pública:

```bash
pepe gateway telegram setup
pepe gateway telegram
```

A partir de ahí, cualquiera que le escriba al bot habla con ese mismo agente. WhatsApp, Slack, Discord, Teams y Google Chat están cubiertos en [Canales](../channels/).

## 6. Automatiza

```bash
pepe cron add
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
```

Usa tareas programadas para lo que se repite, y vigilancias para que te avisen una sola vez cuando algo que te importa cambie.

## Siguientes pasos

- [Agentes y herramientas](../agents/)
- [API HTTP](../api/)
- [Canales](../channels/)
- [Tareas programadas](../scheduled/)
- [Seguridad y permisos](../security/)
- [Plugins](../plugins/)
