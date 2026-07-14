---
title: Google Chat
description: Conecta una app de Google Chat a un agente de Pepe.
---

## Google Chat

Google Chat publica eventos de espacio en la URL de retorno. Configúralo
mediante la configuración guiada (o el panel):

```bash
pepe setup
```

El `config` de una conexión contiene:

- `access_token`: un token OAuth para la Chat API, usado como bearer para las
  respuestas. Guárdalo como `${ENV_VAR}` y renuévalo por fuera.
- `project_number`: el número del proyecto de Cloud en el que está
  registrada la app de Chat. En la página de configuración de la app de
  Chat, pon **Authentication Audience** en **Project Number** — la otra
  opción (HTTP endpoint URL) envía un token con forma distinta que Pepe no
  valida, y se rechazaría todo mensaje entrante.

Solo se atienden los eventos `MESSAGE` de una persona. Las respuestas se
publican de vuelta al espacio a través de la Chat REST API. Forma de la URL de
retorno:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Autenticación de entrada

Cada solicitud entrante trae un token firmado por Google en `Authorization:
Bearer`, y Pepe lo valida (firma contra las claves publicadas por Google,
emisor, y un audience igual a `project_number`) antes de que el agente vea
nada. Así el endpoint acepta `POST`s directo de Google — sin necesitar un
proxy validador. Si tu proxy ya hace esa comprobación, pon `trust_proxy: true`
en la conexión para saltarte la de Pepe.

Ver [Webhooks](../webhooks/) para los campos que comparte toda conexión
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) y
cómo funciona la ruta genérica por dentro.

### Cambiar de modelo

`/model` y `/models` solo se activan en una conexión en modo `admin` con
`commands` habilitado; en `support`, son texto plano. `/models` lista los
modelos disponibles para el proyecto de esta conexión; `/model` muestra el
actual, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquiera en una conversación permitida puede cambiar su propia sesión;
cambiarlo **globalmente** está reservado para **entrenadores**, la misma
lista que rige la memoria. Pon `model_switch_locked: true` en la conexión para
desactivar el cambio de modelo por completo para quien no sea entrenador.
