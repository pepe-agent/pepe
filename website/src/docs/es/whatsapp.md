---
title: WhatsApp
description: Conecta webhooks de WhatsApp Cloud API a agentes de Pepe.
---

## WhatsApp

WhatsApp usa la Cloud API de Meta. A diferencia de Telegram, al que Pepe
consulta, WhatsApp **empuja** los mensajes entrantes hacia un webhook, así que
cada conexión recibe su propia URL en la ruta de entrada genérica de Pepe:

```
/webhooks/:company/:provider/:slug        p. ej.  /webhooks/acme/whatsapp/support
```

Esa ruta es una superficie de webhook genérica, apoyada en un registro de
proveedores, y no una tubería específica de WhatsApp. El segmento `:company` es
`root` cuando no usas empresas. Un `GET` en esa URL responde al handshake de
verificación de Meta. Un `POST` es un mensaje entrante: su `X-Hub-Signature-256`
se verifica contra el app secret, luego se ejecuta el agente vinculado y la
respuesta vuelve por la Graph API. `pepe serve` sirve esta ruta, así que no hay
ningún proceso extra que ejecutar.

Puedes tener tantas conexiones como quieras, cada una vinculada a su propio
agente. Es el equivalente por webhook de los varios bots de Telegram.

WhatsApp tiene una línea de comandos dedicada porque es el canal por webhook más
común. Añade una conexión:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

Las credenciales de la conexión (guardadas bajo su `config`):

- `phone_number_id`: el id del punto de envío desde la app de Meta.
- `access_token`: el token bearer de la Graph API. Guárdalo como `${ENV_VAR}`.
- `app_secret`: verifica el `X-Hub-Signature-256` entrante. Guárdalo como
  `${ENV_VAR}`.
- `verify_token`: cualquier cadena que elijas. Meta la devuelve durante el
  handshake de suscripción. Si omites la opción, se usa el slug.

Si dejas fuera `--access-token` o `--app-secret`, la línea de comandos escribe
una referencia de marcador derivada del slug (por ejemplo `${WA_TOKEN_SUPPORT}` y
`${WA_APP_SECRET_SUPPORT}`), para que rellenes el valor real en tu entorno más
tarde. El comando imprime la URL de retorno y el token de verificación. Pega
ambos en la configuración de webhook de la app de Meta y suscribe el campo
`messages`, para que Meta entregue de verdad los mensajes entrantes:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Gestiona conexiones:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

`whatsapp list` imprime cada conexión con su URL de retorno. Las demás opciones
de `whatsapp add` son `--company`, `--trainers`, `--ttl-min`, `--ephemeral` y
`--commands`, que corresponden a los campos por conexión descritos arriba. El
panel añade y edita conexiones de WhatsApp a través de la misma sección Channels.

### Del lado de Meta

Una vez por número, en tu app de Meta:

1. Crea una app y añádele el producto WhatsApp.
2. Anota el `phone_number_id` del número que estás conectando.
3. Genera un token de acceso permanente y ponlo en tu entorno como
   `${WA_TOKEN_<SLUG>}`.
4. Copia el App Secret y ponlo en tu entorno como `${WA_APP_SECRET_<SLUG>}`.
5. Apunta la Callback URL al slug de tu conexión, escribe el token de
   verificación y suscribe el campo `messages`.

### Los dos modos

El `--mode` de la conexión decide cuánto de Pepe queda expuesto. La comparación
completa está en [Canales](../channels/); para un número de WhatsApp se reduce a
esto:

| | **admin** (el tuyo) | **support** (de cara al cliente) |
|---|---|---|
| Comandos de barra | Activos (`/new` reinicia) | Desactivados, tratados como texto plano |
| Quién puede escribir | `allowed_numbers`, tu propio número | Cualquiera |
| ¿Aprende? (`trainers`) | Tú eres entrenador | `[]`, así que nunca aprende de un cliente |
| Herramientas del agente | Completas | Mantenlas restringidas: solo herramientas seguras, ya que no hay una persona que apruebe una acción arriesgada |
| Sesión | Se conserva | Efímera, más un TTL de inactividad |

### La sesión

La sesión se indexa como `whatsapp:<agent>:<phone>`. Es el hilo del agente con
ese cliente concreto, aislado por empresa a través del handle del agente. Dos
cosas la terminan:

- El agente llama a la herramienta **`end_session`** cuando el intercambio
  termina, lo que limpia el contexto para que el siguiente mensaje del cliente
  empiece desde cero.
- El **TTL de inactividad** (`--ttl-min`, ausente significa nunca) desaloja una
  conversación que se quedó quieta.

Pasar una conversación a un especialista no necesita maquinaria extra: el agente
simplemente llama a `send_to_agent`. Ver [Enrutamiento](../routing/).

<div class="note"><strong>Regla de las 24 horas.</strong> Meta solo permite
respuestas de formato libre dentro de las 24 horas del último mensaje del
usuario. El soporte reactivo encaja con esto de forma natural. Los mensajes
proactivos fuera de la ventana necesitan plantillas preaprobadas, que este canal
no envía.</div>

### Cambiar de modelo

`/model` y `/models` solo se activan en una conexión en modo `admin` (ver la
comparación de modos arriba); en `support`, son texto plano como cualquier otro
comando de barra. `/models` lista los modelos disponibles para la empresa de esta
conexión; `/model` muestra el que está activo, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquiera en una conversación permitida puede cambiar su propia sesión;
cambiarlo **globalmente** está reservado para **entrenadores**, la misma
lista que rige la memoria. Pon `model_switch_locked: true` en la conexión para
desactivar el cambio de modelo por completo para quien no sea entrenador.
WhatsApp no tiene un selector con botones como el de Telegram; aquí es solo
escrito.
