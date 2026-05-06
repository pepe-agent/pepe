---
title: Instalación
description: Instala Pepe y ejecuta la configuración guiada antes de crear agentes.
---

Instala el binario `pepe` y ejecuta la configuración guiada. Crea el archivo de
configuración, conecta un modelo y crea el primer agente.

## 1. Instalación

Un solo comando instala el binario `pepe`.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Comprueba que quedó instalado:

```bash
pepe help
```

Pepe guarda la configuración en `~/.pepe/config.json`. No hay base de datos que
ejecutar.

## 2. Configuración guiada (el camino rápido)

`pepe setup` pasa por autenticación del proveedor, elección de modelo, primer
agente y canales opcionales.

```bash
pepe setup
```

Si prefieres hacerlo manualmente, usa las páginas de modelos, agentes y canales.
Los dos caminos escriben la misma configuración.

<div class="note"><strong>Los secretos se quedan fuera del archivo.</strong> Cuando Pepe te pide una clave de API acepta una referencia <code>${ENV_VAR}</code>, por ejemplo <code>${OPENROUTER_API_KEY}</code>. Lo que se escribe en <code>~/.pepe/config.json</code> es la referencia. El valor real se lee de tu entorno en tiempo de ejecución y nunca se guarda expandido.</div>

## Docker

¿Prefieres un contenedor? `docker pull ghcr.io/pepe-agent/pepe` (amd64 y arm64). Necesita un
volumen y una contraseña del panel: ambos están explicados, junto con cómo darle
herramientas extra al agente dentro del contenedor, en la [página de Docker](/es/docs/docker/).

## Desinstalar

Elimina el binario; borra también la carpeta de configuración para descartar
todo modelo, agente y credencial que hayas configurado.

```bash
rm ~/.local/bin/pepe
rm -rf ~/.pepe   # opcional - también descarta tu configuración
```

(`~/.local/bin` es la carpeta de instalación predeterminada; si la
sobrescribiste con `$PEPE_BIN_DIR`, es ahí donde apunte.)
