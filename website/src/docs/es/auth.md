---
title: Autenticación
description: Protege el acceso remoto a la API con tokens acotados.
---

## Autenticación y tokens

Con **cero tokens configurados, la API responde solo a los llamantes de la misma máquina (loopback)**. Un `curl` local o el panel funcionan sin token, pero cualquier llamante remoto se rechaza con `401`, así que un servidor que expones en una red nunca es anónimo.

Crear el primer token requiere entonces un token de todos (locales o remotos). Una vez que existe cualquier token, cada petición, local o remota, debe presentar uno válido o se rechaza con `401`. Generar el primer token es lo que desbloquea el acceso remoto.

### Generar y gestionar tokens

Puedes generar, listar y revocar tokens de tres formas: la CLI, el panel o por chat.

Desde la CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

En el panel, la página de tokens de la API tiene un formulario para generar un token (con un alcance de empresa y agente opcional) y una lista para revocar los existentes.

Un token es una cadena aleatoria con el prefijo `pepe_`. En el archivo de configuración solo se guarda su hash SHA-256; el token en bruto se imprime una vez al crearlo y nunca más. Cópialo en ese momento. Si lo pierdes, revócalo y genera uno nuevo.

#### Hazlo por chat

Un agente al que se le otorga la herramienta protegida `manage_token` puede generar, listar y revocar tokens desde una conversación. Como un token concede acceso a la API, la herramienta no es de solo lectura: pasa por la barrera de permisos, así que confirmas antes de que se cree un token, y el secreto en bruto se devuelve una sola vez para que lo copies.

> Tú: Crea un token para la empresa buskaza, con la etiqueta chatwoot.
>
> Agente: (te pide confirmación y luego lo genera) Token de API creado, alcance empresa buskaza. Cópialo ahora, no se volverá a mostrar: `pepe_9f2a...`

### Presentar un token

Envíalo de cualquiera de las dos formas en que lo haría un cliente estilo OpenAI:

```bash
# OpenAI standard: Authorization: Bearer
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hola"}] }'
```

```bash
# Azure OpenAI style: api-key header (accepted as a fallback)
curl http://localhost:4000/v1/chat/completions \
  -H 'api-key: pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hola"}] }'
```

Cualquier SDK de OpenAI envía la forma `Authorization: Bearer` cuando fijas su `api_key`, de modo que la autenticación no necesita ningún tratamiento especial en el cliente.

### Ámbitos de token

Un token lleva un ámbito que decide a qué agentes puede llegar. De lo más estrecho a lo más amplio:

* **Fijado a un agente** (`--agent HANDLE`): siempre ejecuta exactamente ese agente. El campo `model` de la petición se ignora. Entrega esto a quien solo deba alcanzar un agente específico.
* **Empresa** (`--company CO`): cualquier agente dentro de esa empresa. Un nombre de `model` puro se cualifica dentro de esa empresa automáticamente, y una petición por un agente que pertenece a otra empresa se rechaza con `403`.
* **Ninguno**: el ámbito raíz (sin empresa). Es sobre lo que opera cada comando cuando no le pones ámbito. Puede alcanzar los agentes raíz (los que tienen un nombre puro, sin espacio de nombres) y, de forma única, recurrir a conexiones de modelo puras por nombre.

`GET /v1/models` respeta el ámbito: un token de empresa o de agente ve solo sus propios agentes, nunca los de otra empresa, y nunca las conexiones de modelo puras.

## Enrutamiento multiempresa: dale a la empresa X su propio acceso

Los ámbitos son la forma de repartir acceso a la API por empresa. Para dar a una empresa su propia clave, genera un token con ámbito de empresa:

```bash
pepe token add --company acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

Quien posea ese token:

* puede alcanzar por nombre cualquier agente que pertenezca a `acme`;
* puede enviar un nombre de `model` puro y que se resuelva dentro de `acme`;
* se rechaza con `403` si nombra un agente de otra empresa;
* ve solo los agentes de `acme` desde `GET /v1/models`.

```bash
# Allowed: an agent inside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "support", "messages": [{"role":"user","content":"hola"}] }'

# Refused with 403: an agent outside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "some-other-company-agent", "messages": [{"role":"user","content":"hola"}] }'
```

Para fijar un token a exactamente un agente (el campo `model` se ignora entonces por completo), agrega `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "widget de soporte de Acme"
```
