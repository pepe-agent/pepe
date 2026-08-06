---
title: Hooks de privacidade (censura de dados pessoais)
description: Faça um agente remover dados pessoais das mensagens antes que elas cheguem a um modelo externo, e devolver os valores reais na resposta. Desligado por padrão, habilitado por agente.
---

Os hooks de privacidade deixam um agente limpar dados pessoais (nomes, e-mails, números de documento) do fluxo de mensagens antes que qualquer coisa chegue a um modelo externo, e devolver os valores reais na resposta. Eles são opcionais: um agente sem hooks roda cru, exatamente como antes.

Você os habilita por agente (com `--hooks`, ou pelo formulário de Agentes no painel), pode herdar um padrão do projeto (`default_hooks`) e configura cada hook uma vez em `"hooks"` na configuração.

## Quatro hooks, um contrato

Você pode combiná-los, porque todos alimentam o mesmo mapa reversível: o registro do que foi trocado pelo quê, usado para restaurar os valores reais na saída.

- **`pii_redact`**: casamento de padrões (regex) que roda inteiro na sua máquina, nada é enviado a lugar nenhum. Reconhecedores (e-mail, cartão via Luhn, CPF/CNPJ com dígitos verificadores, CEP, telefones) agrupados em pacotes (`intl`, `br`, `us`), mais os seus próprios em `custom` `{name, pattern, replace}`. Ele troca os dados pessoais estruturados por tokens e os restaura na saída.
- **`llm_redact`**: um modelo configurado ou local troca os dados pessoais por pseudônimos realistas e devolve um mapa `falso -> real`, mantido consistente entre os turnos. Ele dá conta de nomes e de texto livre que a regex não pega, em qualquer idioma, e mantém os dados longe do modelo principal.
- **`http_redact`**: quem decide é o seu próprio endpoint. O Pepe faz um POST de `{stage, text, session, map}`; você devolve `{text, map}`. A autenticação é via `basic_auth` ou `headers` arbitrários (todos `${ENV}`).
- **`presidio`**: o Analyzer e o Anonymizer do Microsoft Presidio por HTTP (auto-hospedados).

## Usando

```bash
pepe agent add support --hooks pii_redact,llm_redact --project acme --prompt "..."
pepe hooks list
# deixe um modelo montar uma configuração validada de pii_redact a partir de linguagem natural:
pepe hooks generate "cpf, cnpj e os nossos números de apólice APOL-12345678" --model local --save
```

## Uma garantia forte

Marque uma conexão de modelo como **require_redaction** e o runtime se recusa a enviar para ela a menos que o agente rode um hook de censura, então uma configuração de agente esquecida nunca consegue vazar dados pessoais crus para aquele provedor.

<div class="note"><strong>A censura nunca atrasa a conversa.</strong> Um hook apoiado em LLM roda ao lado da sessão, não dentro dela (fora do processo), então nunca segura uma resposta. O mapa reversível vive apenas na memória, e é limpo no reset, no <code>end_session</code> e na expiração por TTL.</div>

O quadro maior, incluindo em que pontos do fluxo a censura acontece e como ela conversa com a barreira de permissão, está na página [Segurança](../security/).
