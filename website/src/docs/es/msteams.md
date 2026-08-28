---
title: Microsoft Teams
description: Pon un agente de Pepe en Microsoft Teams para que tu equipo pueda hablar con él ahí mismo.
---

## Microsoft Teams

Al conectar Teams, tu equipo puede chatear con el agente sin salir de donde ya trabaja. Teams se comunica con los bots a través del Bot Framework de Microsoft; configura la conexión desde el asistente guiado (o desde el panel):

```bash
pepe setup
```

El `config` de una conexión guarda:

- `app_id`: el id de app (cliente) del bot en Microsoft.
- `app_password`: el secreto de cliente. Guárdalo como `${ENV_VAR}`.
- `tenant_id`: el id del tenant de Azure (o `botframework.com`).

Las actividades entrantes llegan como `POST`. Las respuestas vuelven a la URL de servicio de la actividad con un token de acceso de app generado a partir de las credenciales de cliente. La mención al bot se elimina del texto entrante antes de que el agente lo vea. Así queda la URL de retorno:

```
https://YOUR_HOST/webhooks/default/msteams/<slug>
```

### Autenticación de las solicitudes entrantes

Pepe comprueba que cada solicitud entrante viene realmente de Microsoft antes de que el agente vea nada: cada solicitud trae un token del Bot Framework en `Authorization: Bearer`, y Pepe lo valida contra las claves públicas de Microsoft (firma, emisor y una audiencia que debe coincidir con el `app_id` del bot). Gracias a eso, el endpoint acepta `POST` directamente desde Microsoft sin necesitar ningún proxy que valide por su cuenta. Si tu proxy ya hace esa comprobación, define `trust_proxy: true` en la conexión para saltarte la de Pepe.

Consulta [Webhooks](../webhooks/) para ver los campos que comparten todas las conexiones (`agent`, `mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) y cómo funciona la ruta genérica por dentro.

### Cambiar de modelo

Los comandos `/model` y `/models` permiten consultar o cambiar qué modelo de IA responde. Solo funcionan en una conexión en modo `admin` con `commands` habilitado; en modo `support` se tratan como texto normal. `/models` lista los modelos disponibles para el proyecto de esa conexión; `/model` muestra cuál está activo, o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquiera dentro de una conversación permitida puede cambiar el modelo de su propia conversación. Cambiarlo de forma **global**, para todos con los que habla esa conexión, queda reservado a los **entrenadores**, la misma lista de confianza que controla la memoria. Define `model_switch_locked: true` en la conexión para desactivar por completo el cambio de modelo a cualquiera que no sea entrenador.
