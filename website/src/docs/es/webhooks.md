---
title: Webhooks
description: Configura Slack, Discord, Microsoft Teams, Google Chat y canales webhook genéricos.
---

## Cómo funciona un canal por webhook

Todo canal por webhook, sea cual sea la plataforma, es accesible en una sola
ruta:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` es el ámbito de empresa. Usa `root` para el ámbito
  predeterminado (que aparece como "Principal" en el panel), o el identificador
  de una empresa para aislar una conexión a ese empresa.
- `<provider>` es el nombre de la plataforma: `whatsapp`, `slack`, `discord`,
  `msteams` o `googlechat`.
- `<slug>` es el nombre único que le diste a la conexión.

Un `GET` a esa URL responde al saludo de verificación del proveedor (Pepe
devuelve el desafío que la plataforma envía cuando registras la URL por primera
vez). Un `POST` es un evento entrante. En un `POST`, Pepe resuelve la conexión,
verifica la firma de la petición contra el secreto que configuraste, extrae el
mensaje, ejecuta el agente vinculado y entrega la respuesta a través de la
propia API del proveedor. El trabajo del agente corre en segúndo plano para que
la plataforma reciba su acuse de inmediato (proveedores como Meta reintentan un
webhook lento).

Hay una única ruta genérica. Agregar un nuevo proveedor nunca agrega un nuevo
punto de acceso.

<div class="note"><strong>Host público.</strong> Los canales por webhook
necesitan una URL que la plataforma pueda alcanzar. Expón tu instancia de Pepe
detrás de un proxy inverso o un túnel, y define <code>PEPE_PUBLIC_URL</code> para
que las URL de retorno que imprime la línea de comandos estén completas. Para un
túnel rápido durante las pruebas, ejecuta <code>pepe serve --tunnel</code>.</div>

## Slack, Discord, Microsoft Teams, Google Chat

Estos proveedores se configuran a través de la configuración guiada (o el
panel), que pide exactamente los campos que cada uno necesita e imprime la URL de
retorno para registrar:

```bash
pepe setup
```

Elige la opción de canal, escoge el proveedor y el agente, e ingresa las
credenciales (se acepta una referencia `${ENV_VAR}` para cualquier secreto). Los
campos obligatorios de cada proveedor están abajo.

### Slack

Slack usa la Events API. El `config` de una conexión contiene:

- `bot_token`: el token OAuth del usuario bot (`xoxb-...`), usado como bearer
  para las respuestas.
- `signing_secret`: verifica el `X-Slack-Signature` en las peticiones entrantes.

En la app de Slack, define la URL de petición de Event Subscriptions con la URL
de la conexión y suscríbete a `message.channels` y `app_mention`. El primer
guardado dispara un saludo `url_verification`, que Pepe responde de inmediato.
Las respuestas se publican con `chat.postMessage`. Forma de la URL de retorno:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

### Discord

Discord se conecta a través del punto de acceso de Interactions (comandos de
barra), así que encaja en la pasarela de webhook y no en una conexión
persistente. El `config` de una conexión contiene:

- `public_key`: la clave pública de la app (hex), para la verificación de firma
  Ed25519 requerida.
- `application_id`: se usa para publicar la respuesta de seguimiento.

En la app de Discord, apunta "Interactions Endpoint URL" a la URL de la conexión
y agrega un comando de barra con una opción de texto (por ejemplo
`/ask prompt:...`). Discord exige un acuse en tres segúndos, así que Pepe
responde con una respuesta diferida y publica la respuesta real como seguimiento
una vez que el agente termina.

### Microsoft Teams

Teams usa el Bot Framework. El `config` de una conexión contiene:

- `app_id`: el id de la app (cliente) de Microsoft del bot.
- `app_password`: el secreto de cliente. Guárdalo como `${ENV_VAR}`.
- `tenant_id`: el id de empresa de Azure (o `botframework.com`).

Las actividades entrantes llegan como `POST`s. Las respuestas vuelven a la URL de
servicio de la actividad con un token de acceso de app generado a partir de las
credenciales de cliente. La mención al bot se quita del texto entrante antes de
que el agente lo vea.

### Google Chat

Google Chat publica eventos de espacio en la URL de retorno. El `config` de una
conexión contiene:

- `access_token`: un token OAuth para la Chat API, usado como bearer para las
  respuestas. Guárdalo como `${ENV_VAR}` y renuévalo por fuera.

Solo se atienden los eventos `MESSAGE` de una persona. Las respuestas se
publican de vuelta al espacio a través de la Chat REST API.

## Por dentro: el contrato del proveedor

Cada canal por webhook es un pequeño módulo que implementa el mismo contrato,
así que todos se comportan de forma coherente y una nueva plataforma es un nuevo
módulo en lugar de una nueva ruta. Las funciones de retorno son:

- `name` y `label`: el segmento de URL del proveedor y su nombre para personas.
- `config_schema`: los campos que el panel muestra para configurar una conexión.
- `verify`: responder al saludo de verificación del `GET`.
- `authenticate`: verificar la firma en un `POST` entrante contra el secreto de
  la conexión y el cuerpo crudo de la petición. Una petición que falla se
  descarta.
- `parse`: normalizar la carga de la plataforma en cero o más mensajes planos.
  Las actualizaciones de estado y los acuses de entrega se ignoran.
- `respond` (opcional): producir una respuesta síncrona cuando el protocolo
  exige una antes de cualquier trabajo del agente, como el desafío
  `url_verification` de Slack o el ping y el acuse diferido de Discord.
- `deliver`: enviar una respuesta de texto de vuelta al remitente.
- `deliver_file` (opcional): enviar un archivo como adjunto.

Si escribes un complemento que implementa este contrato, se registra como un
nuevo proveedor bajo su propio `name`, accesible en la misma ruta
`/webhooks/...` sin cableado extra.
