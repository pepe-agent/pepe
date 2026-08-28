---
title: Docker
description: Corre Pepe como contenedor, e instala dentro de él las herramientas que el agente necesite.
---

Cada release publica, junto a los binarios, una imagen de contenedor para
`amd64` y `arm64`. Al hacer `docker pull`, se elige sola la arquitectura
correcta, sea en un Mac de la serie M o en un servidor.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=una-contrasena-fuerte \
  ghcr.io/pepe-agent/pepe
```

Abre <http://localhost:4000>, inicia sesión y termina la configuración desde
el panel.

## Requisitos

Hay dos ajustes obligatorios, y saltarte cualquiera de los dos falla en
silencio.

### Volúmenes

Son dos, y cada uno guarda un tipo distinto de cosa.

`/data` (el `PEPE_HOME`) es **estado**: configuración, agentes,
conversaciones, workspaces y Mnesia. Es el volumen del que debes respaldar
copias de seguridad; sin él, un `docker rm` te borra la instalación entera.

`/tools` es **caché**: todo lo que el agente instala por su cuenta. Está en
el `PATH`, y además ahí vive el directorio home del agente, en
`/tools/home`. Ese segundo detalle es justo lo que hace que "se instala una
sola vez" sea cierto de verdad, y tiene su propio apartado más abajo.

`/tools` queda deliberadamente separado de `/data`. Una copia de seguridad
debería llevarse el estado, no decenas de megabytes de binarios y modelos
que se pueden volver a descargar, y esos archivos además son específicos de
cada arquitectura: si restauras en una máquina amd64 un `/data` respaldado
en una arm64, terminarías con ejecutables en el `PATH` que ahí simplemente
no corren.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Contraseña del panel

Un contenedor no cuenta como tu propia máquina: Pepe da por hecho que su red
es pública y, sin contraseña, rechaza toda petición con un HTTP 403. El
panel simplemente no se sirve.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

Es una política deliberada, no una limitación de Docker: Pepe se niega a
exponer un panel sin autenticación en una red que no puede garantizar como
segura. Esta regla nació de un incidente real, un servicio expuesto sin
autenticación que terminó escaneado y explotado.

## Secretos

Nunca pongas claves de API dentro de la imagen ni en el archivo de
configuración. Deja ahí solo la referencia, y entrega el valor real en el
momento de ejecutar; Pepe resuelve esa referencia al leerla, y jamás guarda
el valor ya expandido.

```bash
# la configuración guarda solo:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Herramientas para el agente

El agente corre como un usuario sin privilegios y no puede ejecutar
`apt install`. Esto es intencional: los comandos que ejecuta los elige un
modelo de lenguaje, y darle acceso root a ese proceso no es una decisión que
nadie deba tomar en tu nombre.

Esta restricción cuesta menos de lo que parece, porque root nunca fue la
pieza que faltaba:

> Todo lo que instala `apt` muere junto con el contenedor. apt escribe en
> `/usr` y en `/etc`, que pertenecen a la capa escribible del contenedor, no
> a un volumen. Root te da permiso, no persistencia: lo que instala
> desaparece con el `docker rm`, incluso corriendo como root.

La pregunta nunca es cómo hacerte root. Es dónde tiene que vivir una
herramienta para sobrevivir. Hay dos respuestas posibles, y hoy la primera
resuelve, ella sola, la mayoría de los casos.

### Todo lo que el agente instala por su cuenta persiste

El `HOME` del agente es `/tools/home`, y eso lo coloca dentro del volumen
`/tools`. Ese es todo el truco: los instaladores no preguntan dónde está tu
volumen, simplemente escriben en `~/.local/bin` y en `~/.cache`, y en ningún
otro lado. Si el `HOME` vive en la capa del contenedor, todo lo que el
agente instaló se vuelve a descargar en el siguiente contenedor; si el
`HOME` vive en el volumen, se instala una sola vez.

La diferencia se puede medir sin esfuerzo. Un agente que transcribe un
mensaje de voz instala `uv` y descarga un modelo Whisper de unos 75 MB; la
primera vez tarda 27 segundos. En un contenedor completamente nuevo, esa
misma transcripción tarda 1,2 segundos, porque la caché sobrevivió al
reinicio.

