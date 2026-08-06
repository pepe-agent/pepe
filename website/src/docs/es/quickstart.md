---
title: Inicio rápido
description: Instala Pepe, crea un agente y ejecuta la primera conversación.
---

En pocos comandos instalas Pepe, creas un agente y hablas con él. `pepe setup`
toma el camino corto: modelo, clave, primer agente y canal opcional.

## 1. Instala

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
pepe help
```

## 2. Configura

```bash
pepe setup
```

El asistente escribe `~/.pepe/config.json`. Cuando pida una clave, prefiere una
referencia como `${OPENROUTER_API_KEY}` para que el secreto no quede en el archivo.

## 3. Habla

```bash
pepe run assistant "¿Qué archivos hay en este directorio?"
```

Si marcaste un agente como predeterminado, omite el nombre:

```bash
pepe run "resume el README en tres puntos"
```

Para una conversación continua:

```bash
pepe chat assistant
```

`pepe run` responde una vez y olvida: nada pasa a la siguiente ejecución. Para
retomar una conversación en la terminal más tarde, dale un nombre a la sesión:

```bash
pepe chat assistant --session mi-sesion
```

Cuando una herramienta quiera actuar sobre tu máquina, como ejecutar un comando o
escribir un archivo, Pepe pide tu aprobación antes.

## 4. Sirve la API y el panel

```bash
pepe serve --port 4000
```

El mismo agente queda ahora accesible en tres lugares:

- Panel local: `http://localhost:4000`
- API compatible con OpenAI: `POST /v1/chat/completions`
- WebSocket: `ws://localhost:4000/socket/websocket`

Prueba la API:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hola"}]}'
```

<div class="note"><strong>La API empieza local.</strong> Hasta que crees un token, solo esta máquina puede llamar a <code>/v1</code>: nadie de fuera llega a tu agente. Crea uno con <code>pepe token add</code> antes de exponer el servidor.</div>

## 5. Conecta un canal

Telegram es la prueba más rápida porque no necesita una URL pública:

```bash
pepe gateway telegram setup
pepe gateway telegram
```

Después, quien escriba al bot habla con el mismo agente. WhatsApp, Slack, Discord,
Teams y Google Chat están en [Canales](../channels/).

## 6. Automatiza

```bash
pepe cron add
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
```

Usa tareas programadas para lo que se repite, y vigilancias para que te avisen una
sola vez cuando algo que te importa cambie.

## Siguientes pasos

- [Agentes y herramientas](../agents/)
- [API HTTP](../api/)
- [Canales](../channels/)
- [Tareas programadas](../scheduled/)
- [Seguridad y permisos](../security/)
- [Plugins](../plugins/)
