---
title: Gestionar por conversación
description: Permite que agentes confiables configuren Pepe desde conversaciones en lenguaje natural.
---

Los agentes confiables pueden gestionar Pepe desde una conversación cuando les concedes las herramientas de gestión correspondientes. Estas acciones están protegidas porque cambian el estado del runtime o exponen acceso.

Pepe está hecho para que un agente pueda resolver una petición sobre el propio Pepe, del tipo "añade un bot", "programa esto", "conecta Sentry" o "cambia la zona horaria", sin código a medida para cada caso y sin ser nunca peligroso. Lo consigue leyendo su propia documentación, descubriendo qué tiene permiso para cambiar, usando un puñado de herramientas protegidas para los caminos más comunes y verificando después su propio trabajo.

## Lee su propia documentación

Las guías prácticas vienen con Pepe, en `priv/docs/`, y cubren agentes, canales, cron, MCP, plugins, permisos y configuración. El prompt de sistema de cada agente las lista como la fuente autoritativa, y la herramienta de solo lectura `docs` carga la guía adecuada cuando hace falta. Una petición nueva o imprevista se resuelve leyendo, no adivinando. Pon guías adicionales en `~/.pepe/docs/` para ampliar o sustituir las que vienen de fábrica.

## Descubre qué es editable

Llama a `config_set` sin ningún argumento y devuelve su propio esquema: los ajustes que puede editar, sus valores actuales y los valores que acepta. El conjunto editable es una lista blanca que falla cerrada, en concreto `default_model`, `default_agent`, `language`, `timezone` y `telegram.require_mention` / `telegram.enabled`. Cualquier otra cosa se rechaza, con una indicación de la herramienta protegida adecuada para el trabajo: `manage_agent`, `manage_channel`, `manage_mcp`, `manage_plugin`, `schedule_task` o `manage_token`. Los secretos nunca son editables por chat.

## Administrar agentes

`can_manage` controla qué agentes puede administrar un agente (crear, editar,
reconfigurar, entrenar) mediante la herramienta `manage_agent`. Está cerrado por
defecto y su significado es preciso:

- Sin definir (`null`): el agente solo puede administrarse a sí mismo.
- Vacío (`[]`, definido con `--can-manage none`): no puede administrar a nadie, ni
  siquiera a sí mismo. Un hijo bloqueado, por ejemplo un agente de cara al cliente
  que no debe alterarse a sí mismo.
- Una lista de nombres: exactamente esos agentes, y ningún otro. Incluye su propio
  nombre para dejar que también se administre a sí mismo.
- `["*"]` (definido con `--can-manage "*"`): todos los agentes. Un superadministrador
  explícito.

Concede autoridad de gestión directamente:

```bash
pepe agent manage supervisor "*"
```

### Hazlo por chat

Un agente administrador usa `manage_agent` para dar forma a los agentes de su
alcance. Sus acciones son `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool` y `remember` (añade un hecho duradero a la memoria del
destino). Por ejemplo:

```text
Dale al agente de soporte la herramienta send_file y registra en su memoria que
los reembolsos superiores a 200 necesitan una persona.
```

El agente llama a `manage_agent` con `action: "add_tool"` y luego con
`action: "remember"`. Cada una de estas acciones pasa por la barrera de permisos: el
agente propone el cambio, tú lo autorizas y solo entonces se aplica. Un agente
también puede renombrarse a sí mismo con la herramienta aparte `rename_agent` ("De
ahora en adelante, llámate scout"), que mueve su directorio de espacio de trabajo y
surte efecto en el siguiente mensaje.

## Instalar plugins de la comunidad

La herramienta protegida `manage_plugin` instala, escanea, lista y elimina herramientas y canales `.exs` sueltos desde el chat. Acepta una ruta local, un `.tar.gz` o una URL de GitHub, y cada instalación pasa por el mismo escaneo estático que usa la CLI.

A diferencia de la CLI, esta herramienta no tiene `--force`. Un veredicto `danger` del escaneo siempre se rechaza desde el chat. Saltarse un veredicto peligroso es una decisión de operador, tomada de forma deliberada en la terminal, y nunca una decisión a la que se pueda convencer a un agente en mitad de una conversación.

## Repartir acceso a la API

La herramienta protegida `manage_token` genera, lista y revoca tokens de portador de `/v1` desde el chat, acotados a un proyecto o a un solo agente. Así un agente puede darle acceso a una integración sin que tú tengas que bajar a una terminal. Como las demás herramientas de gestión, no es de solo lectura, así que pasa antes por la barrera de permisos.

## El propietario puede ejecutar la CLI entera

Para un agente propietario en el que confíes plenamente, `manage_pepe` ejecuta desde el chat cualquier comando `pepe` no interactivo, a través del mismo despachador que usa la CLI. Los comandos interactivos y bloqueantes (`setup`, `chat`, `serve` y las pasarelas en primer plano) se rechazan, y la herramienta sigue detrás de la barrera de permisos. Concédesela solo a un agente propietario de confianza, nunca a uno expuesto a entradas no confiables. Mira [Seguridad y entorno aislado](../security/) para los detalles.

## Verifica su propio trabajo

Después de cambiar algo, el agente (o tú) ejecuta el doctor. Hace comprobaciones sin conexión, confirmando que cada referencia `${ENV}` se resuelve, que los agentes apuntan a modelos reales y a herramientas conocidas, y que las programaciones, zonas horarias y agentes del cron son válidos. También lanza sondeos en vivo: un `getMe` de Telegram por bot, un ping por conexión de modelo, y un arranque de MCP más el listado de herramientas por servidor.

```bash
pepe doctor              # sondeos en vivo (Telegram, modelos, MCP)
pepe doctor --offline    # solo la consistencia de la configuración, sin red
```

El ciclo es hacer, verificar, corregir: herramientas protegidas y estructuradas para los caminos más comunes, herramientas genéricas más la documentación para todo lo demás, y el doctor para confirmar que funcionó.
