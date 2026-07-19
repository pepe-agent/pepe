---
title: Mensajes de voz
description: Una nota de voz llega como texto. La transcripción ocurre en la entrada, antes de que el agente se ejecute.
---

## Mensajes de voz

Envía una nota de voz a tu bot de Telegram y el agente recibe **texto**. El audio se
transcribe al entrar, antes de que exista una sesión y antes de cualquier decisión de
enrutado, así que lo que llega al agente es un mensaje corriente.

No siempre fue así. El gateway guardaba el fichero en el espacio de trabajo del agente y le
pasaba la ruta, dejando que el agente averiguara por su cuenta cómo escuchar: encontrar un
transcriptor, instalarlo, ejecutarlo, leer la salida. Cada nota de voz se convertía en un
pequeño proyecto de investigación. Era lento, salía distinto cada vez, y gastaba una verja
de permisos solo para leer el mensaje que acababa de llegar.

### Nada que configurar

Si ya tienes una conexión de modelo con OpenAI o con Groq, la transcripción ya funciona.
Pepe reutiliza esa credencial y le pide al provider su modelo de transcripción (`whisper-1`
en OpenAI, `whisper-large-v3-turbo` en Groq) en lugar del modelo de chat con el que se
configuró la conexión. Envía una nota de voz y se responde. No hay nada que ajustar.

### Cómo se elige la ruta

Pepe prueba estas rutas en este orden, y cualquiera de ellas puede faltar:

1. **`media.audio.model`**: una conexión de modelo, referida por su nombre. La cadena de
   `fallbacks` de esa conexión también se aplica aquí, así que el failover no cuesta nada
   extra.
2. **`media.audio.command`**: un comando local, por ejemplo `whisper-cli -f {file}`.
   `{file}` se sustituye por la ruta del audio. Esto se prueba *antes* de la detección
   automática, y es a propósito: quien configuró un transcriptor local lo hizo para que el
   audio no salga de la máquina, y saltárselo para llamar a un provider echaría por tierra
   ese propósito.
3. **Detección automática**: la ruta sin configuración descrita arriba.
4. **Nada disponible**: el fichero va al agente, que se las arregla con las herramientas que
   tiene. Esa vía queda como red de seguridad; no es la puerta de entrada.

### Configurar esto

Apunta la transcripción a una conexión de modelo concreta, o a un comando local, desde la CLI:

```bash
pepe media audio --model groq --language es --echo true
pepe media audio --command "whisper-cli -f {file}"   # mantiene el audio en la máquina
pepe media audio off                                 # vuelve a la detección automática
```

`--echo true` devuelve la transcripción al chat, para que quien habló vea qué se entendió.
Las mismas opciones están en la página Config del panel, y en `pepe setup` bajo **Media**.

### Por qué importa transcribir primero

Como las palabras existen antes de que se ejecute el enrutado, el enrutado puede leerlas. De
ahí salen dos consecuencias, ninguna posible mientras la transcripción solo aparecía dentro
del turno del agente:

- **Un comando de barra hablado se ejecuta.** Di `/help` o `/stop` en una nota de voz y el
  comando se ejecuta, igual que si lo hubieras escrito, en vez de convertirse en un turno
  del agente sobre un fichero tirado en un directorio.
- **A un bot en un grupo se le puede hablar por voz.** En un grupo que exige mención, la
  verja lee las **palabras** en lugar del pie de mensaje. Una nota de voz no lleva pie, así
  que antes de esto no había nada que la verja pudiera leer, y dirigirse al bot hablando era
  imposible.

<div class="note"><strong>El audio se vuelve texto; la foto se vuelve visión.</strong> El habla
se transcribe en la puerta. Una foto se envía al modelo como una imagen que de verdad puede ver
(en un modelo con visión, más abajo). Un documento se extrae a texto.</div>

## Responder de vuelta

Responde a una nota de voz con otra nota de voz. Apagado por defecto; apunta `media.tts` a
una conexión de modelo que sirva un `/audio/speech` compatible con OpenAI y se enciende:

