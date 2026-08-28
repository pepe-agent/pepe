---
title: Hooks de privacidad (censura de datos personales)
description: Haz que un agente elimine datos personales de los mensajes antes de que lleguen a un modelo externo, y los restaure en la respuesta. Desactivado por defecto, se activa por agente.
---

Los hooks de privacidad dejan que un agente borre datos personales (PII: nombres, correos, números de documento) del flujo de mensajes antes de que nada llegue a un modelo externo, y que luego restaure los valores reales en la respuesta. Son opcionales: un agente sin hooks funciona en crudo, tal como lo hacía antes de que existieran.

Los activas por agente (con `--hooks`, o desde el formulario de Agentes del panel), puedes heredar un valor por defecto del proyecto (`default_hooks`), y cada hook se configura una sola vez bajo `"hooks"` en la configuración.

## Cuatro hooks, un mismo contrato

Puedes combinarlos porque todos alimentan el mismo mapa reversible: el registro de qué se reemplazó por qué, que se usa para restaurar los valores reales a la salida.

- **`pii_redact`**: coincidencia de patrones (regex) que corre enteramente en tu máquina, sin enviar nada a ningún lado. Trae reconocedores (correo, tarjeta vía Luhn, CPF/CNPJ con dígitos de control, CEP, teléfonos) agrupados en paquetes (`intl`, `br`, `us`), más los tuyos propios en `custom` con `{name, pattern, replace}`. Sustituye los datos personales estructurados por tokens y los restaura a la salida.
- **`llm_redact`**: un modelo, configurado o local, reemplaza los datos personales por seudónimos realistas y devuelve un mapa `falso -> real` que se mantiene coherente entre turnos. Se encarga de los nombres y del texto libre que el regex no puede cubrir, en cualquier idioma, y mantiene esos datos fuera del modelo principal.
- **`http_redact`**: decide tu propio endpoint. Pepe le hace un POST con `{stage, text, session, map}`; tú devuelves `{text, map}`. La autenticación va por `basic_auth` o por `headers` arbitrarios (todos como `${ENV}`).
- **`presidio`**: el Analyzer y el Anonymizer de Microsoft Presidio por HTTP, autoalojados.

## Cómo se usan

```bash
pepe agent add support --hooks pii_redact,llm_redact --project acme --prompt "..."
pepe hooks list
# deja que un modelo arme una configuración validada de pii_redact a partir de una descripción en lenguaje natural:
pepe hooks generate "cpf, cnpj y nuestros números de póliza APOL-12345678" --model local --save
```

## Una garantía firme

Marca una conexión de modelo como **require_redaction** y el runtime se niega a enviarle nada a menos que el agente tenga corriendo un hook de censura, de modo que una configuración de agente olvidada nunca pueda filtrar datos personales en crudo a ese proveedor.

<div class="note"><strong>La censura nunca frena la conversación.</strong> Un hook respaldado por un LLM corre en paralelo a la sesión, no dentro de ella (fuera de proceso), así que jamás bloquea una respuesta. El mapa reversible vive solo en memoria, y se borra al reiniciar, al llamar a <code>end_session</code> y al expirar el TTL.</div>

El panorama completo, incluyendo en qué punto del flujo ocurre la censura y cómo interactúa con la barrera de permisos, está en la página de [Seguridad](../security/).
