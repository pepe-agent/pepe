---
title: Configuración
description: Entiende dónde guarda Pepe la configuración, los secretos y el estado de ejecución.
---

## Dónde vive tu configuración

Todo lo que hiciste arriba está ahora en `~/.pepe/config.json`: la conexión al
modelo, el agente y cualquier canal. Sin base de datos, sin migraciones. Para mover
una configuración a otra máquina, copia ese archivo y define las mismas variables
de entorno a las que apuntan tus referencias `${VAR}`.

```bash
pepe config
```

Eso imprime la ruta de la configuración y un resumen de lo que está definido. Un archivo completo se ve así:

```json
{
  "default_model": "openrouter",
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-5-chat",
      "max_tokens": 4096
    }
  },
  "default_agent": "assistant",
  "agents": {
    "assistant": {
      "model": "openrouter",
      "system_prompt": "You are Pepe, a helpful agent.",
      "tools": ["bash", "run_script", "read_file", "write_file", "edit_file", "list_dir", "fetch_url", "web_search"],
      "auto_approve": ["read_file"],
      "max_iterations": 12
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [], "require_mention": true },
  "locale": "en",
  "server": { "port": 4000 }
}
```

`auto_approve` lista las herramientas que ese agente puede ejecutar sin detenerse a preguntarte, como se explica en la página de Seguridad. Puedes cambiar dónde vive el archivo con `PEPE_HOME` (un directorio) o `PEPE_CONFIG` (un archivo).

### Qué guarda un agente en disco

Cada agente recibe además un directorio persistente en `~/.pepe/agents/<name>/`. Ahí viven su `SOUL.md` (su persona) y cualquier archivo que cree mientras trabaja (`MEMORY.md`, `people.md` y lo que decida conservar). `~/.pepe/shared/` es compartido por todos los agentes.

Un agente que todavía no tiene identidad (sin `SOUL.md`, aún con la semilla por defecto) se presenta como Pepe, te dice que no tiene nombre ni características definidas, y se ofrece a configurarlo. Luego guarda tus decisiones en `SOUL.md` y se renombra con la herramienta `rename_agent`.

### Un modelo barato para las tareas menores (`utility_model`)

Algunas llamadas al modelo no son el agente pensando, son el agente ordenando la casa. Ponerle nombre a una conversación, para que la barra lateral del panel diga algo, es la primera de ellas. Apunta `utility_model` a cualquier conexión que ya tengas y esas llamadas van ahí:

```json
{
  "agents": {
    "assistant": {
      "model": "openrouter",
      "utility_model": "groq-fast"
    }
  }
}
```

`model` hace el trabajo y `utility_model` le pone nombre a la conversación. Lo mismo desde la CLI:

```bash
pepe agent add assistant --model openrouter --utility-model groq-fast
```

También está en el panel, en Agents, luego Edit, luego Chores. Y un agente que tenga la herramienta `manage_agent` puede hacerlo por chat: "haz tus tareas menores en groq-fast".

**Déjalo sin definir y las conversaciones igual reciben nombre**, a partir de las primeras palabras del mensaje de apertura. Eso es gratis, funciona sin conexión, y el primer mensaje de nadie se envía a ningún lado para que lo lean. No es mucho peor para lo que una barra lateral sirve realmente, que es que tú reconozcas la conversación. Lo que Pepe nunca hará es caer de vuelta en el modelo del propio agente, porque eso empezaría a gastar en cada instalación que solo actualizó de versión, y Pepe le carga esos tokens a una empresa. Un `utility_model` que nombra una conexión que no existe cuenta como sin definir, por el mismo motivo, y `pepe doctor` lo dice: una errata no puede ser lo que empieza a gastar.

Una advertencia sobre los niveles "gratuitos" de modelos. El texto que se envía para nombrar una conversación es el **mensaje de apertura** del cliente, que es donde viven el nombre, el teléfono y el reclamo. La mayoría de los niveles gratuitos se pagan con tus datos. Si no pondrías ese mensaje en un conjunto de entrenamiento, no apuntes `utility_model` a uno de ellos. El camino sin modelo existe precisamente para que no tengas que hacerlo.

