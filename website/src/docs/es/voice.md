---
title: Mensajes de voz
description: Una nota de voz llega convertida en texto. La transcripción ocurre a la entrada, antes de que el agente entre en juego.
---

## Mensajes de voz

Manda una nota de voz por Telegram o WhatsApp, o por Discord (como adjunto de un comando de barra, o hablada directo en un canal que el bot escuche), y lo que recibe el agente es **texto**. El audio se transcribe al llegar, antes de que exista una sesión y antes de tomar cualquier decisión de enrutado, así que al agente le llega un mensaje corriente y silvestre.

No siempre funcionó así. Antes, el gateway guardaba el archivo en el workspace del agente y le pasaba la ruta, dejando que el agente resolviera por su cuenta cómo "escucharlo": buscar un transcriptor, instalarlo, correrlo, leer la salida. Cada nota de voz se volvía un pequeño proyecto de investigación. Era lento, salía distinto cada vez, y encima gastaba un aviso de permiso solo por el hecho de leer el mensaje recién llegado.

### No hay nada que configurar

Si ya tienes una conexión de modelo con OpenAI o con Groq, la transcripción ya funciona sola. Pepe reutiliza esa misma credencial y le pide al proveedor su modelo de transcripción (`whisper-1` en OpenAI, `whisper-large-v3-turbo` en Groq) en vez del modelo de chat con el que configuraste esa conexión. Manda una nota de voz y te responde, sin ningún ajuste previo.

### En qué canales funciona

**Telegram, WhatsApp y Discord** hacen pasar un adjunto por la misma puerta: el audio se convierte en transcripción, un documento en texto, y una imagen llega como imagen a un modelo con visión. Los ajustes de esta página valen para los tres, así que configurar la transcripción una vez alcanza para todos.

Dos detalles que conviene tener presentes:

- En **WhatsApp** lo que llega es un id de medio, no el archivo. Pepe lo resuelve contra la Graph API con el mismo token de acceso que la conexión ya usa, sin configuración adicional. Meta limita el medio entrante por tipo (16 MB para audio, 5 MB para imágenes, 100 MB para documentos), y el propio límite de 20 MB de Pepe aplica encima.
- En **Discord** hay dos caminos separados, y una conexión puede ofrecer uno, el otro, o ambos. La **opción de adjunto** de un comando de barra funciona en cualquier conexión: dale a tu comando una opción de adjunto y `/ask file:<clip>` funciona, con o sin texto escrito al lado. Una nota de voz grabada directo en un canal, o mandada por DM, necesita el opt-in `--gateway`/`--bot-token` de la conexión (ver [Discord](../discord/)); sin eso, ese mensaje nunca le llega a Pepe y no hay manera de transcribirlo.

Slack, Microsoft Teams y Google Chat siguen recibiendo solo texto.

### Cómo elige la ruta

Pepe prueba en este orden, y cualquiera de estas opciones puede faltar:

1. **`media.audio.model`**: una conexión de modelo, referida por su nombre. La cadena de `fallbacks` propia de esa conexión también aplica aquí, así que el failover no cuesta nada extra.
2. **`media.audio.command`**: un comando local, como `whisper-cli -f {file}`, donde `{file}` se reemplaza por la ruta del audio. Este se intenta *antes* que la detección automática, y es a propósito: si alguien configuró un transcriptor local fue justamente para que el audio no saliera de la máquina, y saltárselo para llamar a un proveedor externo echaría por tierra ese propósito.
3. **Detección automática**: la ruta sin configuración que se describe arriba.
4. **Nada disponible**: el archivo pasa directo al agente, que se las arregla con las herramientas que tenga. Esta vía se mantiene como red de seguridad, no como la entrada normal.

### Configurarlo

Puedes apuntar la transcripción a una conexión de modelo específica, o a un comando local, desde la CLI:

```bash
pepe media audio --model groq --language es --echo true
pepe media audio --command "whisper-cli -f {file}"   # mantiene el audio dentro de la máquina
pepe media audio off                                 # vuelve a la detección automática
```

`--echo true` devuelve la transcripción al chat, así quien habló puede confirmar que se entendió bien. Los mismos ajustes están en la página Config del panel, y en `pepe setup` bajo **Media**.

### Por qué importa transcribir primero

Como el texto ya existe antes de que corra el enrutado, el enrutado puede leerlo. De ahí salen dos cosas que antes eran imposibles, cuando la transcripción solo aparecía dentro del turno del agente:

- **Un comando de barra dicho en voz alta se ejecuta de verdad.** Di "/help" o "/stop" en una nota de voz y el comando corre, igual que si lo hubieras escrito, en vez de volverse un turno del agente sobre un archivo perdido en algún directorio.
- **A un bot dentro de un grupo se le puede hablar directamente.** En un grupo que exige mención, el filtro lee las **palabras**, no el pie de foto. Una nota de voz no lleva pie de foto, así que antes no había nada que el filtro pudiera leer, y era imposible dirigirse al bot hablando.

