---
title: Google Chat
description: Conecta un agente de Pepe a Google Chat para que tu equipo pueda hablarle en espacios y mensajes directos.
---

## Google Chat

Al conectar Google Chat, cualquiera puede hablarle al agente desde sus espacios
o por mensaje directo. Cada mensaje llega a Pepe a través de una URL de
retorno; configura esa conexión con la configuración guiada, o directamente
desde el panel:

```bash
pepe setup
```

El `config` de cada conexión guarda lo siguiente:

- `access_token`: un token OAuth para la Chat API que se usa como bearer al
  responder. Guárdalo como `${ENV_VAR}` y renuévalo por tu cuenta, fuera de
  Pepe.
- `project_number`: el número del proyecto de Cloud donde está registrada la
  app de Chat. En la página de configuración de esa app, pon **Authentication
  Audience** en **Project Number**; la otra opción, HTTP endpoint URL, envía
  un token con un formato distinto que Pepe no sabe verificar, así que
  rechazaría todos los mensajes entrantes.

Solo se procesan los eventos `MESSAGE` que vienen de una persona. Las
respuestas se publican de vuelta en el espacio mediante la Chat REST API. La
URL de retorno tiene esta forma:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Autenticación de entrada

Antes de que el agente vea nada, Pepe verifica que la solicitud entrante venga
realmente de Google: cada petición trae un token firmado por Google en
`Authorization: Bearer`, y Pepe lo valida comprobando la firma contra las
claves públicas de Google, el emisor y que la audiencia coincida con
`project_number`. Gracias a eso, el endpoint puede aceptar los `POST`
directamente desde Google, sin necesitar un proxy intermedio que valide nada.
Si tu propio proxy ya hace esa comprobación, activa `trust_proxy: true` en la
conexión para que Pepe se salte la suya.

Revisa [Webhooks](../webhooks/) para conocer los campos comunes a toda
conexión (`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`,
`commands`) y cómo funciona por dentro la ruta genérica.

### Cambiar de modelo

Con los comandos `/model` y `/models`, cualquiera puede revisar o cambiar qué
modelo de IA le está respondiendo. Solo funcionan en una conexión en modo
`admin` con `commands` habilitado; en modo `support` se tratan como texto
normal, sin ningún efecto especial. `/models` lista los modelos disponibles
para el proyecto de esa conexión, y `/model` muestra cuál está activo o lo
cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquier persona en una conversación permitida puede cambiar el modelo de su
propia conversación. Cambiarlo de forma **global**, para todos con quienes
habla esa conexión, queda reservado a los **entrenadores**, la misma lista de
confianza que controla la memoria. Si quieres desactivar por completo el
cambio de modelo para quien no sea entrenador, activa
`model_switch_locked: true` en la conexión.
