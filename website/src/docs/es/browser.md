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

## Requiere Chrome

`browser` necesita un binario real de Chromium o Chrome en la máquina donde corre Pepe - no viene instalado por defecto, ni en el contenedor ni fuera de él. En Docker, actívalo al construir la imagen:

```
docker build --build-arg PEPE_IMAGE_APT_PACKAGES="chromium" .
```

Fuera de Docker, instala Chromium (o Chrome) y asegúrate de que esté en el `PATH`, o apunta `PEPE_CHROME_BINARY` a su ejecutable. Sin ninguno de los dos, `browser` devuelve un error claro en vez de fallar en silencio.
