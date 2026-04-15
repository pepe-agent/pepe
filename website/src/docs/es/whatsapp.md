---
title: WhatsApp
description: Conecta webhooks de WhatsApp Cloud API a agentes de Pepe.
---

## WhatsApp

WhatsApp usa la Cloud API de Meta. Tiene una línea de comandos dedicada porque es
el canal por webhook más común. Agrega una conexión:

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
- `verify_token`: cualquier cadena que elijas. Meta la devuelve durante el saludo
  de suscripción. Si omites la opción, se usa el slug.

Si dejas fuera `--access-token` o `--app-secret`, la línea de comandos escribe
una referencia de marcador derivada del slug (por ejemplo `${WA_TOKEN_SUPPORT}`),
para que rellenes el valor real en tu entorno más tarde. El comando imprime la
URL de retorno y el token de verificación. Pega ambos en la configuración de
webhook de la app de Meta:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Gestiona conexiones:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

Las demás opciones de `whatsapp add` son `--company`, `--trainers`, `--ttl-min`,
`--ephemeral` y `--commands`, que corresponden a los campos por conexión
descritos arriba. El panel agrega y edita conexiones de WhatsApp a través de la
misma sección Channels.

<div class="note"><strong>Regla de las 24 horas.</strong> Meta solo permite
respuestas de formato libre dentro de las 24 horas del último mensaje del
usuario. El soporte reactivo encaja con esto de forma natural. Los mensajes
proactivos fuera de la ventana necesitan plantillas preaprobadas, que este canal
no envía.</div>
