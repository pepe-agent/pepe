---
title: Microsoft Teams
description: Conecta un bot de Microsoft Teams a un agente de Pepe mediante el Bot Framework.
---

## Microsoft Teams

Teams usa el Bot Framework. Configúralo mediante la configuración guiada (o el
panel):

```bash
pepe setup
```

El `config` de una conexión contiene:

- `app_id`: el id de la app (cliente) de Microsoft del bot.
- `app_password`: el secreto de cliente. Guárdalo como `${ENV_VAR}`.
- `tenant_id`: el id de empresa de Azure (o `botframework.com`).

Las actividades entrantes llegan como `POST`s. Las respuestas vuelven a la URL de
servicio de la actividad con un token de acceso de app generado a partir de las
credenciales de cliente. La mención al bot se quita del texto entrante antes de
que el agente lo vea. Forma de la URL de retorno:

```
https://YOUR_HOST/webhooks/root/msteams/<slug>
```

Ver [Webhooks](../webhooks/) para los campos que comparte toda conexión
(`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) y
cómo funciona la ruta genérica por dentro.

### Cambiar de modelo

`/model` y `/models` solo se activan en una conexión en modo `admin` con
`commands` habilitado; en `support`, son texto plano. `/models` lista los
modelos disponibles para la empresa de esta conexión; `/model` muestra el
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
