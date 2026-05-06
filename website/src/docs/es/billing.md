---
title: Facturación y límites
description: Limita el gasto o el volumen de mensajes mensual de una empresa, aplica un margen a lo que facturas, y reinicia un tope antes de tiempo.
---

## Facturación y límites

Cada llamada al modelo se mide por empresa (consulta Agentes para entender qué es una empresa y cómo crear una). Además de esa medición, una empresa puede llevar opcionalmente dos topes mensuales independientes, más un margen de facturación:

- **Tope de gasto** (`--budget`) - un límite estricto en tu moneda configurada. En cuanto el total facturable del mes lo alcanza, los agentes de esa empresa dejan de hacer nuevas llamadas al modelo hasta que el tope se reinicie.
- **Tope de mensajes** (`--message-limit`) - un límite estricto en mensajes originados por clientes. En cuanto se alcanza, los agentes de esa empresa dejan de responder a nuevos mensajes hasta que se reinicie.
- **Margen** (`--markup`) - un multiplicador aplicado sobre el coste del proveedor para llegar al importe que cobras al cliente (p. ej., `1.3` = coste del proveedor +30%). Sin definir, facturas exactamente el coste del proveedor.

Los tres son opcionales e independientes: define cualquiera de ellos, todos, o ninguno. Root (el ámbito predeterminado, sin empresa) puede llevar los mismos topes, definidos con `pepe company set root ...`. Root no es una empresa real (nunca aparece en `company list`, no se puede renombrar ni eliminar), pero tampoco está excluido de los límites de facturación.

### Qué cuenta para el tope de mensajes

El tope de mensajes cuenta **un mensaje del cliente, una vez**, no cada llamada al modelo que hace falta para responderlo. Si un agente llama a tres herramientas antes de responder, eso sigue siendo un mensaje contra el tope, igual que es un mensaje en el chat. Las iteraciones del bucle de llamadas a herramientas, las ejecuciones de cron, los mensajes de agente a agente y los heartbeats nunca cuentan.

Solo cuenta mensajes provenientes de superficies orientadas al cliente: Telegram, WhatsApp y otros canales por webhook, el widget incrustable. Excluye deliberadamente la consola TUI, el chat de prueba propio del panel, y la API HTTP, ya que esos son el operador usando su propio runtime, no un cliente enviándole mensajes.

Un agente individual puede quedar exento del tope de mensajes por completo, lo que resulta útil para algo como un agente de escalado siempre activo que nunca debe quedarse callado solo porque el resto de la empresa alcanzó el tope:

```bash
pepe agent add escalation --exempt-message-limit
```

Hoy no hay forma desde la consola de activar esa opción en un agente que ya existe sin tocar el resto de su configuración, ya que `agent add` reemplaza toda la definición del agente en lugar de corregir un solo campo. Cámbialo desde la página de edición del agente en el panel.

### Configurar los topes

```bash
pepe company set acme --budget 100
pepe company set acme --message-limit 5000
pepe company set acme --budget 100 --message-limit 5000 --markup 1.3
```

`company set` solo modifica las opciones que pases; el resto de la configuración de la empresa queda intacta. Pasa `none` para borrar un tope:

```bash
pepe company set acme --budget none
```

Los mismos campos son editables desde la página Companies del panel.

### Reiniciar un tope antes de tiempo

Un tope se reinicia naturalmente al comienzo de cada mes de facturación, pero no hace falta esperar:

```bash
pepe company reset-budget acme
pepe company reset-messages acme
```

La página Companies del panel tiene los mismos dos botones junto al indicador de cada tope, con una confirmación que muestra el recuento actual antes de reiniciar.

Un reinicio no borra nada; solo marca un punto de corte. El gasto o los mensajes registrados antes del reinicio siguen en el ledger; simplemente dejan de contar para el tope de ahí en adelante. Esto importa por un motivo concreto: **el indicador del tope de gasto y el botón de reinicio solo afectan al recuento operativo usado para bloquear nuevas llamadas al modelo.** El registro de facturación real del mes, lo que le facturarías a un cliente, vive en Usage y siempre refleja el total real, reiniciado o no. Si reinicias el tope de gasto de una empresa a mitad de mes, el indicador de la página Companies mostrará un número menor que la página Usage para ese mismo mes; eso es lo esperado, no una inconsistencia, ya que responden a preguntas distintas ("¿se ha limitado esta empresa desde el último reinicio?" frente a "¿cuánto costó realmente esta empresa este mes?").
