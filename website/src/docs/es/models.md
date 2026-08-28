---
title: Modelos
description: Conecta Pepe a cualquier proveedor de modelos compatible con OpenAI, elige uno por defecto y agrega respaldos que entren en acción cuando un proveedor tenga un mal momento.
---

## 3. Conectar un modelo

Pepe funciona con cualquier proveedor que hable el protocolo de OpenAI. Dale tu clave como el nombre de una variable de entorno, para que la clave en sí nunca quede escrita en el archivo de configuración.

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

Algunas cosas que conviene tener presentes:

- Un nombre que coincide con un proveedor integrado, como `openrouter`, usa el endpoint por defecto de ese proveedor. Usa `--base-url` solo para endpoints personalizados.
- Ejecuta `pepe model add NOMBRE` con un nombre que no sea el de un proveedor conocido para abrir el selector guiado: elige un proveedor del catálogo, cómo autenticarte, y luego un modelo de la lista en vivo de ese proveedor.
- `pepe model providers` lista los proveedores que Pepe reconoce de fábrica.
- `pepe model list` muestra cada conexión guardada y marca cuál es la predeterminada.
- `pepe model test` manda una petición real mínima para confirmar que la conexión funciona.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5-chat)...
✓ openrouter works - reply: pong
```

El panel puede hacer todo esto también, en su pestaña Modelos, si prefieres un formulario a la línea de comandos.

### Renombrar una conexión

```bash
pepe model rename openrouter OR-trabajo
```

Cada agente, cron o valor predeterminado que apunte a esa conexión sigue funcionando sin problema: renombrar solo cambia el nombre visible, no el id estable contra el que en realidad se guarda cada referencia, así que no queda nada por arreglar después.

### Cambiar de modelo en plena conversación

`/model` y `/models` funcionan igual en Telegram, en la consola (`pepe chat`) y en el propio chat del panel; consulta [Telegram](../telegram/) para la referencia completa de comandos. Cualquiera dentro de una conversación permitida puede cambiar el modelo solo para su propia sesión; un entrenador (la misma lista de confianza que rige `/learn`) también puede cambiarlo para todos.

## La conexión de modelo

`model` nombra una conexión que definiste con `pepe model add`. Dejarlo sin definir hace que el agente use el modelo predeterminado de su proyecto, así que puedes apuntar todo un grupo de agentes a un mismo proveedor y cambiarlos a todos de una vez modificando un único valor por defecto.

Una conexión de modelo puede llevar una cadena de respaldo. Cuando el modelo principal del agente falla con un error pasajero (un límite de tasa, un tiempo de espera agotado, un corte de red o un 5xx), Pepe baja por la cadena y reintenta con el siguiente modelo, emitiendo un evento `failover` en el proceso. Un error grave, como una clave de API incorrecta o una petición mal formada, falla de inmediato en lugar de reintentar, porque cambiar de endpoint no lo arreglaría de todos modos.

Pepe habla con los proveedores mediante el protocolo Chat Completions de OpenAI, así que cualquier endpoint compatible con OpenAI funciona sin tocar una línea de código.

Una sesión también puede bajarse sola a un modelo más barato de forma automática, en su primer turno, cuando una llamada rápida de triaje juzga que la conversación es lo bastante simple como para justificarlo. Mira [Enrutamiento de modelo por complejidad](../agents/#enrutamiento-de-modelo-por-complejidad).

### Hazlo por chat

Un agente con la herramienta `manage_agent` puede reapuntar un modelo que administra:

```text
Point the researcher agent at the groq-fast model.
```

El agente llama a `manage_agent` con `action: "set_model"`. El modelo de destino debe ser una conexión ya configurada, y el cambio pasa por la barrera de permisos como cualquier otra edición de configuración.
