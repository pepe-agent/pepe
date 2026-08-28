---
title: Gestionar por conversación
description: Da a un agente de confianza las herramientas para que ajuste Pepe con solo pedírselo, en una conversación normal.
---

Basta con pedírselo a un agente para reconfigurar Pepe, siempre que antes le hayas dado las herramientas de gestión que corresponden. Como estas acciones tocan cómo funciona Pepe o reparten acceso, van todas protegidas: primero te piden aprobación, y solo después se ejecutan.

Pepe está pensado para que un agente resuelva por su cuenta pedidos sobre el propio Pepe ("añade un bot", "programa esto", "conecta Sentry", "cambia la zona horaria") sin necesitar código especial para cada caso, y sin que eso abra ninguna puerta peligrosa. Lo logra apoyándose en cuatro cosas: lee su propia documentación, averigua qué le está permitido tocar, recurre a un puñado de herramientas protegidas para los caminos habituales, y al final comprueba que lo que hizo quedó bien.

## Lee su propia documentación

Pepe trae de fábrica sus propias guías prácticas, guardadas en `priv/docs/`, y ahí cubre agentes, canales, cron, MCP, plugins, permisos y configuración. El system prompt de cada agente las señala como la fuente que manda, y la herramienta de solo lectura `docs` carga la que corresponda en el momento en que hace falta. Ante un pedido nuevo o que no estaba previsto, el agente lee antes de adivinar. Si quieres ampliar esas guías o reemplazar alguna, pon las tuyas en `~/.pepe/docs/`.

## Descubre qué puede tocar

Llamar a `config_set` sin argumentos devuelve su propio esquema: qué ajustes puede tocar, cuánto valen hoy, y qué valores acepta cada uno. La lista de lo editable es corta y fija: `default_model`, `default_agent`, `language`, `timezone`, `telegram.require_mention` / `telegram.enabled`, y `secrets.expose_env` (los *nombres* de las variables de entorno que el shell del agente puede conservar después de que Pepe borre el resto, pensado para abrir una bóveda de la que ya tiene un token; nombres nada más, nunca un valor secreto). Cualquier otra cosa se rechaza, señalando la herramienta protegida que corresponde: `manage_agent`, `manage_channel`, `manage_mcp`, `manage_plugin`, `schedule_task` o `manage_token`. Los valores de los secretos, esos nunca se editan por chat.

## Administrar agentes

`can_manage` decide a qué agentes puede administrar otro agente (crearlos,
editarlos, reconfigurarlos, entrenarlos) a través de la herramienta
`manage_agent`. Por defecto viene cerrado, y su significado no deja lugar a
dudas:

- Sin definir (`null`): solo puede administrarse a sí mismo.
- Vacío (`[]`, con `--can-manage none`): no administra a nadie, ni siquiera a
  sí mismo. Útil para un agente hijo bloqueado, por ejemplo uno de cara al
  cliente que no debe poder cambiarse solo.
- Una lista de nombres: exactamente esos agentes, ninguno más. Si quieres que
  también se administre a sí mismo, incluye su propio nombre en la lista.
- `["*"]` (con `--can-manage "*"`): todos los agentes. Un superadministrador
  declarado sin rodeos.

Concede autoridad de gestión directamente:

```bash
pepe agent manage supervisor "*"
```

### Hazlo por chat

Un agente con permisos de administrador usa `manage_agent` para darle forma a
los agentes bajo su alcance, con las acciones `list`, `get`, `create`,
`set_persona`, `set_model`, `add_tool`, `remove_tool` y `remember` (agrega un
dato permanente a la memoria del agente destino). Por ejemplo:

```text
Dale al agente de soporte la herramienta send_file y anota en su memoria que
los reembolsos de más de 200 necesitan que intervenga una persona.
```

Ahí el agente llama primero a `manage_agent` con `action: "add_tool"`, y
después con `action: "remember"`. Ninguna de estas acciones pasa de largo: el
agente propone el cambio, tú das el visto bueno, y solo entonces se aplica.
Con la herramienta aparte `rename_agent` ("De ahora en adelante, llámate
scout"), un agente también puede ponerse otro nombre a sí mismo, lo que mueve
su carpeta de trabajo y entra en vigor desde el siguiente mensaje.

## Instalar plugins de la comunidad

Desde el chat, la herramienta protegida `manage_plugin` instala, escanea, lista y quita herramientas y canales `.exs` sueltos. Recibe una ruta local, un `.tar.gz` o una URL de GitHub, y cada instalación pasa por el mismo escaneo estático que corre la CLI.

A diferencia de la CLI, aquí no existe el `--force`. Si el escaneo devuelve un veredicto `danger`, el chat lo rechaza siempre. Pasar por encima de un veredicto peligroso es una decisión que le toca al operador, tomada a propósito desde la terminal, y a la que jamás se puede convencer a un agente en plena conversación.

## Repartir acceso a la API

La herramienta protegida `manage_token` crea, lista y revoca tokens de portador de `/v1` desde el chat, limitados a un proyecto o a un único agente. Gracias a esto, un agente puede darle acceso a una integración sin que tengas que abrir una terminal. Igual que las demás herramientas de gestión, no es de solo lectura, así que primero pasa por la barrera de permisos.

## El propietario puede correr toda la CLI

Si tienes un agente propietario en quien confías del todo, `manage_pepe` le permite correr desde el chat cualquier comando `pepe` no interactivo, usando el mismo despachador que la CLI. Los comandos interactivos o bloqueantes (`setup`, `chat`, `serve` y las pasarelas en primer plano) quedan fuera, rechazados, y la herramienta sigue detrás de la barrera de permisos. Dásela únicamente a un agente propietario de confianza, nunca a uno que reciba entradas de las que no puedes fiarte. Los detalles están en [Seguridad y entorno aislado](../security/).

## Comprueba su propio trabajo

Tras cambiar algo, el agente (o tú mismo) corre el doctor. Sin salir a la red, comprueba que cada referencia `${ENV}` resuelve bien, que los agentes apuntan a modelos reales y herramientas que existen, y que las programaciones de cron, las zonas horarias y los agentes son válidos. Además hace sondeos en vivo: un `getMe` de Telegram por cada bot, un ping por cada conexión de modelo, y un arranque de MCP con listado de herramientas por cada servidor.

```bash
pepe doctor              # sondeos en vivo (Telegram, modelos, MCP)
pepe doctor --offline    # solo consistencia de configuración, sin red
```

El ciclo completo es hacer, verificar y corregir: herramientas protegidas y estructuradas para los caminos frecuentes, herramientas genéricas más la documentación para todo lo demás, y el doctor al final para confirmar que salió bien.
