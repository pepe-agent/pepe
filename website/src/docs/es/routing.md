---
title: Enrutamiento entre agentes
description: Con la herramienta send_to_agent, un agente pasa trabajo a otro. Tú decides con exactitud quién puede llamar a quién, y en qué sentido.
---

Los agentes pueden comunicarse entre sí a través de la herramienta `send_to_agent`. Quién
tiene permiso para llamar a quién queda definido por una **lista de rutas dirigida**: el
campo `can_message` de cada agente enumera a quiénes puede escribirles *ese* agente en
concreto. Que exista una ruta de `triage` hacia `billing` no significa que también exista
la ruta inversa, de `billing` hacia `triage`.

Cada vez que un agente enruta un mensaje, el agente destino responde en una ejecución
nueva, y esa respuesta llega de vuelta al que llamó como resultado de la herramienta. Un
límite de saltos junto con una comprobación de ciclos evita que estas cadenas de llamadas
entren en un bucle infinito.

Algo que `send_to_agent` nunca hace es cambiar con quién habla el usuario en realidad: es
una consulta puntual, así que el agente que llamó sigue siendo el que lleva la
conversación. Para entregar la conversación **completa** a otro agente existe una
herramienta distinta, `switch_agent`, que se explica más adelante.

## Crear una ruta

```bash
# triage pasa trabajo a billing; billing puede escalar a refunds
pepe agent route triage billing
pepe agent route triage refunds
pepe agent route billing refunds

# revocar una ruta
pepe agent route triage billing --remove

# o definirla directamente al crear el agente
pepe agent add triage --model mock --can-message billing,refunds
```

Estas rutas quedan guardadas en `~/.pepe/config.json`, dentro de la lista `can_message` de
cada agente:

```jsonc
"agents": {
  "triage":  { "can_message": ["billing", "refunds"] },
  "billing": { "can_message": ["refunds"] },
  "refunds": { "can_message": [] }
}
```

`refunds` tiene un `can_message` vacío: responde cuando otro agente lo llama, pero no
puede iniciar llamadas propias. Y como la lista es dirigida, dar de alta la ruta de
`billing` hacia `refunds` no otorga nada en el sentido contrario.

Para poder enrutar, el agente también necesita tener `send_to_agent` entre sus `tools`. La
lista de rutas decide a quién puede dirigirse; la herramienta es lo que le permite hacer
la llamada en sí.

<div class="note"><strong>Los proyectos son fronteras.</strong> Ninguna ruta cruza de un
proyecto a otro. Un nombre simple en <code>--can-message</code> se resuelve dentro del
propio proyecto del agente, y la CLI rechaza cualquier ruta entre dos agentes que
pertenezcan a proyectos distintos.</div>

## Entregar toda la conversación (`switch_agent`)

Si `send_to_agent` sirve para una consulta puntual, `switch_agent` cubre el otro caso: el
agente que está respondiendo en este momento le cede **el resto de la conversación** a
otro agente. El resultado es idéntico a que el propio usuario escribiera `/agent NOMBRE`,
solo que se puede activar con una petición en lenguaje natural ("ponme con billing",
"quiero hablar directo con soporte") en vez de necesitar el comando de barra.

```text
Ponme directamente con el agente de billing.
```

El agente llama a `switch_agent` con `target: "billing"`. La respuesta a *este* turno
todavía sale del agente que venía respondiendo ("listo, te conecto ahora"); el cambio no
entra en vigor hasta el siguiente mensaje, igual que ya ocurre con `/agent`. El agente
nuevo arranca con el contexto en blanco: no hereda el historial de la conversación
anterior.

`switch_agent` reutiliza la misma lista `can_message` de `send_to_agent`: si un agente
puede escribirle a otro, también puede cederle la conversación, sin necesidad de dar de
alta una ruta aparte. La diferencia es que, por defecto, `switch_agent` **sí** pasa por la
barrera de permisos habitual: está cambiando quién responderá cada mensaje de ahí en
adelante, una decisión de mayor peso que una persona podría aprobar sin darse cuenta si
no se le marca explícitamente.

## Cómo encaja el enrutamiento con la barrera de permisos

La propia lista de rutas funciona como autorización para la llamada a `send_to_agent`. El
operador ya decidió, en la configuración, que este agente puede escribirle a aquel otro,
así que esa llamada puntual no vuelve a pasar por la barrera de permisos: simplemente se
ejecuta.

Y es justo por eso que la lista es dirigida y parte cerrada, en lugar de ser simétrica y
abierta. El permiso es estrecho y explícito, un sentido a la vez, lo que hace seguro
dejarla pasar sin barrera. Una lista simétrica, en cambio, le regalaría en silencio al
agente llamado una ruta de vuelta hacia quien lo llamó, algo que nadie pidió.

Las herramientas riesgosas del agente destino son otro tema, y siguen con su propia
barrera. Si `billing` ejecuta `bash` o `write_file`, esa llamada pasa por la barrera de
permisos exactamente igual que si hubieras hablado con `billing` directamente. El
enrutamiento le da a un agente acceso a otro, pero nunca le lava los permisos.

## Cambiar rutas desde el chat

Si le das a un agente la herramienta `set_route`, podrá agregar o quitar rutas
conversando, guiado por la skill integrada `manage-routing`. La herramienta recibe
`{from, to, action}`, donde `from` toma por defecto al agente que hace la llamada.

```text
Date permiso a ti mismo para escribirle al agente de billing.
```

El agente llama a `set_route` con `action: "allow"` y `to: "billing"`. Como esta acción
modifica la configuración, `set_route` sí pasa por el aviso de permisos: tú autorizas la
ruta nueva antes de que quede escrita en disco. El enrutamiento sigue siendo dirigido, así
que aprobar esta ruta no habilita que `billing` te responda por su cuenta.