```bash
pepe media tts --model openai --voice nova
pepe media tts off
```

La respuesta en texto sigue siendo el registro que queda guardado — el audio es un extra, y
tiene un límite de tamaño para que una respuesta larga nunca se convierta en un clip de
cinco minutos. Un fallo del TTS es silencioso: la respuesta en texto ya se envió, así que no
se pierde nada, solo no lleva voz ese turno. Las mismas opciones están en la página Config
del panel, y en `pepe setup` bajo **Media**.

## Fotos

Envía una foto a tu bot de Telegram y, en un **modelo con visión**, el agente ve la imagen de
verdad, no un nombre de archivo. Antes recibía solo una línea de texto («el usuario envió una
foto, guardada en `…`») mientras que la imagen en sí nunca llegaba al modelo, así que el agente
se quedaba adivinando, o inventando, qué había en ella. Ahora la imagen va junto con el mensaje.

Está desactivado a menos que digas que el modelo ve. No todos los endpoints compatibles con
OpenAI aceptan una imagen, y enviar una a un modelo solo de texto es un error, así que la visión
es opcional por conexión:

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

Con `vision` activo, una foto (con o sin pie) llega al modelo como imagen en el turno en que se
recibe. Funciona igual en conexiones compatibles con OpenAI, Anthropic y Responses/Codex. La
imagen acompaña solo ese turno: como una transcripción, el registro que queda es la respuesta
del agente sobre ella, no los bytes, así que nunca infla la sesión ni se reenvía en cada turno.
Un modelo sin `vision` vuelve al comportamiento anterior (la ruta del archivo en el prompt, para
que el agente lo abra con sus propias herramientas).

Telegram ya envía cada foto en varios tamaños preescalados, así que Pepe elige el mayor que cabe
en el tope de bytes, sin ninguna biblioteca de procesamiento de imagen que instalar. Un álbum de
fotos se envía como varias imágenes juntas. Los límites están en `media.image` y ambos tienen
valores por defecto:

- `max_mb`: la imagen más grande aceptada, en megabytes. Por defecto `5`. Una foto demasiado
  grande (o de un tipo no admitido) vuelve al prompt con la ruta del archivo.
- `max_parts`: cuántas imágenes puede llevar un turno, para álbumes. Por defecto `4`. Lo que
  pase de ahí se entrega como ruta de archivo.

```json
{
  "media": {
    "image": { "max_mb": 5, "max_parts": 4 }
  }
}
```

### Configuración

Todas las claves son opcionales y viven en `media.audio`, dentro de `~/.pepe/config.json`:

- `model`: el nombre de una conexión de modelo con la que transcribir.
- `command`: un transcriptor local. `{file}` se sustituye por la ruta del audio.
- `language`: una pista de idioma que se pasa al provider.
- `max_mb`: límite de tamaño del fichero entrante. Por defecto, `20`.
- `timeout`: cuánto puede tardar una transcripción, en segundos. Por defecto, `60`.
- `echo`: devuelve la transcripción al chat como `📝 ...`, para que quien habló compruebe
  qué se entendió.

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

Para mantener el audio en la máquina, usa un comando en lugar de una conexión:

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

### Salvaguardas

- **Un fichero por debajo de 1 KB se rechaza antes de hacer ninguna petición.** A ese tamaño
  está vacío o truncado, no callado, y ningún transcriptor diría nada útil sobre él.
  Rechazarlo no cuesta nada; enviarlo cuesta una petición.
- **Un fichero por encima de `max_mb` se rechaza igual**, antes de costar una petición.
- **Un comando atascado se abandona al cumplirse el `timeout`**, en vez de dejar colgada la
  conversación que espera detrás.
- **Un audio sin habla alguna recibe una respuesta breve**, no un turno del agente. El
  fichero se leyó, sencillamente no había nada dentro, y responder a un mensaje vacío solo
  produciría una respuesta confusa.
