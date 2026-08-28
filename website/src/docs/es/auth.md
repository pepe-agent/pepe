---
title: Autenticación
description: Entra en el panel y protege el acceso remoto a la API con tokens acotados.
---

Pepe tiene dos puertas de entrada, y cada una lleva su propia cerradura. El panel
es para personas, y lo protege una contraseña opcional más una regla de red que
por defecto se mantiene cerrada. La API HTTP `/v1` es para programas, y la
protegen tokens bearer que llevan un ámbito. En tu propia máquina ninguna de las
dos cerraduras te estorba, y ninguna de las dos puertas se abre a la red hasta
que tú mismo enciendes su llave.

## Autenticación del panel

El panel viene **abierto por defecto**, así que una instalación local no tiene
ninguna fricción: ejecutas `pepe serve` en tu máquina y lo abres en el
navegador. La autenticación es algo que tú activas cuando quieres: en cuanto
defines una contraseña para el panel, todas las páginas exigen iniciar sesión.
No hay base de datos ni tabla de usuarios; la contraseña se compara en tiempo
constante y una marca firmada viaja en la cookie de sesión de Phoenix.

### Cómo activarla

Puedes fijar la contraseña de dos formas. Si defines las dos, gana el valor de
la configuración:

```bash
# Opción A: una variable de entorno, así nada queda en el archivo de configuración.
export PEPE_DASHBOARD_PASSWORD='una frase secreta bien larga'

# Opción B: guarda una referencia, así el secreto sigue viniendo del entorno.
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'

# Consulta el estado actual, o desactívala de nuevo.
pepe dashboard
pepe dashboard password --clear
```

El valor se interpola como `${ENV}` al momento de leerlo, así que, igual que
cualquier otro secreto de Pepe, nunca queda escrito en claro en
`~/.pepe/config.json`.

Con una contraseña definida:

* todas las rutas del panel redirigen a **`/login`** hasta que inicias sesión;
* `POST /login` compara la contraseña en tiempo constante y guarda una marca
  firmada `dashboard_authed` en la cookie de sesión;
* aparece un enlace **Sign out** en el pie de la barra lateral, y
  `DELETE /logout` borra esa marca.

Si quitas la contraseña, ya sea borrando la variable de entorno o la clave de
configuración, el panel vuelve a quedar abierto.

### Por defecto se cierra: el panel nunca queda abierto a la red sin contraseña

Que venga "abierto por defecto" solo es seguro porque ese valor por defecto es
**exclusivamente loopback**. Una comprobación en cada petición lo garantiza: sin
ninguna contraseña definida, el panel responde únicamente a clientes
`localhost` genuinos. Cualquier petición que llegue de otro lugar (una
dirección de la LAN, una máquina virtual, un proxy inverso) recibe un **403**
que te indica que definas una contraseña. No existe un interruptor para
"dejarlo abierto de todos modos": llegar al panel desde fuera de la máquina
exige una contraseña o un túnel, una de las dos cosas.

La regla, con precisión:

| De dónde viene la petición | Sin contraseña | Con contraseña |
|---|---|---|
| `localhost` (loopback, sin cabeceras de proxy) | permitida | pide iniciar sesión |
| LAN, una VM u otra máquina | **403** | pide iniciar sesión |
| a través de un proxy (con `X-Forwarded-For`) | **403** | pide iniciar sesión |

La LAN y los rangos privados (`192.168.x`, `10.x`, `172.16.x`) cuentan como
**públicos**, no como confiables. La API `/v1` y los endpoints `/webhooks` no
se rigen por esta regla: llevan su propia autenticación, que se describe más
abajo.

### Llegar al panel desde otra máquina

Hay dos formas seguras de hacerlo:

1. **Define una contraseña** y expón el panel detrás de TLS, con un proxy
   inverso o un túnel, de modo que la contraseña y la cookie de sesión nunca
   viajen en claro. Cuando pones un proxy delante, mantén la contraseña activa,
   porque cualquier petición que pase por él se trata como pública.

2. **Déjalo en loopback y entra por un túnel**, de forma que no se abra nada a
   la red:

```bash
pepe serve --tunnel                     # túnel rápido de Cloudflare, ya integrado (necesita cloudflared)
ssh -L 4000:localhost:4000 tu@servidor  # después abre http://localhost:4000
tailscale serve 4000                    # una tailnet privada, sin puerto público
```

