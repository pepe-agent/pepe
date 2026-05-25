---
title: Enrutamiento entre agentes
description: Deja que un agente pase trabajo a otro con la herramienta send_to_agent, bajo una lista de rutas permitidas dirigida que dice exactamente quién puede llamar a quién.
---

Los agentes pueden hablarse entre sí mediante la herramienta `send_to_agent`. Quién
puede llamar a quién lo decide una **lista de rutas permitidas dirigida**: el campo
`can_message` de cada agente enumera los agentes a los que *él* puede enviar mensajes.
Una ruta de `triage` a `billing` no implica una ruta de `billing` de vuelta a `triage`.

Cuando un agente enruta un mensaje, el agente llamado responde en una ejecución nueva, y
su respuesta vuelve a quien llamó como resultado de la herramienta. Un límite de saltos
y una comprobación de ciclos evitan que las cadenas de llamadas se queden en bucle.

## Crear una ruta

```bash
# triage pasa trabajo a billing; billing puede escalar a refunds
pepe agent route triage billing
pepe agent route triage refunds
pepe agent route billing refunds

# revocar una ruta
pepe agent route triage billing --remove

# o defínelo al crear el agente
pepe agent add triage --model mock --can-message billing,refunds
```

Las rutas se guardan en `~/.pepe/config.json`, en la lista `can_message` de cada agente:

```jsonc
"agents": {
  "triage":  { "can_message": ["billing", "refunds"] },
  "billing": { "can_message": ["refunds"] },
  "refunds": { "can_message": [] }
}
```

`refunds` tiene un `can_message` vacío, así que responde cuando lo llaman, pero no puede
llamar a nadie de vuelta. Como la lista es dirigida, conceder la ruta de `billing` a
`refunds` no concede nada en el sentido inverso.

El agente también necesita tener `send_to_agent` en su lista de `tools` para poder
enrutar. La lista de rutas permitidas decide a quién puede llamar, y la herramienta es lo
que le permite hacer la llamada.

<div class="note"><strong>Fronteras de proyecto.</strong> Las rutas nunca cruzan la
frontera de un proyecto. Los nombres simples en <code>--can-message</code> se resuelven
dentro del propio proyecto del agente, y la CLI rechaza una ruta entre dos agentes que
viven en proyectos distintos.</div>

## El enrutamiento y la barrera de permisos

La lista de rutas permitidas *es* la autorización de la llamada. El operador ya decidió,
en la configuración, que este agente puede enviar mensajes a aquel agente, así que la
llamada a `send_to_agent` no pasa por la barrera de permisos humana. Simplemente se
ejecuta.

Por eso mismo la lista es dirigida y está cerrada por defecto, en lugar de ser simétrica
y abierta. La concesión es estrecha y explícita, un sentido cada vez, y eso es lo que
hace seguro permitir una llamada sin barrera. Una lista simétrica le entregaría en
silencio al agente llamado una ruta de vuelta hacia quien lo llamó, sin que nadie la
hubiera pedido.

Las herramientas de riesgo del agente llamado son otra cuestión, y siguen con barrera.
Cuando `billing` ejecuta `bash` o `write_file`, esa llamada pasa por la barrera de
permisos igual que lo haría si hubieras hablado con `billing` tú mismo. El enrutamiento
deja que un agente alcance a otro, pero nunca blanquea los permisos de ese otro agente.

## Cambiar rutas por chat

Dale a un agente la herramienta `set_route` y podrá añadir o quitar rutas conversando,
guiado por la skill integrada `manage-routing`. La herramienta recibe
`{from, to, action}`, y `from` toma por defecto el propio agente que llama.

```text
Permítete a ti mismo enviar mensajes al agente billing.
```

El agente llama a `set_route` con `action: "allow"` y `to: "billing"`. Como esto edita la
configuración, `set_route` sí pasa por la barrera de permisos: tú autorizas la nueva ruta
antes de que se escriba en disco. El enrutamiento sigue siendo dirigido, así que permitir
esta ruta no deja que `billing` responda por iniciativa propia.
