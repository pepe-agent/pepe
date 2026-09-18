---
title: Discord
description: Contesta comandos de barra en tu servidor de Discord usando un agente de Pepe.
---

## Discord

En Discord la gente le habla al agente a través de un comando de barra, por
ejemplo `/ask`. Discord entrega esos comandos por su endpoint de
Interactions, que calza con la pasarela de webhooks de Pepe en vez de con una
conexión persistente. Configúralo desde el asistente guiado o desde el
panel:

```bash
pepe setup
```

El `config` de cada conexión guarda dos cosas:

- `public_key`: la clave pública de la app, en hex, que Discord exige para
  verificar la firma Ed25519.
- `application_id`: con esto se publica la respuesta de seguimiento.

Dentro de la app de Discord, apunta "Interactions Endpoint URL" a la URL de
tu conexión y crea un comando de barra con una opción de texto, por ejemplo
`/ask prompt:...`. Como Discord exige una confirmación dentro de tres
segundos, Pepe responde de inmediato con un acuse diferido y, cuando el
agente termina, publica la respuesta real como mensaje de seguimiento. La
URL de retorno tiene esta forma:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

Los campos que comparten todas las conexiones (`agent`, `mode`, `trainers`,
`session_ttl_min`, `ephemeral`, `commands`) y el funcionamiento interno de la
ruta genérica están en [Webhooks](../webhooks/).

### Archivos en un comando

Dale a tu comando de barra una **opción de adjunto** y la gente puede mandarle un archivo: `/ask prompt:¿qué dice? file:<clip>`. Un clip de voz se transcribe antes de que el agente corra, un documento llega con su texto ya leído, y una imagen llega como imagen a un modelo con visión. El adjunto alcanza por sí solo, así que `/ask file:<clip>` sin nada escrito también funciona.

Es el único camino que tiene un archivo por acá. Un endpoint de interacciones ve comandos de barra y nada más, así que una nota de voz o un adjunto publicado en el canal nunca le llega a Pepe. Aplica el límite de subida del propio Discord (10 MB en un servidor sin boost). Ver [Mensajes de voz](../voice/) y [Documentos](../documents/).

### Cambiar de modelo

Con los comandos `/model` y `/models` cualquiera puede consultar o cambiar
el modelo de IA que le responde. En Discord estos llegan a Pepe a través del
comando que ya registraste (el `/ask` de arriba): todo lo que se escriba en
su opción `prompt:` es lo que Pepe termina leyendo. Solo funcionan si la
conexión está en modo `admin` con `commands` habilitado; en modo `support`
se procesan como texto normal, sin efecto especial. `/models` lista los
modelos disponibles para el proyecto de esa conexión, y `/model` muestra
cuál está activo o lo cambia:

```text
/model openrouter               # pregunta si cambiar solo este chat o todos
/model openrouter session       # cambia solo para esta conversación
/model openrouter global        # cambia para todos con los que habla esta conexión
```

Cualquier persona autorizada a conversar puede cambiar el modelo de su
propia charla, pero hacerlo **de forma global**, para todos con quienes
habla esa conexión, queda reservado a los **entrenadores**: la misma lista
de confianza que controla la memoria. Si quieres bloquear por completo el
cambio de modelo para quien no sea entrenador, activa
`model_switch_locked: true` en la conexión.
