---
title: Hooks de privacidade (censura de dados pessoais)
description: Transformações opcionais plugadas no fluxo de mensagens, para o agente censurar dados pessoais antes que cheguem a um modelo externo e restaurá-los na resposta.
---

Os hooks de privacidade são transformações opcionais plugadas no fluxo de mensagens, para que um agente possa censurar dados pessoais antes que eles cheguem a um modelo externo, e restaurá-los na resposta. Um agente sem hooks roda cru, exatamente como antes.

Você os habilita por agente (com `--hooks`, ou pelo formulário de Agentes no painel), pode herdar um padrão da empresa (`default_hooks`) e configura cada hook uma vez em `"hooks"` na configuração.

## Quatro hooks, um contrato

Eles se compõem, porque cada um alimenta o mesmo mapa reversível:

- **`pii_redact`**: regex offline. Reconhecedores (e-mail, cartão via Luhn, CPF/CNPJ com dígitos verificadores, CEP, telefones) agrupados em pacotes (`intl`, `br`, `us`), mais os seus próprios em `custom` `{name, pattern, replace}`. Ele tokeniza os dados pessoais estruturados e os restaura na saída.
- **`llm_redact`**: um modelo configurado ou local troca os dados pessoais por pseudônimos realistas e devolve um mapa `falso -> real`, mantido consistente entre os turnos. Ele dá conta de nomes e de texto livre que a regex não pega, em qualquer idioma, e mantém os dados longe do modelo principal.
- **`http_redact`**: quem decide é o seu próprio endpoint. O Pepe faz um POST de `{stage, text, session, map}`; você devolve `{text, map}`. A autenticação é via `basic_auth` ou `headers` arbitrários (todos `${ENV}`).
- **`presidio`**: o Analyzer e o Anonymizer do Microsoft Presidio por HTTP (auto-hospedados).

## Usando

```bash
pepe agent add support --hooks pii_redact,llm_redact --company acme --prompt "..."
pepe hooks list
# deixe um modelo montar uma configuração validada de pii_redact a partir de linguagem natural:
pepe hooks generate "cpf, cnpj e os nossos números de apólice APOL-12345678" --model local --save
```

## Uma garantia forte

Marque uma conexão de modelo como **require_redaction** e o runtime se recusa a enviar para ela a menos que o agente rode um hook de censura, então uma configuração de agente esquecida nunca consegue vazar dados pessoais crus para aquele provedor.

<div class="note"><strong>A censura roda fora do processo.</strong> Um hook apoiado em LLM nunca bloqueia a sessão. O mapa reversível vive apenas na memória, e é limpo no reset, no <code>end_session</code> e na expiração por TTL.</div>

O quadro maior, incluindo em que pontos do fluxo a censura acontece e como ela conversa com a barreira de permissão, está na página [Segurança](../security/).
