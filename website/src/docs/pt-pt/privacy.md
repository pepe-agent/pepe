---
title: Hooks de privacidade (censura de dados pessoais)
description: Transformações opcionais ligadas ao fluxo de mensagens, para o agente censurar dados pessoais antes de chegarem a um modelo externo e restaurá-los na resposta.
---

Os hooks de privacidade são transformações opcionais ligadas ao fluxo de mensagens, para que um agente possa censurar dados pessoais antes de eles chegarem a um modelo externo, e restaurá-los na resposta. Um agente sem hooks corre em cru, exatamente como antes.

Ativa-os por agente (com `--hooks`, ou pelo formulário de Agentes no painel), podes herdar uma predefinição da empresa (`default_hooks`), e configuras cada hook uma vez em `"hooks"` na configuração.

## Quatro hooks, um contrato

Compõem-se, porque cada um alimenta o mesmo mapa reversível:

- **`pii_redact`**: regex offline. Reconhecedores (email, cartão via Luhn, CPF/CNPJ com dígitos de controlo, CEP, telefones) agrupados em pacotes (`intl`, `br`, `us`), mais os teus próprios em `custom` `{name, pattern, replace}`. Tokeniza os dados pessoais estruturados e restaura-os à saída.
- **`llm_redact`**: um modelo configurado ou local substitui os dados pessoais por pseudónimos realistas e devolve um mapa `falso -> real`, mantido coerente ao longo dos turnos. Dá conta de nomes e de texto livre que a regex não apanha, em qualquer língua, e mantém os dados longe do modelo principal.
- **`http_redact`**: quem decide é o teu próprio endpoint. O Pepe faz POST de `{stage, text, session, map}`; tu devolves `{text, map}`. A autenticação é via `basic_auth` ou `headers` arbitrários (todos `${ENV}`).
- **`presidio`**: o Analyzer e o Anonymizer do Microsoft Presidio por HTTP (alojados por ti).

## Utilização

```bash
pepe agent add support --hooks pii_redact,llm_redact --company acme --prompt "..."
pepe hooks list
# deixa um modelo montar uma configuração validada de pii_redact a partir de linguagem natural:
pepe hooks generate "cpf, cnpj e os nossos números de apólice APOL-12345678" --model local --save
```

## Uma garantia forte

Marca uma ligação de modelo como **require_redaction** e o runtime recusa-se a enviar para ela a não ser que o agente corra um hook de censura, por isso uma configuração de agente esquecida nunca consegue deixar fugir dados pessoais em cru para esse fornecedor.

<div class="note"><strong>A censura corre fora do processo.</strong> Um hook apoiado num LLM nunca bloqueia a sessão. O mapa reversível vive apenas em memória, e é limpo no reset, no <code>end_session</code> e na expiração por TTL.</div>

O quadro mais amplo, incluindo em que pontos do fluxo a censura acontece e como se articula com a barreira de permissão, está na página [Segurança](../security/).