La compactación deliberadamente no usa el modelo utilitario. Un resumen mal escrito no solo se lee mal: desinforma en silencio a cada turno que lo lee después, y el agente no tiene forma de notarlo. La prueba es la forma del fallo, no el precio: si equivocarse ahí solo se vería torpe, es una tarea menor; si dejaría equivocado al agente, no lo es.

## Los secretos quedan como referencias

La configuración vive en un archivo JSON plano en `~/.pepe/config.json`. No hay base de datos. Para mantener las credenciales fuera de ese archivo, escríbelas como referencias `${ENV_VAR}`. Pepe las interpola contra el entorno al momento de leer y nunca persiste el valor expandido.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini"
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}" }
}
```

En tiempo de ejecución la clave real se lee del entorno. En disco el archivo solo contiene el marcador. El mismo mecanismo funciona para los tokens de pasarela, los ajustes de plugins y la contraseña del panel, así que puedes versionar o compartir una configuración sin filtrar nada. Exporta las variables antes de servir:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

Un marcador de cadena completa que se resuelve en nada (la variable no está definida) se trata como "sin definir" en lugar de una cadena vacía, así que un secreto ausente aparece como un claro "no configurado" en vez de un blanco silencioso.

### Hazlo por chat

Un agente al que se le otorgan las herramientas de solo lectura `config_get` y `doctor` puede informar sobre tu configuración y detectar un secreto ausente en una conversación normal. Ambas son de solo lectura, así que nunca activan la barrera de permisos.

> Tú: ¿Está todo configurado correctamente?
>
> Agente: (ejecuta `doctor`) Encontré un problema: la conexión de modelo "openrouter" referencia `${OPENROUTER_API_KEY}`, pero esa variable no está definida en el entorno. Expórtala antes de servir.

La herramienta `doctor` hace un comprobación de salud de toda la configuración y marca secretos `${ENV}` sin definir, agentes que apuntan a modelos ausentes, programaciones inválidas y conexiones inalcanzables. Pasa `live: true` para también sondear la red.

<div class="note"><strong>Los ajustes sensibles a la seguridad no se pueden editar por chat.</strong> La herramienta protegida `config_set` está cerrada por defecto: solo toca una lista blanca corta (el modelo y el agente por defecto, el idioma, la zona horaria y un par de opciones de Telegram). Los secretos, las listas de herramientas permitidas, los tokens de bot, el envoltorio del entorno aislado y la contraseña del panel quedan a propósito fuera de esa lista, así que `config_set` no puede cambiarlos. Esos los defines tú con la CLI o el panel. Los tokens de la API son lo único que un agente puede generar por chat, pero solo a través de la herramienta separada y protegida por la barrera de permisos `manage_token`, nunca mediante `config_set`.</div>

## Almacenamiento y copias de seguridad: son todo archivos, sin base de datos

Todo vive bajo `~/.pepe/` (o bajo `PEPE_HOME`). No hay servidor de base de datos. `config.json` es la única fuente de verdad para empresas, agentes, modelos, watches, crons, bots, servidores MCP y tokens de API ya hasheados. El conocimiento de un agente vive como archivos en `agents/<name>/` y en `companies/<co>/agents/<name>/`, el historial de conversaciones en `data/sessions/`, y `data/mnesia/` es una caché desechable que se reconstruye sola. `Pepe.Repo` y Postgres existen en el código, pero están apagados (`ecto_repos: []`); son la puerta que quedó abierta para un futuro backend de base de datos, hoy sin uso.

Los secretos nunca se guardan en claro. Son referencias `${ENV_VAR}` resueltas al momento de leer, así que viven en tu entorno y no en los archivos.

Haz la copia de seguridad con un solo comando. Archiva las partes duraderas, se salta la caché desechable, y lista las variables de entorno secretas que tienes que guardar aparte, porque a propósito no van dentro del archivo:

```bash
pepe backup                       # genera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /path/x.tgz
```

Para restaurar, `pepe restore ese-archivo.tgz` y vuelve a exportar esas variables. También puedes sacar una sola empresa para que funcione en su propio servidor con `pepe extract`. Consulta [Copia de seguridad y extracción](/es/docs/backup/) para la historia completa.
