---
title: Skills
description: Instala instrucciones reutilizables que enseñan flujos de trabajo repetibles a los agentes.
---

Las skills son instrucciones Markdown reutilizables que enseñan a un agente cómo ejecutar un flujo de trabajo. Las integradas viven en `priv/skills/` y se pueden instalar para que los agentes las descubran y las apliquen durante una ejecución.

## El registro: cómo se encuentran las herramientas

`Pepe.Tools` es el registro único. Combina dos fuentes.

- El conjunto **integrado**, una lista fija en `Pepe.Tools`. Incluye `bash`,
  `run_script`, `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`,
  `fetch_url`, `web_search`, `send_file`, y las herramientas de gestión que un
  agente usa para operar el runtime por chat (`manage_agent`, `manage_channel`,
  `enable_tool`, `schedule_task` y otras).
- Los **plugins**, descubiertos en tiempo de ejecución desde la carpeta de plugins.

`Pepe.Tools.all/0` devuelve las integradas seguidas de cada herramienta de
plugin cargada. Cuando listas las herramientas de un agente, cada nombre se
busca aquí. Hay una regla que vale la pena conocer: ante una colisión de
nombres, gana la integrada. No puedes tapar `read_file` con un plugin del
mismo nombre, así que elige un nombre distinto para tu herramienta.

### Conceder una herramienta a un agente

Un plugin instalado no entrega automáticamente sus herramientas a todos los
agentes. Solo las herramientas que listas en un agente quedan expuestas para
él, y cada llamada sigue pasando por la misma puerta de permisos que una
herramienta integrada. Concedes una herramienta de tres formas.

**Con la CLI de pepe.** Lista la herramienta en el `--tools` del agente:

```bash
pepe agent add assistant --tools reverse_text,web_search,read_file
```

**En el panel.** Abre el agente en Agentes y marca la herramienta en su lista
de herramientas. Las herramientas del plugin aparecen junto a las integradas.

#### Hazlo por chat

Un agente que tiene la herramienta integrada `enable_tool` puede activar una
herramienta para sí mismo después de que instales un plugin, sin que tengas
que tocar la CLI ni el panel.

> Tú: activa la herramienta reverse_text
>
> Agente: reverse_text activada; ya puedes usarla desde tu próximo mensaje

`enable_tool` solo acepta una herramienta que ya exista como integrada o como
plugin cargado, y el cambio vale desde el próximo mensaje del agente. Para
conceder una herramienta a un agente *distinto*, un agente con la herramienta
`manage_agent` puede hacerlo con la acción `add_tool`. Esa herramienta está
limitada a los agentes que el agente que actúa tiene permiso para gestionar,
y sus instrucciones le mandan confirmar el cambio contigo antes de aplicarlo.

> Tú: dale al agente de soporte la herramienta gmail_search
>
> Agente: Voy a añadir gmail_search al agente "support". ¿Confirmas?
>
> Tú: sí
>
> Agente: gmail_search añadida a support.
