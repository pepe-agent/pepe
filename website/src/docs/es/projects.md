---
title: Empresas
description: Aísla a un cliente de otro para que una sola instalación pueda atender a varias empresas sin que los datos de una crucen jamás a la otra.
---

## Qué es una empresa

Una empresa es un ámbito de cliente aislado. Una sola instalación puede atender a varios
clientes, y nada cruza de uno a otro: ni archivos, ni enrutamiento, ni claves de modelo.

Las empresas son totalmente opcionales. Sin ninguna empresa, todo vive en el ámbito
**root**, que se comporta exactamente como una instalación de un solo cliente, y root es
el ámbito que usa cada comando cuando omites `--company`. La mayoría de las instalaciones
nunca necesita una empresa. Crea una solo cuando tengas que aislar de verdad a unos
clientes de otros.

<div class="note"><strong>En el panel.</strong> Root aparece como "Principal", y la página
Companies lista cada empresa real que has creado. Root no es una empresa real: nunca
aparece en <code>company list</code>, y no se puede renombrar ni eliminar.</div>

## El handle es la identidad

La identidad real de un agente es su **handle**. En root, el handle es solo el nombre
simple (`sales`). Dentro de una empresa se cualifica como `empresa/nombre`
(`acme/sales`). El mismo nombre simple puede reutilizarse en cada empresa, así que
`acme/sales` y `globex/sales` son dos agentes distintos.

El handle es lo que indexa todo: la entrada de configuración, el directorio del workspace,
las sesiones y las rutas. Por eso el aislamiento no es una funcionalidad aparte, pegada
encima. Se deriva del handle.

### Archivos

El workspace de un agente de empresa es `~/.pepe/companies/<empresa>/agents/<nombre>/` y su
espacio compartido es `~/.pepe/companies/<empresa>/shared/`. Los agentes con el mismo nombre
en empresas distintas nunca escriben en el mismo directorio, y una ruta `shared/...` nunca
se filtra a otro cliente. Los agentes de root mantienen la disposición simple,
`~/.pepe/agents/<nombre>/` y `~/.pepe/shared/`.

### Enrutamiento

`send_to_agent` nunca cruza la frontera de una empresa. Un destino indicado con el nombre
simple se resuelve a un par dentro de la propia empresa de quien envía, y un bloqueo
estricto rechaza cualquier ruta entre empresas, aunque una lista de permisos la pida.

### Modelos y claves

Un agente de empresa resuelve sus modelos primero dentro de su propia empresa y solo después
recurre a root. Así, una empresa puede fijar claves de proveedor privadas que ninguna otra
empresa ve, o heredar un único proveedor global compartido. El agente o el modelo de una
empresa nunca se promueve a predeterminado global, ni siquiera cuando es el primero que se
crea.

## Crear y usar una empresa

```bash
pepe company add acme --description "Acme Inc"
pepe company add globex
pepe company list

# agentes, modelos y rutas aceptan --company
pepe model add llm  --company acme --base-url ... --api-key '${ACME_KEY}' --model ...
pepe agent add sales   --company acme --prompt "..." --can-message support
pepe agent add support --company acme --prompt "..."
pepe agent route sales support --company acme   # ambos se resuelven dentro de acme

pepe agent list --company acme    # solo los de Acme
pepe agent list                   # solo los de root
pepe agent list --all             # todos los ámbitos
pepe chat --company acme sales    # o: pepe run acme/sales "..."
```

## Renombrar y eliminar

```bash
pepe company rename acme umbrella   # reindexa sus agentes, modelos, rutas,
                                    # crons, watches, bots, tokens y archivos
pepe company remove acme            # se niega mientras todavía tenga agentes
pepe company remove acme --force    # la elimina, y se lleva sus agentes también
```

## Cómo queda en la configuración

```jsonc
"companies": { "acme": { "description": "Acme Inc", "default_model": "llm" } },
"agents": {
  "assistant":    { "can_message": [] },          // ámbito root
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Empresas y canales

Un bot de Telegram vinculado a un agente de empresa mantiene toda la conversación dentro de
esa empresa. Un bot vinculado a un agente de root atiende a root, exactamente igual que
antes de que tuvieras empresa alguna.

## Topes de gasto y de mensajes

La empresa es además la unidad que mide la facturación. Cada llamada al modelo se mide por
empresa, y una empresa puede llevar un tope mensual de gasto, un tope mensual de mensajes de
clientes y un margen de facturación. Consulta [Facturación y límites](../billing/) para
definirlos, borrarlos y reiniciarlos, y [Agentes](../agents/) para los campos del agente que
la empresa delimita.
