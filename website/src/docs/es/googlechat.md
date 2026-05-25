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

Solo se atienden los eventos `MESSAGE` de una persona. Las respuestas se
publican de vuelta al espacio a través de la Chat REST API. Forma de la URL de
retorno:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

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
