---
title: Autenticación
description: Entra en el panel y protege el acceso remoto a la API con tokens acotados.
---

Pepe tiene dos puertas de entrada y cada una lleva su propia cerradura. El panel es para personas, y lo protege una contraseña opcional más una regla de red que se cierra por defecto. La API HTTP `/v1` es para programas, y la protegen tokens bearer que llevan un ámbito. En tu propia máquina ninguna de las dos cerraduras te estorba, y ninguna de las dos puertas se abre a la red hasta que enciendes la suya.

## Autenticación del panel

El panel está **abierto por defecto**, así que una instalación local no tiene ninguna fricción: ejecuta `pepe serve` en tu máquina y ábrelo en el navegador. La autenticación es **opcional, la activas tú**: en el momento en que defines una contraseña del panel, todas las páginas exigen iniciar sesión. No hay base de datos ni tabla de usuarios. La contraseña se comprueba en tiempo constante y una marca firmada viaja en la cookie de sesión de Phoenix.

### Activarla

Define una contraseña de cualquiera de las dos formas. Si están ambas, gana el valor de la configuración:

```bash
# Opción A: una variable de entorno, así nada acaba en el archivo de configuración.
export PEPE_DASHBOARD_PASSWORD='una frase secreta bien larga'

# Opción B: guarda una referencia, así el secreto sigue viniendo del entorno.
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'

# Consulta el estado actual, o vuelve a desactivarla.
pepe dashboard
pepe dashboard password --clear
```

El valor se interpola como `${ENV}` al momento de leer, así que, como todos los demás secretos en Pepe, nunca se escribe en claro en `~/.pepe/config.json`.

Con una contraseña definida:

* todas las rutas del panel redirigen a **`/login`** hasta que inicias sesión;
* `POST /login` comprueba la contraseña con una comparación en tiempo constante y guarda una marca firmada `dashboard_authed` en la cookie de sesión;
* aparece un enlace **Sign out** en el pie de la barra lateral, y `DELETE /logout` borra la marca.

Quita la contraseña, borrando la variable de entorno o la clave de la configuración, y el panel vuelve a quedar abierto.

### Se cierra por defecto: el panel nunca queda abierto a la red sin contraseña

Que esté "abierto por defecto" solo es seguro porque ese valor por defecto es **solo loopback**. Una barrera por petición lo garantiza: **sin contraseña definida**, el panel responde únicamente a clientes `localhost` genuinos. Cualquier petición que venga de otro sitio, ya sea una dirección de la LAN, una máquina virtual o un proxy inverso, recibe un **403** que te dice que definas una contraseña. No existe un interruptor de "déjalo abierto igual": llegar al panel desde fuera de la máquina significa o una contraseña o un túnel.

La regla, con precisión:

| La petición viene de | Sin contraseña | Con contraseña |
|---|---|---|
| `localhost` (loopback, sin cabeceras de proxy) | permitida | exige iniciar sesión |
| LAN, una VM u otra máquina | **403** | exige iniciar sesión |
| a través de un proxy (con `X-Forwarded-For`) | **403** | exige iniciar sesión |

La LAN y los rangos privados (`192.168.x`, `10.x`, `172.16.x`) cuentan como **públicos**, no como de confianza. La API `/v1` y los endpoints `/webhooks` no se ven afectados por esta regla; llevan su propia autenticación, descrita más abajo.

### Llegar al panel desde otra máquina

Dos opciones son seguras:

1. **Define una contraseña** y expón el panel detrás de TLS, con un proxy inverso o un túnel, para que la contraseña y la cookie de sesión nunca viajen en claro. Cuando pones un proxy delante, deja la contraseña puesta, porque una petición que llega por un proxy se trata como pública.

2. **Déjalo en loopback y entra por un túnel**, para que no se abra nada a la red:

```bash
pepe serve --tunnel                     # túnel rápido de Cloudflare, incorporado (necesita cloudflared)
ssh -L 4000:localhost:4000 tu@servidor  # luego abre http://localhost:4000
tailscale serve 4000                    # una tailnet privada, sin puerto público
```

