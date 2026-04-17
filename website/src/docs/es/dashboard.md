---
title: Panel
description: Usa la interfaz web local para inspeccionar y gestionar agentes, modelos, canales y ejecuciones.
---

El panel es la interfaz web local que arranca con `pepe serve`. Úsalo para conversar con agentes, inspeccionar trazas, gestionar conexiones de modelo, configurar canales, revisar tareas programadas y generar tokens de API sin editar JSON a mano.

## Acceso al panel

El panel web está abierto en localhost por defecto, lo que resulta cómodo para el desarrollo local. En el momento en que lo expones más allá de tu máquina, ponlo detrás de una contraseña:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Puedes pasar una contraseña literal o una referencia `${ENV_VAR}` para que el secreto quede fuera del archivo. Una vez definida la contraseña, el panel exige iniciar sesión en `/login`. Bórrala con `pepe dashboard password --clear`.

La contraseña se lee de `dashboard.password` en la configuración (interpolada), con respaldo en la variable de entorno `PEPE_DASHBOARD_PASSWORD`. Dos ajustes relacionados endurecen un panel servido detrás de un dominio:

- `pepe dashboard hosts app.example.com,dash.example.com` define los valores adicionales del encabezado `Host` que el panel acepta. Esto sirve también como lista blanca contra el reataque de DNS (DNS rebinding).
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lista los proxies inversos cuyo encabezado `X-Forwarded-For` puede considerarse confiable. Vacío por defecto, lo que significa que no se confía en ningún encabezado de reenvío.

Vinculado a una interfaz pública sin contraseña, el panel se cierra por defecto y bloquea a los clientes remotos hasta que definas una.
