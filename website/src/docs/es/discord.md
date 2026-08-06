---
title: Discord
description: Responde comandos de barra en tu servidor de Discord con un agente de Pepe.
---

## Discord

En Discord, la gente habla con el agente mediante un comando de barra (por
ejemplo, `/ask`). Discord entrega esos comandos por su punto de acceso de
Interactions, que encaja en la pasarela de webhook de Pepe y no en una
conexión persistente. Configúralo mediante la configuración guiada (o el
panel):

```bash
pepe setup
```

El `config` de una conexión contiene:

- `public_key`: la clave pública de la app (hex), para la verificación de firma
  Ed25519 requerida.
- `application_id`: se usa para publicar la respuesta de seguimiento.

En la app de Discord, apunta "Interactions Endpoint URL" a la URL de la conexión
y añade un comando de barra con una opción de texto (por ejemplo
`/ask prompt:...`). Discord exige un acuse en tres segundos, así que Pepe
responde con una respuesta diferida y publica la respuesta real como seguimiento
una vez que el agente termina. Forma de la URL de retorno:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Ver [Webhooks](../webhooks/) para los campos que comparte toda conexión
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) y
cómo funciona la ruta genérica por dentro.

### Cambiar de modelo

Los comandos `/model` y `/models` permiten ver o cambiar el modelo de IA que
responde. En Discord llegan a Pepe a través del comando que registraste
(`/ask` arriba): lo que escribas en su opción `prompt:` es el mensaje que
Pepe ve. Solo funcionan en una conexión en modo `admin` con `commands`
habilitado; en `support`, se tratan como texto normal. `/models` lista los
modelos disponibles para el proyecto de esta conexión; `/model` muestra el
actual, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquiera en una conversación permitida puede cambiar el modelo de su propia
conversación. Cambiarlo **globalmente**, para todos con los que habla esta
conexión, está reservado a los **entrenadores**, la misma lista de confianza
que rige la memoria. Pon `model_switch_locked: true` en la conexión para
desactivar el cambio de modelo por completo para quien no sea entrenador.