`pepe serve --tunnel` ejecuta `cloudflared` e imprime una URL pública `https://<...>.trycloudflare.com` que dura lo que dure el proceso. Como el túnel es un proxy, una petición que llega por él cuenta como pública, así que define una contraseña del panel antes de usarlo. El recorrido completo, incluidos los túneles con nombre y una URL estable que eliges tú, está en la página del [Panel](../dashboard/#acceso-remoto).

En cambio `ssh -L` y un reenvío de puerto de Multipass llegan por loopback, así que funcionan sin ninguna contraseña. Una VM alcanzada a través de su red virtual parece remota y queda bloqueada, así que reenvía su puerto a `localhost`.

### Servir detrás de un dominio o de un proxy inverso

Dos ajustes opcionales hacen que un despliegue de verdad se comporte bien:

```bash
# Los valores de la cabecera Host a los que el panel debe responder (los nombres de loopback siempre funcionan).
pepe dashboard hosts dash.example.com

# Los proxies inversos cuyo X-Forwarded-For se puede creer (CIDRs o IPs sueltas).
pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8

# Muestra la postura actual: autenticación, hosts, proxies.
pepe dashboard
```

* Los **hosts permitidos** son una defensa contra el DNS rebinding. Sin contraseña, el panel acepta solo un `Host` de **loopback** (`localhost`, `127.0.0.1`, `::1`) y rechaza cualquier otro nombre con **400**, lo que impide que una página maliciosa reapunte un dominio a tu máquina y maneje el panel local. Cuando sirves bajo un dominio real, ponlo aquí, con una contraseña activada. Una lista vacía más una contraseña acepta cualquier host, porque entonces la contraseña es la barrera.
* Los **proxies de confianza** deciden cuándo se cree el `X-Forwarded-For`. Por defecto se ignora y una petición que llega por proxy se trata como remota, que es la opción que cierra por defecto. Pon aquí tu proxy y Pepe toma la IP real del cliente de la cadena reenviada, de modo que tanto la regla de loopback frente a remoto como el límite de intentos de inicio de sesión vean al par verdadero y no al proxy.

### Protección contra fuerza bruta

`POST /login` tiene límite de tasa por IP de cliente, por defecto 10 intentos cada 60 segundos, y un inicio de sesión correcto reinicia el contador. Eso se apoya sobre la comparación de contraseña en tiempo constante y un pequeño retardo en cada fallo. Pasarse del límite devuelve **429** con una cabecera `Retry-After`.

### Extenderla

La barrera es deliberadamente pequeña y componible: un hook `on_mount` (`PepeWeb.Auth`), un plug (`PepeWeb.NetworkGuard`, apoyado en `Pepe.Net` y `PepeWeb.RemoteClient`) y el limitador de inicios de sesión. Esquemas más ricos, como OAuth, cabeceras de identidad de un proxy de confianza o cuentas por operador, encajan sin tocar cada LiveView.

## Autenticación y tokens

Con **cero tokens configurados, la API responde solo a los llamantes de la misma máquina (loopback)**. Un `curl` local o el panel funcionan sin token, pero cualquier llamante remoto se rechaza con `401`, así que un servidor que expones en una red nunca es anónimo.

Crear el primer token cambia la regla para todos. Una vez que existe cualquier token, cada petición, local o remota, debe presentar uno válido o se rechaza con `401`. Generar el primer token es lo que desbloquea el acceso remoto.

### Generar y gestionar tokens

Puedes generar, listar y revocar tokens de tres formas: la CLI, el panel o por chat.

Desde la CLI:

```bash
pepe token add [--project PROJECT] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

En el panel, la página de tokens de la API tiene un formulario para generar un token (con un alcance de proyecto y agente opcional) y una lista para revocar los existentes.

Un token es una cadena aleatoria con el prefijo `pepe_`. En el archivo de configuración solo se guarda su hash SHA-256; el token en bruto se imprime una vez al crearlo y nunca más. Cópialo en ese momento. Si lo pierdes, revócalo y genera uno nuevo.

#### Hazlo por chat

Un agente al que se le otorga la herramienta protegida `manage_token` puede generar, listar y revocar tokens desde una conversación. Como un token concede acceso a la API, la herramienta no es de solo lectura: pasa por la barrera de permisos, así que confirmas antes de que se cree un token, y el secreto en bruto se devuelve una sola vez para que lo copies.

> Tú: Crea un token para el proyecto acme, con la etiqueta chatwoot.
>
> Agente: (te pide confirmación y luego lo genera) Token de API creado, alcance proyecto acme. Cópialo ahora, no se volverá a mostrar: `pepe_9f2a...`

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
* **Proyecto** (`--project PROJECT`): cualquier agente dentro de ese proyecto. Un nombre de `model` puro se cualifica dentro de ese proyecto automáticamente, y una petición por un agente que pertenece a otro proyecto se rechaza con `403`.
* **Ninguno**: el proyecto por defecto. Es el ámbito en el que opera cada comando cuando no especificas ninguno. Puede alcanzar los agentes del proyecto por defecto (los que tienen un nombre puro, sin espacio de nombres) y, de forma única, recurrir a conexiones de modelo puras por nombre.

`GET /v1/models` respeta el ámbito: un token de proyecto o de agente ve solo sus propios agentes, nunca los de otro proyecto, y nunca las conexiones de modelo puras.

## Enrutamiento multi-cliente: dale al proyecto X su propio acceso

Los ámbitos son la forma de repartir acceso a la API por cliente. Para dar a un proyecto su propia clave, genera un token con ámbito de proyecto:

```bash
pepe token add --project acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

Quien posea ese token:

* puede alcanzar por nombre cualquier agente que pertenezca a `acme`;
* puede enviar un nombre de `model` puro y que se resuelva dentro de `acme`;
* se rechaza con `403` si nombra un agente de otro proyecto;
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
  -d '{ "model": "some-other-project-agent", "messages": [{"role":"user","content":"hola"}] }'
```

Para fijar un token a exactamente un agente (el campo `model` se ignora entonces por completo), añade `--agent`:

```bash
pepe token add --project acme --agent acme/support --label "widget de soporte de Acme"
```
