---
title: Editores de código
description: Conecta un agente de Pepe a tu editor mediante el Agent Client Protocol.
---

## Tu agente dentro del editor

Los editores han aprendido a hablar con agentes igual que ya hablaban con los servidores de lenguaje: arrancan un proceso pequeño en segundo plano e intercambian mensajes con él. El protocolo para eso es el [Agent Client Protocol](https://agentclientprotocol.com), un estándar abierto que no pertenece a ningún editor ni a ningún agente en concreto.

Pepe lo habla. Apuntas el editor a un comando y el agente que ya configuraste empieza a responder en el panel de conversación del propio editor, con sus herramientas, su memoria, sus habilidades y sus permisos. No se duplica nada: es el mismo agente que responde en Telegram, en el panel web y en la consola.

### Cómo arrancarlo

```bash
pepe acp                 # el agente por defecto
pepe acp soporte         # un agente concreto
pepe acp --project acme  # el agente por defecto de ese proyecto
```

Rara vez lo escribirás tú. Quien lo ejecuta es el editor, como proceso hijo, hablando con él por su entrada y su salida. Lo que configuras en el editor es esa línea de comando.

Busca en las preferencias del editor los agentes externos, personalizados o ACP e indícale el comando de arriba. Si te pide el ejecutable y los argumentos por separado, el ejecutable es `pepe` y la lista de argumentos es `["acp"]`, más el nombre del agente cuando quieras uno concreto.

**¿Lo ejecutas desde el código fuente?** Entonces el comando es `MIX_QUIET=1 mix pepe acp`. El `MIX_QUIET=1` importa: el protocolo no admite nada en la salida salvo sus propios mensajes, y sin él la línea "Compiling..." de la herramienta de compilación aterriza justo ahí y despista al editor.

### Lo que consigues

**La respuesta según se escribe.** El texto va apareciendo en el panel a medida que el agente lo redacta, igual que en la consola.

**Cada llamada a herramienta, en el momento.** Cuando el agente lee un archivo, ejecuta un comando o busca en la web, el editor muestra la llamada y después su resultado. Ves los argumentos reales, no solo el nombre de la herramienta.

**Una petición de permiso de verdad.** Esta es la parte que merece la pena. Cuando el agente quiere hacer algo que depende de tu visto bueno, el editor te pregunta ahí mismo, con el comando exacto delante y las mismas respuestas que tendrías en cualquier otro canal:

- permitir una vez
- permitir todo en esta tarea
- permitir en esta sesión
- permitir siempre
- no permitir

Tu respuesta significa exactamente lo mismo que en el resto de Pepe. "Permitir siempre" graba el mismo permiso permanente que habrías grabado respondiendo en Telegram, acotado a lo que estabas mirando de verdad y no al nombre de la herramienta. Si la tarea ha leído algo de fuera de la conversación, los permisos permanentes quedan en suspenso para ella y el agente vuelve a preguntar, y por eso cambia la respuesta recomendada en esa situación. Mira [Seguridad](../security/) para ver el alcance de cada respuesta.

**Cancelar.** Interrumpe el turno desde el editor y el agente se detiene, incluso cuando está esperando un permiso que nadie ha contestado.

**Tu conversación persiste.** Cerrar el editor no la termina. Cada conversación de ACP se guarda igual que una del panel web o de Telegram, así que el historial del editor puede listar sesiones anteriores, retomar una donde la dejaste o recuperar una que empezaste en otro directorio de proyecto. Dos ventanas del editor no pueden pisarse la misma conversación en silencio: si una ya está abierta en otro sitio, te avisa y te ofrece bifurcarla en su lugar, que sigue desde el mismo punto con un id nuevo y separado. Las sesiones que llevan 30 días sin tocarse, o las más antiguas a partir de 200, se limpian solas; ninguna que siga abierta se toca.

**Comandos con barra, dentro del propio panel.** Escribe `/status`, `/rewind 2`, `/model`, `/usage` y el resto, los mismos comandos y las mismas respuestas que tendrías en Telegram o en `mix pepe chat`: aparecen en la paleta de comandos del editor con su propia descripción. Algunos, como `/rewind` y `/undo`, reescriben la conversación y esperan a que termine un turno en marcha; otros, como `/status` y `/steer`, funcionan en cualquier momento. Cualquier cosa que escribas que no sea uno de estos va al agente como un mensaje normal.

**Un panel de plan y un medidor de contexto, cuando el agente los usa.** Una tarea de varios pasos que el agente sigue con su propia herramienta de planificación aparece como una lista de comprobación en el editor, actualizada según se completan los pasos. Después de cada respuesta, el editor también sabe cuánto de la ventana de contexto del modelo ocupa la conversación, el mismo número que imprime `/context`.

**Cambiar de modelo o cuánto puede hacer sin preguntar, a media conversación.** Los ajustes de sesión de tu propio editor (no `pepe agent add`, no `config.json`) te dejan elegir entre los modelos ya configurados para este agente, y escoger un modo de aprobación de ediciones: preguntar antes de cada cambio de archivo (el modo por defecto), dejar pasar sin preguntar las ediciones dentro del proyecto, o dejar pasar sin preguntar las ediciones en cualquier sitio. Una ruta sensible, una llamada que una política ha escalado, o cualquier cosa una vez que la conversación ha leído contenido de fuera sigue preguntando pase lo que pase el modo: los modos solo relajan la pregunta de edición de archivos, nunca ningún otro control de permiso.

**Imágenes, audio y archivos traídos al prompt con `@`.** Lo que realmente se usa depende del agente con el que hables: una imagen se le entrega tal cual a un modelo con visión y se rechaza con un motivo claro para uno que no ve; una nota de voz se transcribe si tienes configurada una vía de transcripción (mira [Voz](../voice/)); el contexto de archivo incrustado (lo que tu editor envía cuando mencionas un archivo con `@`) siempre funciona. Nada se descarta en silencio: un bloque que el agente no puede usar se te informa, no se tira.

**Servidores MCP configurados en el editor.** Si tu editor está preparado para entregarle servidores MCP al agente para este proyecto, Pepe ahora los usa solo para esa conversación: nunca se escriben en `config.json`, nunca están disponibles para otra sesión, canal o agente, y se detienen en cuanto el editor se desconecta. Un servidor que no arranca no corta la conversación; te avisa, y el resto sigue funcionando. Configúralos en el agente, con `pepe mcp add`, cuando los quieras disponibles en todos los canales a la vez. Mira [MCP](../mcp/).

### Configurar una conexión de modelo desde el propio editor

`session/new` en un agente sin una conexión de modelo utilizable falla de inmediato y le dice al editor que ofrezca autenticación, para que nunca te quedes con una conexión que abre bien y luego falla en el primer mensaje. No hay dónde iniciar sesión (Pepe se autentica ante el proveedor del modelo con su propia configuración, no con la del editor), así que lo que se ofrece de verdad es elegir entre dos formas de arreglarlo: usar las conexiones de modelo que ya tienes configuradas en Pepe, si las tienes, o abrir una terminal que ejecuta la configuración interactiva de Pepe (`pepe acp --setup`) para añadir una.

### Lo que no hace, y por qué

**Leer archivos y abrir terminales a través del editor.** El agente ya tiene herramientas propias para ambas cosas, corriendo en la misma máquina. Dar ese rodeo solo crearía un segundo juego de reglas que mantener de acuerdo con el primero.

**Preguntarte algo a media llamada de herramienta (elicitación).** Toda pregunta que Pepe necesita que responda una persona es o una petición de permiso o un mensaje en la conversación: no hay un tercer tipo de interrupción para el que montar una interfaz aparte.

### Lo que el agente puede hacer

Todo lo que el agente alcanza aquí sale de su configuración, no de la del editor. `pepe agent list` muestra las herramientas que tiene y `pepe tools` las que existen. Un agente sin `bash` tampoco ejecuta comandos desde tu editor, y uno con `bash` pregunta antes.

Si quieres para el editor un agente más estrecho que el de cada día, crea un segundo y apunta el editor a ese:

```bash
pepe agent add revisor --prompt "Revisas código. Sé breve." --tools read_file,list_dir
pepe acp revisor
```

### Mira también

- [Seguridad](../security/) explica qué concede realmente cada respuesta de permiso.
- [Agentes](../agents/) explica cómo crear y afinar el agente que atiende aquí.
- [API HTTP](../api/) es el otro camino para llegar a un agente desde tu propio programa.
