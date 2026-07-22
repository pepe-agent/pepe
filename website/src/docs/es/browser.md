---
title: Navegador
description: Un agente puede manejar un navegador real sin interfaz para páginas que necesitan JavaScript, inicio de sesión, o completar un flujo con clics.
---

`fetch_url` es un simple GET por HTTP: no puede ejecutar JavaScript, iniciar sesión, ni hacer clic en nada. La herramienta `browser` es para las páginas que necesitan eso: un Chrome real, sin interfaz, manejado página por página, que persiste entre llamadas dentro de la misma conversación hasta que lo cierres.

Cada conversación tiene su propia sesión de navegador, que arranca la primera vez que llama a `open` y se cierra sola tras diez minutos de inactividad si nada la termina antes. Sus cookies y la página actual se mantienen de una llamada a otra, así que un inicio de sesión, un formulario de varios pasos, o una página que solo revela contenido tras un clic, funcionan como lo harían en una pestaña real.

## Qué puede hacer

- **`open`** - navega a una URL (arranca el navegador de la sesión si ninguno está corriendo todavía). Devuelve el título de la página, su texto visible, y una lista numerada de los elementos sobre los que se puede actuar.
- **`snapshot`** - vuelve a describir la página actual, con la misma forma que `open`, sin navegar - útil después de que un script en la página cambia algo sin una carga completa.
- **`click`** - hace clic en el elemento numerado `ref` del último `open`/`snapshot`.
- **`type`** - escribe texto en el elemento numerado `ref`.
- **`press`** - presiona una tecla (por ejemplo, "Enter"), opcionalmente enfocando antes un elemento.
- **`close`** - termina la sesión y libera su navegador.

```
Tú: Entra a la página de estado e indícame si algo está caído.

Agente: [browser open: "https://status.example.com/login"]
        [browser type ref=2: "el correo de la cuenta"]
        [browser type ref=3: "la contraseña de la cuenta"]
        [browser click ref=4]
        [browser snapshot]
Todo en verde, sin incidentes abiertos en este momento.
```

Los elementos se identifican por número, no por un selector CSS que tendrías que escribir tú mismo: cada `open`/`snapshot` etiqueta cada elemento clicable o completable y devuelve qué es y qué dice, así que el agente lee "el elemento 4 es el botón de enviar" directamente de lo que se le acaba de mostrar.

## Postura de seguridad

Un navegador bajo el control de un agente llega a la misma red que la aplicación, así que `browser` aplica la misma regla que `fetch_url`: solo `http`/`https`, y nunca una dirección interna o privada (loopback, RFC1918, link-local, metadatos de la nube). Y porque un navegador real es una superficie bastante mayor que una herramienta de solo lectura (los scripts propios de la página se ejecutan, una sesión iniciada podría quedar expuesta, usa CPU y memoria reales), `browser` no es siempre-segura: cada llamada pasa por el mismo aviso de permiso que `bash`.

## Cómo consigue un navegador

`browser` necesita un binario real de Chrome/Chromium/Edge/Brave para manejar. Lo busca en este orden:

1. `PEPE_CHROME_BINARY`, si lo defines - una ruta explícita gana sobre todo lo demás.
2. Lo que ya esté instalado - revisado en el `PATH` y en las ubicaciones normales de instalación de cada sistema (`/Applications` en macOS, `Program Files` y la carpeta de instalación por usuario en Windows), así que un navegador que ya tengas se usa tal cual, en contenedor o no.
3. **Una descarga automática, una sola vez**, si ninguno de los anteriores encontró nada: un build pequeño y sin interfaz de `chrome-headless-shell` desde el feed oficial Chrome for Testing de Google, guardado en caché bajo `~/.cache/pepe/browser/` para que esto solo pase una vez por máquina. Desactívalo con `PEPE_BROWSER_AUTO_DOWNLOAD=0` si prefieres instalar uno tú mismo y ver un error claro en su lugar.

La imagen por defecto no incluye el paquete del navegador en sí (la misma lógica que mantiene el ffmpeg fuera - ver el Dockerfile), pero sí incluye las bibliotecas compartidas que `chrome-headless-shell` necesita para arrancar una vez descargado, ya que `browser` es una herramienta integrada, no un extra opcional. Así que el paso 3 es lo que corre por defecto en Docker, y funciona de entrada: sin necesidad de ningún build arg, en un host `amd64` (Google no publica un build de Chrome for Testing para Linux en ARM - ver más abajo). Si prefieres incluir un navegador completo en la imagen en vez de descargarlo en tiempo de ejecución:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

## Linux en ARM

Chrome for Testing no tiene build para Linux ARM, así que el paso 3 no puede ayudar ahí - `browser` devuelve un error claro de "plataforma no soportada" en vez de fallar en silencio. Instala Chromium tú mismo vía el gestor de paquetes de tu sistema y ponlo en el `PATH`, o define `PEPE_CHROME_BINARY`.
