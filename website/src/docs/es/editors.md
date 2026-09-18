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

### Lo que no hace, y por qué

Pepe implementa el núcleo del protocolo y avisa, en el saludo inicial, de qué partes se ha dejado fuera, para que el editor nunca te ofrezca algo que no va a funcionar:

**Retomar una conversación anterior.** La sesión vive mientras el editor mantenga el proceso en pie. Cierras el editor y se acabó. Las conversaciones de larga vida viven en los canales pensados para eso.

**Iniciar sesión.** No hay dónde. Pepe se autentica ante el proveedor del modelo con su propia configuración.

**Imagen, audio y adjuntos en el prompt.** Solo texto, por ahora. Aun así puedes señalarle un archivo al agente mencionando su ruta: lo lee él mismo.

**Servidores MCP configurados en el editor.** Si tu editor está preparado para entregarle servidores MCP al agente, Pepe los rechaza en vez de aceptarlos y luego no usarlos sin decirlo. Configúralos en el agente, con `pepe mcp add`, y valen en todos los canales a la vez. Mira [MCP](../mcp/).

**Leer archivos y abrir terminales a través del editor.** El agente ya tiene herramientas propias para ambas cosas, corriendo en la misma máquina. Dar ese rodeo solo crearía un segundo juego de reglas que mantener de acuerdo con el primero.

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
