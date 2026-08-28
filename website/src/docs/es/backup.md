---
title: Copia de seguridad y extracción
description: Archiva la instalación completa, o saca un proyecto para que corra en su propio servidor, y restaura cualquiera de las dos con un solo comando.
---

Todo lo que Pepe sabe vive como archivos bajo `~/.pepe/` (o `PEPE_HOME`), así que moverlo es simplemente mover un directorio. Dos comandos generan un paquete comprimido de eso, y uno restaura cualquiera de los dos.

## Copia de seguridad: la instalación completa

```bash
pepe backup                       # genera pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /ruta/x.tgz
```

Este es el archivo del tipo "que no se pierda esta máquina". Empaqueta todos los proyectos, todos los espacios de trabajo de los agentes, el espacio compartido, las sesiones y los libros de uso, y deja fuera `data/mnesia/` (una caché desechable que se reconstruye sola). Restaurado en una máquina vacía, el resultado es la misma máquina de antes.

Puedes ejecutarlo con Pepe corriendo. La base de datos (compromisos, watches, traces, boards, uso) jamás se copia mientras podría estar a mitad de una escritura: en vez de eso, `backup` toma una instantánea a través de la conexión activa, garantizada consistente en un instante preciso (consistencia transaccional), y la verifica antes de meterla en el archivo. Si la verificación falla, el comando aborta en lugar de enviar una instantánea rota. Para volver a comprobar un archivo que ya tienes:

```bash
pepe backup verify pepe-backup-2026-07-14.tgz
```

## Extracción: un proyecto por su cuenta

```bash
pepe extract acme                 # genera acme-extract-YYYY-MM-DD.tgz
pepe extract acme --output /ruta/acme.tgz
```

Un proyecto que creció dentro de una instalación compartida puede independizarse y correr en su propio servidor. No basta con copiar una carpeta, porque los registros de ese proyecto quedan entrelazados en el `config.json` compartido como handles del tipo `acme/agente`. La extracción reescribe esos handles a los nombres simples de un proyecto por defecto recién creado, de modo que el archivo resultante es en realidad **una instalación nueva de un solo cliente que da la casualidad de ser ese proyecto**: lo dejas caer en un servidor nuevo y lo ejecutas.

Solo viaja ese proyecto: sus agentes, modelos, crons, watches, bots, tokens, espacios de trabajo e historial de uso. Nada de los demás clientes se lleva. Si alguno de sus agentes depende de un **modelo compartido** (uno que vive en el proyecto por defecto, no dentro de este), ese modelo también se incorpora al archivo para que el paquete funcione en una máquina vacía, y el comando te indica cuáles fueron.

## Restauración: cualquiera de los dos archivos

```bash
pepe restore acme-extract-2026-07-14.tgz
pepe restore pepe-backup-2026-07-14.tgz --force
```

Una copia de seguridad y una extracción tienen la misma forma (un `~/.pepe` dentro de un tarball), así que un solo comando restaura ambas. Todo se descomprime en `~/.pepe` (o `PEPE_HOME`). Como una restauración **reemplaza** lo que ya hay ahí, se niega a escribir sobre un directorio que no esté vacío a menos que pases `--force`.

La base de datos de una copia de seguridad pasa por la misma verificación de integridad al volver a entrar: la restauración rechaza una base de datos que no la supere, y también rechaza sobrescribir una sobre la que una instancia de Pepe en marcha parece estar escribiendo en ese momento. En ese caso, detenla primero y vuelve a intentarlo.

## Los secretos nunca van en el archivo

Los secretos son referencias `${ENV_VAR}` que se resuelven al leerlas, así que viven en tu entorno y nunca en los archivos (consulta [Secretos](/es/docs/secrets/)). Por eso, tanto una copia de seguridad como una extracción **no** los incluyen, y esto es intencional. Cada uno de estos comandos imprime qué variables referencia el archivo y si cada una está definida en ese momento, para que puedas provisionarlas en el destino. Vuelve a exportarlas ahí y la configuración se resuelve sola; si olvidas alguna, lo que esa variable desbloqueaba simplemente no estará disponible.
