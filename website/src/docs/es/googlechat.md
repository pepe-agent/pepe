---
title: Google Chat
description: Pon un agente de Pepe en Google Chat para que tu equipo hable con él en espacios y mensajes directos.
---

## Google Chat

Conectar Google Chat permite que la gente hable con el agente en sus espacios
y mensajes directos. Google Chat entrega cada mensaje en la URL de retorno de
Pepe; configura la conexión mediante la configuración guiada (o el panel):

```bash
pepe setup
```

El `config` de una conexión contiene:

- `access_token`: un token OAuth para la Chat API, usado como bearer para las
  respuestas. Guárdalo como `${ENV_VAR}` y renuévalo por fuera.
- `project_number`: el número del proyecto de Cloud en el que está
  registrada la app de Chat. En la página de configuración de la app de
  Chat, pon **Authentication Audience** en **Project Number**. La otra
  opción (HTTP endpoint URL) envía un token con forma distinta que Pepe no
  valida, así que se rechazaría todo mensaje entrante.

Solo se atienden los eventos `MESSAGE` de una persona. Las respuestas se
publican de vuelta al espacio a través de la Chat REST API. Forma de la URL de
retorno:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Autenticación de entrada

Pepe comprueba que cada solicitud entrante viene de verdad de Google antes de
que el agente vea nada: cada solicitud trae un token firmado por Google en
`Authorization: Bearer`, y Pepe lo valida (firma contra las claves publicadas
por Google, emisor y una audiencia igual a `project_number`). Así el endpoint
acepta `POST`s directamente desde Google, sin necesidad de un proxy que
valide. Si tu proxy ya hace esa comprobación, pon `trust_proxy: true` en la
conexión para saltarte la de Pepe.

Ver [Webhooks](../webhooks/) para los campos que comparte toda conexión
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) y
cómo funciona la ruta genérica por dentro.

### Cambiar de modelo

Los comandos `/model` y `/models` permiten ver o cambiar el modelo de IA que
responde. Solo funcionan en una conexión en modo `admin` con `commands`
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