`pepe serve --tunnel` ejecuta `cloudflared` e imprime una URL pública
`https://<...>.trycloudflare.com` que dura lo que dure el proceso. Como el
túnel funciona como un proxy, cualquier petición que llegue por él cuenta como
pública, así que define una contraseña de panel antes de usarlo. La guía
completa, incluidos los túneles con nombre propio y una URL estable que eliges
tú, está en la página del [Panel](../dashboard/#llegar-a-él-desde-otro-lugar).

En cambio, `ssh -L` y un reenvío de puerto de Multipass llegan por loopback, así
que funcionan sin ninguna contraseña. Una VM a la que se accede a través de su
red virtual sí se ve como remota y queda bloqueada, así que reenvía su puerto a
`localhost`.

### Servir detrás de un dominio o un proxy inverso

Dos ajustes opcionales hacen que un despliegue real se comporte bien:

```bash
# Los valores de la cabecera Host a los que debe responder el panel (los nombres de loopback siempre funcionan).
pepe dashboard hosts dash.example.com

# Los proxies inversos cuyo X-Forwarded-For se puede confiar (CIDRs o IPs sueltas).
pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8

# Muestra la postura actual: autenticación, hosts, proxies.
pepe dashboard
```

* Los **hosts permitidos** son una defensa contra el DNS rebinding. Sin
  contraseña, el panel solo acepta un `Host` de **loopback** (`localhost`,
  `127.0.0.1`, `::1`) y rechaza cualquier otro nombre con **400**, lo que evita
  que una página maliciosa reapunte un dominio hacia tu máquina y maneje el
  panel local desde ahí. Cuando sirves bajo un dominio real, agrégalo aquí, con
  una contraseña activa. Una lista vacía junto con una contraseña acepta
  cualquier host, porque en ese caso la contraseña ya hace de barrera.
* Los **proxies de confianza** deciden cuándo se le cree al `X-Forwarded-For`.
  Por defecto se ignora, y una petición que llega por proxy se trata como
  remota: es la opción que se mantiene cerrada por defecto. Agrega tu proxy
  aquí y Pepe tomará la IP real del cliente de la cadena reenviada, de modo que
  tanto la regla de loopback frente a remoto como el límite de intentos de
  inicio de sesión vean al cliente verdadero y no al proxy.

### Protección contra fuerza bruta

`POST /login` tiene un límite de intentos por IP de cliente, 10 cada 60
segundos por defecto, y un inicio de sesión exitoso reinicia ese contador. Eso
se suma a la comparación de contraseña en tiempo constante y a un pequeño
retraso en cada fallo. Superar el límite devuelve **429** con una cabecera
`Retry-After`.

### Cómo extenderla

La barrera es deliberadamente pequeña y componible: un hook `on_mount`
(`PepeWeb.Auth`), un plug (`PepeWeb.NetworkGuard`, apoyado en `Pepe.Net` y
`PepeWeb.RemoteClient`) y el limitador de intentos de inicio de sesión.
Esquemas más elaborados, como OAuth, cabeceras de identidad de un proxy de
confianza o cuentas por operador, pueden encajar ahí sin tener que tocar cada
LiveView.

## Autenticación y tokens

Con **cero tokens configurados, la API responde solo a quien llame desde la
misma máquina (loopback)**. Un `curl` local o el panel funcionan sin token,
pero cualquier llamada remota se rechaza con `401`, así que un servidor que
expones a una red nunca queda anónimo.

Crear el primer token cambia la regla para todos: en cuanto existe un solo
token, cada petición, local o remota, tiene que presentar uno válido o se
rechaza con `401`. Generar ese primer token es justamente lo que habilita el
acceso remoto.

### Generar y gestionar tokens

Puedes generar, listar y revocar tokens de tres formas: desde la CLI, desde el
panel, o por chat.

Desde la CLI:

```bash
pepe token add [--project PROJECT] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

En el panel, la página de tokens de la API trae un formulario para generar un
token (con un proyecto y opcionalmente un agente como alcance) y una lista para
revocar los que ya existen.

Un token es una cadena aleatoria con el prefijo `pepe_`. En el archivo de
configuración solo se guarda su hash SHA-256; el token en bruto se imprime una
única vez al crearlo y nunca más. Cópialo en ese momento: si lo pierdes, la
única salida es revocarlo y generar uno nuevo.

#### Hazlo por chat

Un agente al que le concedes la herramienta protegida `manage_token` puede
generar, listar y revocar tokens desde una conversación. Como un token da
acceso a la API, esta herramienta no es de solo lectura: pasa por la barrera de
permisos, así que confirmas antes de que el token se cree, y el secreto en
bruto se devuelve una sola vez para que lo copies.

> Tú: Crea un token para el proyecto acme, con la etiqueta chatwoot.
>
> Agente: (te pide confirmación y luego lo genera) Token de API creado, con
> alcance sobre el proyecto acme. Cópialo ahora, no se va a volver a mostrar:
> `pepe_9f2a...`

### Cómo presentar un token

Puedes enviarlo de cualquiera de las dos formas que usaría un cliente estilo
OpenAI:

```bash
# Estándar de OpenAI: Authorization: Bearer
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hola"}] }'
```

```bash
# Estilo Azure OpenAI: cabecera api-key (aceptada como alternativa)
curl http://localhost:4000/v1/chat/completions \
  -H 'api-key: pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hola"}] }'
```

Cualquier SDK de OpenAI envía la forma `Authorization: Bearer` en cuanto fijas
su `api_key`, así que la autenticación no exige ningún tratamiento especial del
lado del cliente.

### Ámbitos de token

Un token lleva un ámbito que decide a qué agentes puede llegar. De más
estrecho a más amplio:

* **Fijado a un agente** (`--agent HANDLE`): siempre ejecuta exactamente ese
  agente, y el campo `model` de la petición se ignora por completo. Dáselo a
  quien solo deba poder alcanzar un agente en particular.
* **Proyecto** (`--project PROJECT`): cualquier agente dentro de ese proyecto.
  Un nombre de `model` a secas se resuelve automáticamente dentro de ese
  proyecto, y una petición por un agente de otro proyecto se rechaza con
  `403`.
* **Sin ninguno de los dos**: el proyecto por defecto. Es el ámbito en el que
  opera cualquier comando cuando no le indicas otro. Este tipo de token llega a
  los agentes del proyecto por defecto (los que tienen un nombre a secas, sin
  espacio de nombres) y, como caso único, también puede recurrir a conexiones
  de modelo puras por su nombre.

### Permisos de token

El ámbito dice *de quién* son los datos que el token alcanza. Aparte de eso,
un conjunto de permisos dice *qué puede hacer* con ellos. Los valores por
defecto dejan intacto cada token que ya hayas generado antes: **puede**
ejecutar agentes y **no puede** leer el consumo.

| Flag | Por defecto | Qué habilita |
| --- | --- | --- |
| `--chat` / `--no-chat` | activado | ejecutar agentes (`/v1/chat/completions`, el WebSocket) |
| `--usage` | desactivado | leer `/v1/usage`, las cifras de facturación |
| `--prices` | `billable` | cuánto de esos importes muestra una lectura de consumo |
| `--content` | desactivado | que el detalle de una ejecución incluya el prompt y los argumentos o la salida de las herramientas |

```bash
# un token de facturación de solo lectura para un cliente: lee las cifras, no puede gastar tu presupuesto
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions abc123 --prices list    # lo cambia en el sitio, sin tocar el secreto
```

Las dos mitades son independientes a propósito: sin esa separación, darle a un
cliente visibilidad sobre su propio gasto significaría también entregarle una
credencial capaz de ejecutar agentes con cargo a tu cuenta. Consulta la
[API de consumo](../usage-api/) para ver qué devuelve exactamente cada lectura.

### Qué ve cada ámbito en `GET /v1/models`

| Token | Devuelve |
|---|---|
| `--project acme` | solo los agentes de `acme` |
| `--project globex` | solo los agentes de `globex` |
| `--agent acme/support` | únicamente ese agente |
| proyecto por defecto (sin flag) | los agentes del proyecto por defecto, más las conexiones de modelo puras |
| sin token (solo loopback) | todos los agentes, de todos los proyectos, más las conexiones de modelo puras |

Un token nunca cruza esa frontera: uno de `acme` jamás puede listar ni alcanzar
un agente de `globex`. No existe un token que nombre otro proyecto para poder
leerlo; para acceder a los agentes de otro proyecto hace falta generar el token
propio de ese proyecto. Si necesitas una vista de operador que cruce varios
proyectos, usa la CLI (`pepe agent list`) o el panel, nunca un token de un
cliente en particular.

## Enrutamiento multi-cliente: dale al proyecto X su propio acceso

Los ámbitos son la forma de repartir acceso a la API por cliente. Para darle a
un proyecto su propia clave, genera un token con ámbito de proyecto:

```bash
pepe token add --project acme --label "Acme production"
# imprime: pepe_9f2a... (cópialo ahora, se muestra una sola vez)
```

Quien tenga ese token:

* puede alcanzar por nombre cualquier agente que pertenezca a `acme`;
* puede enviar un nombre de `model` a secas y que se resuelva dentro de `acme`;
* recibe un `403` si nombra un agente de otro proyecto;
* ve solo los agentes de `acme` al llamar a `GET /v1/models`.

```bash
# Permitido: un agente dentro de acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "support", "messages": [{"role":"user","content":"hola"}] }'

# Rechazado con 403: un agente fuera de acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "some-other-project-agent", "messages": [{"role":"user","content":"hola"}] }'
```

Para fijar un token a exactamente un agente (con lo que el campo `model` se
ignora del todo), agrega `--agent`:

```bash
pepe token add --project acme --agent acme/support --label "widget de soporte de Acme"
```
