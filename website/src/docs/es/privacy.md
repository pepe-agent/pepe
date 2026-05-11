---
title: Hooks de privacidad (censura de datos personales)
description: Transformaciones opcionales enchufadas al flujo de mensajes, para que el agente censure datos personales antes de que lleguen a un modelo externo y los restaure en la respuesta.
---

Los hooks de privacidad son transformaciones opcionales enchufadas al flujo de mensajes, para que un agente pueda censurar datos personales antes de que lleguen a un modelo externo, y restaurarlos en la respuesta. Un agente sin hooks funciona en crudo, exactamente como antes.

Los habilitas por agente (con `--hooks`, o desde el formulario de Agentes del panel), puedes heredar un valor por defecto de la empresa (`default_hooks`), y configuras cada hook una sola vez bajo `"hooks"` en la configuración.

## Cuatro hooks, un contrato

Se componen, porque cada uno alimenta el mismo mapa reversible:

- **`pii_redact`**: regex offline. Reconocedores (correo, tarjeta vía Luhn, CPF/CNPJ con dígitos de control, CEP, teléfonos) agrupados en paquetes (`intl`, `br`, `us`), más los tuyos propios en `custom` `{name, pattern, replace}`. Tokeniza los datos personales estructurados y los restaura a la salida.
- **`llm_redact`**: un modelo configurado o local sustituye los datos personales por seudónimos realistas y devuelve un mapa `falso -> real`, mantenido coherente entre turnos. Se ocupa de los nombres y del texto libre que la regex no puede, en cualquier idioma, y mantiene los datos fuera del modelo principal.
- **`http_redact`**: decide tu propio endpoint. Pepe hace un POST de `{stage, text, session, map}`; tú devuelves `{text, map}`. La autenticación va por `basic_auth` o por `headers` arbitrarios (todos `${ENV}`).
- **`presidio`**: el Analyzer y el Anonymizer de Microsoft Presidio por HTTP (autoalojados).

## Cómo se usan

```bash
pepe agent add support --hooks pii_redact,llm_redact --company acme --prompt "..."
pepe hooks list
# deja que un modelo construya una configuración validada de pii_redact a partir de lenguaje natural:
pepe hooks generate "cpf, cnpj y nuestros números de póliza APOL-12345678" --model local --save
```

## Una garantía dura

Marca una conexión de modelo como **require_redaction** y el runtime se niega a enviarle nada a menos que el agente ejecute un hook de censura, de modo que una configuración de agente olvidada nunca puede filtrar datos personales en crudo a ese proveedor.

<div class="note"><strong>La censura se ejecuta fuera del proceso.</strong> Un hook respaldado por un LLM nunca bloquea la sesión. El mapa reversible vive solo en memoria, y se borra en el reset, en <code>end_session</code> y al expirar el TTL.</div>

El cuadro completo, incluyendo en qué puntos del flujo ocurre la censura y cómo se relaciona con la barrera de permisos, está en la página [Seguridad](../security/).
