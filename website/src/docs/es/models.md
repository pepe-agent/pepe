---
title: Modelos
description: Conecta proveedores compatibles con OpenAI y define modelos predeterminados y de respaldo.
---

## 3. Conectar un modelo

Apunta Pepe a cualquier endpoint compatible con OpenAI. Guarda la clave como una
referencia de entorno para que el secreto en crudo nunca acabe en el archivo de
configuración.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

Verás una confirmación como esta:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5-chat)
```

Algunas cosas que conviene saber:

- Los nombres que coinciden con un proveedor integrado, como `openrouter`, usan
  su endpoint por defecto. Usa `--base-url` solo para endpoints personalizados.
- Ejecuta `pepe model add NAME` con un nombre que no parezca proveedor para abrir
  el selector guiado. Elige un proveedor del catálogo, cómo autenticarte y luego
  elige un modelo de la lista en vivo del proveedor.
- `pepe model providers` lista los proveedores que Pepe conoce de fábrica.
- `pepe model list` muestra cada conexión guardada y marca la predeterminada.
- `pepe model test` envía una petición real mínima para confirmar que la conexión
  funciona.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5-chat)...
✓ openrouter works - reply: pong
```

El panel también puede hacer todo esto, en su pestaña Modelos, si prefieres un
formulario a la línea de comandos.

### Renombrar una conexión

```bash
pepe model rename openrouter OR-trabajo
```

Cada agente, cron y valor predeterminado que apunte a la conexión sigue
funcionando. Renombrar solo cambia el nombre visible, no el id estable con
el que cada referencia se guarda de verdad, así que no hay nada que arreglar
después.

### Cambiar de modelo en medio de una conversación

`/model` y `/models` funcionan igual en Telegram, la consola (`pepe chat`) y
el propio chat del panel. Consulta [Telegram](../telegram/) para la
referencia completa de comandos. Cualquiera en una conversación permitida
puede cambiar el modelo solo para su sesión; un entrenador (la misma lista
que rige `/learn`) también puede cambiarlo para todos.

## La conexión de modelo

`model` nombra una conexión que definiste con `pepe model add`. Dejarlo sin definir
significa que el agente usa el modelo predeterminado de su alcance, así que puedes
apuntar todo un conjunto de agentes a un proveedor y cambiarlos todos modificando un
solo predeterminado.

Una conexión de modelo puede llevar una cadena de respaldo. Cuando el modelo
primario del agente falla con un error transitorio (un límite de tasa, un tiempo de
espera agotado, un corte de red o un 5xx), el runtime baja por la cadena y reintenta
con el siguiente modelo, emitiendo un evento `failover` mientras lo hace. Un error
grave como una clave de API incorrecta o una petición mal formada falla de inmediato,
ya que otro endpoint no lo arreglaría.

Pepe habla con los proveedores mediante el protocolo Chat Completions de OpenAI, así
que cualquier endpoint compatible con OpenAI funciona sin cambiar código.

Una sesión también puede bajar sola a un modelo más barato automáticamente, en su
propio primer turno, cuando una llamada de triaje rápida juzga que la
conversación es lo bastante simple. Mira [Enrutamiento de modelo por complejidad](../agents/#enrutamiento-de-modelo-por-complejidad).

### Hazlo por chat

Un agente con la herramienta `manage_agent` puede reapuntar un modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

El agente llama a `manage_agent` con `action: "set_model"`. El modelo destino debe
ser una conexión configurada, y el cambio pasa por la barrera de permisos como
cualquier otra edición de configuración.
