---
title: WhatsApp
description: Pon un agente de Pepe detrás de tu número de WhatsApp, usando la Cloud API de Meta.
---

## WhatsApp

WhatsApp funciona con la Cloud API de Meta. A diferencia de Telegram, donde es Pepe el que va a buscar los mensajes, en WhatsApp cada mensaje entrante **llega solo** a una dirección de tu propio servidor, así que Pepe necesita ser accesible desde internet. Cada conexión recibe su propia URL dentro de la ruta de entrada de Pepe:

```
/webhooks/:project/:provider/:slug        p. ej.  /webhooks/acme/whatsapp/support
```

El segmento `:project` es `default` si no estás usando proyectos adicionales. Pepe mismo responde el handshake de verificación de Meta en esa URL, y cada mensaje entrante pasa antes por una comprobación de su firma `X-Hub-Signature-256` contra el app secret, antes incluso de que corra el agente vinculado, así que una petición falsificada nunca llega a tocar al agente. La respuesta se manda de vuelta por la Graph API. Como `pepe serve` ya sirve esta ruta, no hace falta correr ningún proceso aparte.

Puedes tener tantas conexiones como quieras, cada una atada a su propio agente. Es exactamente la misma lógica que correr varios bots de Telegram.

WhatsApp cuenta con su propia línea de comandos porque es, de lejos, el canal por webhook más usado. Para agregar una conexión:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

Las credenciales de la conexión (guardadas dentro de su `config`):

- `phone_number_id`: el id del punto de envío que te da la app de Meta.
- `access_token`: el token bearer de la Graph API. Guárdalo como `${ENV_VAR}`.
- `app_secret`: es lo que verifica el `X-Hub-Signature-256` entrante. Guárdalo también como `${ENV_VAR}`.
- `verify_token`: cualquier cadena que elijas tú. Meta la devuelve durante el handshake de suscripción. Si no pasas esta opción, se usa el slug.

Si dejas `--access-token` o `--app-secret` sin poner, la CLI escribe en su lugar una referencia derivada del slug (por ejemplo, `${WA_TOKEN_SUPPORT}` y `${WA_APP_SECRET_SUPPORT}`), para que después completes el valor real en tu entorno. El comando imprime la URL de retorno y el token de verificación; pega ambos en la configuración de webhook de tu app de Meta, y suscribe el campo `messages` para que Meta empiece a entregarte de verdad los mensajes entrantes:

```
https://YOUR_HOST/webhooks/default/whatsapp/support
```

Para administrar conexiones:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

`whatsapp list` imprime cada conexión junto con su URL de retorno. Las demás opciones de `whatsapp add` son `--project`, `--trainers`, `--ttl-min`, `--ephemeral` y `--commands`, que corresponden a los campos por conexión descritos arriba. El panel también permite agregar y editar conexiones de WhatsApp, desde esa misma sección Channels.

### Del lado de Meta

Una vez por número, dentro de tu app de Meta:

1. Crea una app y agrégale el producto WhatsApp.
2. Anota el `phone_number_id` del número que vas a conectar.
3. Genera un token de acceso permanente y guárdalo en tu entorno como `${WA_TOKEN_<SLUG>}`.
4. Copia el App Secret y guárdalo en tu entorno como `${WA_APP_SECRET_<SLUG>}`.
5. Configura la Callback URL con el slug de tu conexión, escribe el token de verificación, y suscribe el campo `messages`.

### Los dos modos

El `--mode` de la conexión decide cuánto de Pepe queda a la vista. La comparación completa está en [Canales](../channels/); para un número de WhatsApp se resume así:

| | **admin** (el tuyo) | **support** (de cara al cliente) |
|---|---|---|
| Comandos de barra | Activos (`/new` reinicia) | Apagados, se tratan como texto plano |
| Quién puede escribirle | `allowed_numbers`, tu propio número | Cualquiera |
| ¿Aprende? (`trainers`) | Tú eres el entrenador | `[]`, así que nunca aprende de un cliente |
| Herramientas del agente | Completas | Consérvalas restringidas, solo herramientas seguras, porque no hay nadie ahí que apruebe una acción riesgosa |
| Sesión | Se conserva | Efímera, con un TTL de inactividad |

### La sesión

La sesión se identifica como `whatsapp:<agent>:<phone>`. Es el hilo del agente con ese cliente en particular, aislado por proyecto a través del handle del agente. Dos cosas la terminan:

- Que el agente llame a la herramienta **`end_session`** cuando da por cerrado el intercambio, lo que limpia el contexto para que el próximo mensaje del cliente arranque desde cero.
- El **TTL de inactividad** (`--ttl-min`; si no lo defines, nunca expira), que desaloja una conversación que quedó en silencio.

Pasarle una conversación a un especialista no necesita ninguna maquinaria adicional: el agente simplemente llama a `send_to_agent`. Ver [Enrutamiento](../routing/).

<div class="note"><strong>La regla de las 24 horas.</strong> Meta solo permite respuestas de formato libre dentro de las 24 horas siguientes al último mensaje del usuario. El soporte reactivo encaja bien ahí de forma natural. Los mensajes proactivos fuera de esa ventana necesitan plantillas preaprobadas, que este canal no envía.</div>

### Notas de voz, fotos y archivos

Una nota de voz llega como **texto**: se transcribe al entrar, antes de que el agente corra, así que quien hace la pregunta hablando recibe una respuesta a la pregunta y no un comentario sobre un archivo de audio. Un PDF o una planilla llegan con el contenido ya leído, junto a lo que se dijo sobre ellos. Una foto le llega al modelo como imagen, cuando el modelo del agente tiene visión.

Nada de esto pide credenciales nuevas. Meta entrega un id de medio y Pepe lo resuelve contra la Graph API con el mismo token de acceso que la conexión ya usa. Meta limita el medio entrante por tipo (16 MB para audio y video, 5 MB para imágenes, 100 MB para documentos), y Pepe aplica su propio límite de 20 MB encima, así que gana el menor de los dos. Si no hay ninguna ruta de transcripción configurada ni deducible, el archivo queda en el workspace del agente y se le avisa dónde está. Ver [Mensajes de voz](../voice/) y [Documentos](../documents/).

### Cambiar de modelo

`/model` y `/models` solo funcionan en una conexión con modo `admin` (ver la comparación de modos más arriba); en modo `support` son texto plano, como cualquier otro comando de barra. `/models` lista los modelos disponibles para el proyecto de esta conexión; `/model` muestra el que está activo, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo esta conversación
/model openrouter global        # cambia para todas las conversaciones de esta conexión
```

Cualquiera en una conversación permitida puede cambiar su propia sesión; cambiarlo **globalmente** queda reservado a los **entrenadores**, la misma lista que controla la memoria. Pon `model_switch_locked: true` en la conexión si quieres apagar el cambio de modelo por completo para quien no sea entrenador. A diferencia de Telegram, WhatsApp no tiene selector con botones: aquí todo se escribe.
