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

Eso imprime la ruta de la configuración y un resumen de lo que está definido.

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

La herramienta `doctor` hace un chequeo de salud de toda la configuración y marca secretos `${ENV}` sin definir, agentes que apuntan a modelos ausentes, programaciones inválidas y conexiones inalcanzables. Pasa `live: true` para también sondear la red.

<div class="note"><strong>Los ajustes sensibles a la seguridad no se pueden editar por chat.</strong> La herramienta protegida `config_set` está cerrada por defecto: solo toca una lista blanca corta (el modelo y el agente por defecto, el idioma, la zona horaria y un par de opciones de Telegram). Los secretos, las listas de herramientas permitidas, los tokens de bot, el envoltorio del entorno aislado y la contraseña del panel quedan a propósito fuera de esa lista, así que `config_set` no puede cambiarlos. Esos los defines tú con la CLI o el panel. Los tokens de la API son lo único que un agente puede generar por chat, pero solo a través de la herramienta separada y protegida por la barrera de permisos `manage_token`, nunca mediante `config_set`.</div>