<div class="note"><strong>El audio se convierte en texto; la foto se convierte en algo que se ve.</strong> El habla se transcribe justo a la entrada. Una foto se le manda al modelo como una imagen que de verdad puede ver (en un modelo con visión, más abajo). Un documento se extrae a texto.</div>

## Responder también con voz

Puedes responder a una nota de voz con otra nota de voz. Viene apagado por defecto; apunta `media.tts` a una conexión de modelo que sirva un `/audio/speech` compatible con OpenAI y se activa:

```bash
pepe media tts --model openai --voice nova
pepe media tts off
```

El registro que queda guardado sigue siendo la respuesta en texto. El audio es un añadido, con un límite de duración para que una respuesta larga jamás se convierta en un clip de cinco minutos. Si el TTS falla, falla en silencio: la respuesta en texto ya se mandó, así que no se pierde nada, simplemente ese turno se queda sin voz. Los mismos ajustes están en la página Config del panel, y en `pepe setup` bajo **Media**.

## Fotos

Manda una foto por Telegram, WhatsApp o Discord y, si el modelo tiene **capacidad de visión**, el agente ve la imagen de verdad, no solo un nombre de archivo. Antes recibía apenas una línea de texto ("el usuario mandó una foto, guardada en `…`") mientras que la imagen en sí nunca llegaba al modelo, así que el agente terminaba adivinando, o directamente inventando, qué había en ella. Ahora la imagen viaja junto con el mensaje.

Está desactivado a menos que le digas explícitamente al sistema que el modelo puede ver. No todos los endpoints compatibles con OpenAI aceptan imágenes, y mandarle una a un modelo de solo texto es un error, así que la visión se activa por conexión:

```json
{
  "models": {
    "gpt4o": {
      "base_url": "https://api.openai.com/v1",
      "api_key": "${OPENAI_API_KEY}",
      "model": "gpt-4o",
      "vision": true
    }
  }
}
```

Con `vision` activado, una foto (con o sin pie de foto) le llega al modelo como imagen en el mismo turno en que se recibe. Funciona igual en conexiones compatibles con OpenAI, Anthropic y Responses/Codex. La imagen viaja solo en ese turno puntual: igual que con una transcripción, lo que queda como registro es la respuesta del agente sobre ella, no los bytes en sí, así que nunca infla la sesión ni se reenvía turno tras turno. Un modelo sin `vision` cae de vuelta al comportamiento anterior (la ruta del archivo en el prompt, para que el agente la abra con sus propias herramientas).

Telegram ya manda cada foto en varios tamaños preescalados, así que Pepe elige la más grande que quepa dentro del límite de bytes, sin necesitar ninguna biblioteca de procesamiento de imágenes. Un álbum de fotos se manda como varias imágenes juntas. Los límites viven bajo `media.image`, y ambos tienen valores por defecto:

- `max_mb`: el tamaño máximo aceptado por imagen, en megabytes. Por defecto, `5`. Una foto que se pase de ese tamaño (o de un tipo no admitido) cae de vuelta al prompt con la ruta del archivo.
- `max_parts`: cuántas imágenes puede llevar un mismo turno, para álbumes. Por defecto, `4`. Lo que sobrepase ese número se entrega como ruta de archivo.

```json
{
  "media": {
    "image": { "max_mb": 5, "max_parts": 4 }
  }
}
```

### Configuración

Todas las claves son opcionales y viven bajo `media.audio`, dentro de `~/.pepe/config.json`:

- `model`: el nombre de la conexión de modelo con la que transcribir.
- `command`: un transcriptor local. `{file}` se reemplaza por la ruta del audio.
- `language`: una pista de idioma que se le pasa al proveedor.
- `max_mb`: límite de tamaño para un archivo entrante. Por defecto, `20`.
- `timeout`: cuánto puede tardar una transcripción, en segundos. Por defecto, `60`.
- `echo`: devuelve la transcripción al chat con el formato `📝 ...`, para que quien habló pueda revisar qué se entendió.

```json
{
  "media": {
    "audio": {
      "model": "groq",
      "language": "es",
      "max_mb": 20,
      "timeout": 60,
      "echo": true
    }
  }
}
```

Para mantener el audio dentro de la máquina, usa un comando en lugar de una conexión:

```json
{
  "media": {
    "audio": {
      "command": "whisper-cli -f {file}",
      "timeout": 120
    }
  }
}
```

### Resguardos

- **Un archivo de menos de 1 KB se rechaza sin siquiera hacer la petición.** A ese tamaño, lo más probable es que esté vacío o truncado, y ningún transcriptor tendría nada útil que decir sobre él. Rechazarlo no cuesta nada; mandarlo sí cuesta una petición.
- **Un archivo que supere `max_mb` se rechaza de la misma manera**, antes de generar ningún gasto.
- **Un comando que se traba se abandona al cumplirse el `timeout`**, en vez de dejar la conversación colgando detrás de él.
- **Un audio sin ninguna voz recibe una respuesta corta**, no un turno completo del agente. El archivo se leyó bien, simplemente no tenía nada adentro, y contestarle a un mensaje vacío solo produciría una respuesta confusa.