Así que `uv`, un `pip install --user`, un modelo Whisper, un toolchain de
algún lenguaje, o simplemente una descarga directa:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

todo eso sobrevive a un `docker rm` y a una actualización de Pepe, sin
necesitar root ni reconstruir nada. Como `/tools` está en el `PATH`,
cualquier binario que dejes ahí queda disponible al instante desde la shell
del agente. El CLI de 1Password (`op`), `gh`, `kubectl` y `terraform` son
todos archivos únicos, y no necesitan más que esto.

### Los paquetes de sistema van en la imagen

Algunas herramientas sí son paquetes de sistema de verdad. Cosas como
`psql` o `imagemagick` reparten archivos y bibliotecas compartidas por todo
el sistema de archivos, algo que un volumen no puede sostener. Esas tienen
que formar parte de la imagen.

Un argumento de build instala paquetes adicionales sin que tengas que
escribir un Dockerfile:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

Si prefieres mantener tu propio Dockerfile, partir de nuestra imagen
funciona igual de bien y sigue siendo una opción totalmente válida:

```dockerfile
FROM ghcr.io/pepe-agent/pepe
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client \
  && rm -rf /var/lib/apt/lists/*
USER pepe
```

```bash
docker build -t mi-pepe .
docker run -d -p 4000:4000 -v pepe-data:/data -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=... mi-pepe
```

Cualquiera de los dos caminos tiene el mismo costo: cada nueva release de
Pepe implica reconstruir la imagen.

#### Por qué `ffmpeg` no está en la imagen

`ffmpeg` parece el paquete de sistema obvio para esta imagen, ya que
Telegram manda la voz en OGG/Opus y de algún lado tiene que salir la
transcripción. Pero ninguna de las dos rutas que realmente transcriben lo
necesita: una API de transcripción recibe el `.ogg` tal cual llega, sin
ninguna conversión, y `faster-whisper` decodifica a través de PyAV, que trae
sus propios códecs dentro del wheel. Esto se comprobó, no se supuso: un
archivo OGG/Opus se transcribió sin problema en un Debian limpio, sin
`ffmpeg` instalado en ningún lado. Solo el CLI de `whisper.cpp` sí llama a
`ffmpeg` por fuera, y esa ruta es opcional.

Incluirlo de todos modos salía mucho más caro de lo que valía. El paquete
`ffmpeg` de Debian arrastra 204 paquetes más y 121 MB de archivos (LLVM,
Mesa, un sintetizador de voz, un demostrador de teoremas), todo para
sostener una pila de aceleración de video por GPU que un contenedor
headless jamás va a usar. Al quitarlo, la imagen bajó de 945 MB a 408 MB,
unos 84 MB comprimidos, que es lo que en realidad te descargas por
arquitectura.

Si de todas formas quieres `ffmpeg`, ya sea para el CLI de `whisper.cpp` o
para cualquier otra cosa, instálalo con el argumento de build de arriba, o
deja un build estático de un solo archivo dentro de `/tools`, que está en el
`PATH` y vive en un volumen.

### Probar una herramienta

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

Esto funciona, y se pierde con el siguiente `docker rm`. Úsalo solo para
confirmar que una herramienta resuelve tu problema, y después decide dónde
debe vivir de verdad: en el home del propio agente, si puede instalarla él
mismo, o en la imagen, si es un paquete de sistema.

Correr el contenedor como root (`docker run --user root`) es opcional, y
jamás el valor por defecto. Vale la pena repetirlo: eso no compra nada
duradero, porque lo que escribe `apt` sigue muriendo con el contenedor, así
que terminas de vuelta en una de las dos respuestas de arriba.

## Compose

Pepe ya trae su propio `docker-compose.yml`, así que no tienes que escribir
nada:

```bash
curl -O https://raw.githubusercontent.com/pepe-agent/pepe/master/docker-compose.yml
```

Es el mismo `docker run` de arriba, con los dos volúmenes y la contraseña ya
puestos:

```yaml
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    volumes:
      - pepe-data:/data # estado: configuración, agentes, conversaciones. De este haces copia de seguridad.
      - pepe-tools:/tools # el home del agente y todo lo que él mismo instala.
    environment:
      # El `:?` es deliberado: sin contraseña, el panel respondería 403 a cada petición
      # (un contenedor no es loopback), así que compose se niega a arrancar en lugar de
      # entregarte un contenedor que se ejecuta y no sirve nada.
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD:?set this in a .env file}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY}
      TZ: UTC

volumes:
  pepe-data:
  pepe-tools:
```

Los secretos van en un archivo `.env` al lado, nunca dentro del archivo
compose ni de la imagen. La configuración de Pepe los referencia por nombre
(`"api_key": "${OPENROUTER_API_KEY}"`) y los resuelve al leerlos, de modo
que el valor real solo existe en el entorno:

```bash
# .env
PEPE_DASHBOARD_PASSWORD=una-contrasena-fuerte
OPENROUTER_API_KEY=sk-...
```

Cada secreto necesita las dos mitades: el valor en `.env`, **y** una línea
bajo `environment:` que lo nombre. Compose lee el `.env` para completar los
`${...}` del propio archivo compose, no para poblar el contenedor
directamente, así que una clave que solo esté en `.env` nunca llega a Pepe,
y terminas con un "no model configured" sin ninguna pista de por qué.
Agrega una línea por cada secreto que uses.

Después, desde ese mismo directorio:

```bash
docker compose up -d
docker compose logs -f          # sigue el log
docker compose exec pepe bin/pepe remote   # una shell IEx en el nodo en ejecución
```

## Ponerlo en un servidor

Todo lo anterior corre en una sola máquina, alcanzable en `localhost`. En
cuanto agregas un dominio, TLS y un proxy inverso detrás, entran en juego
cuatro cosas más, y ninguna depende de Docker. Consulta [Desplegar en un
servidor](/es/docs/deploy/) para ver Compose detrás de Caddy, Docker Swarm
detrás de Traefik, y Kamal.

## Actualización

Con Compose:

```bash
docker compose pull
docker compose up -d
```

Sin Compose:

```bash
docker pull ghcr.io/pepe-agent/pepe
docker rm -f pepe
docker run -d ... ghcr.io/pepe-agent/pepe   # mismos volúmenes, mismas flags
```

La configuración, los agentes y las conversaciones vuelven junto con
`/data`. Las herramientas del agente, su home y toda la caché que contiene
vuelven con `/tools`, así que no reinstala nada en el primer mensaje. Lo
único que no vuelve son los paquetes instalados con `apt`, y para esos
justamente existe la imagen.

Un detalle que conviene tener claro: `docker compose down` detiene los
contenedores y deja los volúmenes intactos, que es lo que quieres. `docker
compose down -v`, en cambio, también los borra, y con ellos toda la
instalación.

## Acceso al nodo

```bash
docker exec -it pepe bin/pepe remote            # o: docker compose exec pepe bin/pepe remote
```

Abre una shell IEx conectada a la release en ejecución, para inspeccionar el
sistema desde dentro.

Si solo necesitas un comando puntual de `pepe` en vez de una shell completa,
usa `bin/pepe rpc` con `dispatch_attached/1`: son los mismos comandos que
`pepe` corre en cualquier otro lado, pero adaptados para ejecutarse sin
riesgo contra un nodo que ya está sirviendo:

```bash
docker exec pepe bin/pepe rpc 'Mix.Tasks.Pepe.dispatch_attached(["agent", "list"])'
```

`bin/pepe <comando>` por sí solo no funciona aquí: el contenedor es una
release simple, y su despacho de CLI solo se activa en el binario Burrito,
que se distribuye aparte. `bin/pepe rpc`/`remote` es, en cualquier caso, la
puerta de entrada. `dispatch_attached/1` existe porque bastantes comandos
(`plugin install`, `eval`, `doctor`, `cron`, y otros más, no solo
`run`/`chat`/`tui`) de otro modo terminarían cambiando ajustes globales
pensados para decidirse una sola vez, al arrancar. Eso no tiene ningún costo
en un proceso de CLI recién levantado que termina enseguida, pero sí lo
tendría en un nodo que ya está corriendo y va a seguir así.
