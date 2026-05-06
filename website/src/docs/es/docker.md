---
title: Docker
description: Ejecuta Pepe en un contenedor e instala, dentro de él, las herramientas que el agente necesita.
---

Cada release publica una imagen de contenedor junto con los binarios, para `amd64` y
`arm64`. El `docker pull` selecciona la arquitectura correcta automáticamente, tanto en un
Mac M-series como en un servidor.

```bash
docker run -d --name pepe \
  -p 4000:4000 \
  -v pepe-data:/data \
  -v pepe-tools:/tools \
  -e PEPE_DASHBOARD_PASSWORD=una-contrasena-fuerte \
  ghcr.io/pepe-agent/pepe
```

Abre <http://localhost:4000>, inicia sesión y completa la configuración desde el panel.

## Requisitos

Dos ajustes son obligatorios. Omitir cualquiera de los dos falla en silencio.

### Volúmenes

Son dos, y guardan cosas de naturaleza distinta.

`/data` (el `PEPE_HOME`) es **estado**: configuración, agentes, conversaciones, workspaces
y Mnesia. Es el volumen del que haces copia de seguridad. Sin él, `docker rm` borra la
instalación entera.

`/tools` es **caché**: todo lo que el agente instala para sí mismo. Está en el `PATH` y es
también donde vive el directorio home del agente, en `/tools/home`. Ese segundo detalle es
lo que hace que "se instala una vez" sea cierto de verdad, y tiene su propia sección más
abajo.

`/tools` queda fuera de `/data` a propósito. Una copia de seguridad debe llevar estado, no
decenas de megabytes de binarios y archivos de modelo que se pueden volver a descargar, y
esos archivos son específicos de arquitectura: un `/data` guardado en una máquina arm64 y
restaurado en una amd64 pondría en el `PATH` ejecutables que allí no funcionan.

```bash
-v pepe-data:/data -v pepe-tools:/tools
```

### Contraseña del panel

Un contenedor no es loopback. Pepe lo clasifica como red pública y, sin contraseña,
responde 403 a todas las peticiones. El panel no arranca.

```bash
-e PEPE_DASHBOARD_PASSWORD=...
```

Es una política deliberada, no una limitación de Docker. Pepe se niega a exponer un panel
sin autenticación en una red por la que no puede responder. La regla surgió de un incidente
real: un servicio expuesto, sin autenticación, fue escaneado y alguien abusó de él.

## Secretos

No pongas claves de API ni en la imagen ni en el archivo de configuración. Guarda solo la
referencia en la configuración y proporciona el valor real en la ejecución. Pepe resuelve
la referencia en el momento de la lectura y nunca almacena el valor expandido.

```bash
# la configuración guarda solo:  "api_key": "${OPENROUTER_API_KEY}"
docker run -d ... -e OPENROUTER_API_KEY=sk-... ghcr.io/pepe-agent/pepe
```

## Herramientas para el agente

El agente se ejecuta como usuario sin privilegios y no puede lanzar `apt install`. Es
intencional: los comandos que ejecuta los elige un modelo de lenguaje, y concederle root a
ese proceso no es una decisión que nos corresponda tomar por ti.

La restricción cuesta menos de lo que parece, porque root no es la pieza que falta:

> Todo lo que `apt` instala muere con el contenedor. apt escribe en `/usr` y `/etc`, que
> pertenecen a la capa escribible del contenedor, no a un volumen. Root da permiso, no
> persistencia: lo instalado desaparece en el `docker rm` aunque se ejecute como root.

La pregunta nunca es cómo llegar a root. Es dónde tiene que vivir la herramienta para
sobrevivir. Hay dos respuestas, y hoy la primera resuelve por sí sola la mayoría de los
casos.

### Todo lo que el agente instala para sí mismo persiste

El `HOME` del agente es `/tools/home`, es decir, queda dentro del volumen `/tools`. Ahí
está todo el truco. Los instaladores no preguntan dónde está tu volumen: escriben en
`~/.local/bin` y en `~/.cache`, y en ningún otro sitio. Con el `HOME` en la capa del
contenedor, todo lo que el agente instala para sí se descarga otra vez en el contenedor
siguiente. Con el `HOME` en el volumen, se instala una sola vez.

La diferencia es fácil de medir. El agente que transcribe un mensaje de voz instala `uv` y
descarga un modelo Whisper, unos 75 MB. La primera vez tarda 27 segundos. En un contenedor
recién creado, esa misma transcripción tarda 1,2 segundos, porque la caché sobrevivió.

Así que `uv`, un `pip install --user`, un modelo Whisper, un toolchain de lenguaje o una
descarga simple:

```bash
curl -sL <url> -o /tools/op && chmod +x /tools/op
```

sobreviven al `docker rm` y a una actualización de Pepe, sin root y sin reconstruir ninguna
imagen. `/tools` está en el `PATH`, así que un ejecutable dejado ahí queda disponible al
instante en la shell del agente. El CLI de 1Password (`op`), `gh`, `kubectl` y `terraform`
son todos un único archivo y no necesitan nada más que esto.

### Los paquetes de sistema van en la imagen

Algunas herramientas son paquetes de sistema de verdad. `psql`, `imagemagick` y similares
reparten archivos y bibliotecas compartidas por todo el sistema de archivos, y un volumen
no da abasto con eso. Tienen que formar parte de una imagen.

Un build arg instala paquetes adicionales sin que tengas que escribir un Dockerfile:

```bash
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick" .
```

Si prefieres mantener un Dockerfile propio, derivar de nuestra imagen funciona igual de
bien y sigue siendo una opción perfectamente válida:

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

Los dos caminos tienen el mismo coste: con cada nueva release de Pepe, reconstruyes la
imagen.

#### Por qué `ffmpeg` no está en la imagen

`ffmpeg` parece el paquete de sistema evidente para esta imagen, ya que Telegram envía la
voz en OGG/Opus y la transcripción tiene que salir de algún sitio. Ninguna de las dos rutas
que transcriben de verdad lo necesita. La API de transcripción acepta el fichero `.ogg` tal
y como llega, sin conversión alguna, y `faster-whisper` descodifica a través de PyAV, que
lleva sus propios códecs dentro del wheel. Esto se midió, no se dio por hecho: un fichero
OGG/Opus se transcribió en un Debian limpio, sin ningún `ffmpeg` instalado. Solo el CLI de
`whisper.cpp` llama a `ffmpeg` por fuera, y esa ruta es opt-in.

Incluirlo de todos modos salía carísimo. El paquete `ffmpeg` de Debian arrastra 204
paquetes y 121 MB de archivos (LLVM, Mesa, un sintetizador de voz, un demostrador de
teoremas), todo para sostener una pila de aceleración de vídeo por GPU que un contenedor
headless no va a tocar jamás. Quitarlo dejó la imagen en 408 MB, frente a los 945 MB
anteriores, unos 84 MB comprimidos, que es lo que de verdad te descargas por arquitectura.

Si aun así quieres `ffmpeg`, ya sea para el CLI de `whisper.cpp` o para cualquier otra cosa,
instálalo con el build arg de arriba o deja un build estático de un solo fichero en
`/tools`, que está en el `PATH` y vive en un volumen.

### Probar una herramienta

```bash
docker exec -u root pepe apt-get update
docker exec -u root pepe apt-get install -y jq
```

Funciona, y se descarta en el siguiente `docker rm`. Úsalo para confirmar que la
herramienta resuelve tu problema y solo después decide dónde vive: en el home del propio
agente, si él mismo puede instalarla, o en la imagen, si es un paquete de sistema.

Arrancar el contenedor como root (`docker run --user root`) es opt-in y nunca el valor por
defecto. Conviene repetirlo: no compra nada duradero, porque lo que `apt` escribe sigue
muriendo con el contenedor, y acabas de vuelta en las dos respuestas de arriba.

## Compose

```yaml
services:
  pepe:
    image: ghcr.io/pepe-agent/pepe:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    volumes:
      - pepe-data:/data
      - pepe-tools:/tools
    environment:
      PEPE_DASHBOARD_PASSWORD: ${PEPE_DASHBOARD_PASSWORD}
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY}

volumes:
  pepe-data:
  pepe-tools:
```

```bash
docker compose up -d
```

## Actualización

```bash
docker pull ghcr.io/pepe-agent/pepe
docker rm -f pepe
docker run -d ... ghcr.io/pepe-agent/pepe   # mismos volúmenes, mismas flags
```

Configuración, agentes y conversaciones vuelven con `/data`. Las herramientas del agente,
su home y todas las cachés que hay dentro vuelven con `/tools`, así que no reinstala nada
en el primer mensaje. Los paquetes instalados con `apt` no vuelven, y para esos está la
imagen.

## Acceso al nodo

```bash
docker exec -it pepe bin/pepe remote
```

Abre una shell IEx conectada a la release en ejecución, para inspeccionar el sistema por
dentro.
