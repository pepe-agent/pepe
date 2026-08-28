---
title: Hooks de privacidade (censura de dados pessoais)
description: Faz um agente retirar dados pessoais das mensagens antes de estas chegarem a um modelo externo, e repõe os valores reais na resposta. Desligado por predefinição, ativa-se agente a agente.
---

Os hooks de privacidade deixam um agente limpar dados pessoais (nomes, emails, números de documento) do fluxo de mensagens antes de qualquer coisa chegar a um modelo externo, repondo depois os valores reais na resposta. São opt-in: um agente sem hooks continua a correr em cru, exatamente como antes desta funcionalidade existir.

Ativam-se agente a agente (com `--hooks`, ou pelo formulário de Agentes no painel), podes herdar uma predefinição do projeto (`default_hooks`), e cada hook configura-se uma única vez em `"hooks"`, na configuração.

## Quatro hooks, um único contrato

Podes combiná-los à vontade, porque todos alimentam o mesmo mapa reversível: o registo do que foi substituído por o quê, usado depois para repor os valores reais na saída.

- **`pii_redact`**: correspondência de padrões (regex) que corre inteiramente na tua máquina, sem nada a sair para fora. Reúne reconhecedores (email, cartão via Luhn, CPF/CNPJ com dígitos de controlo, código postal, telefones) agrupados em pacotes (`intl`, `br`, `us`), além dos teus próprios padrões `custom` no formato `{name, pattern, replace}`. Substitui os dados pessoais estruturados por tokens e repõe-nos depois na saída.
- **`llm_redact`**: um modelo, configurado ou local, substitui os dados pessoais por pseudónimos plausíveis e devolve um mapa `falso -> real`, mantido coerente ao longo dos turnos seguintes. Dá conta de nomes e de texto livre que a regex não apanha, em qualquer língua, e mantém esses dados longe do modelo principal.
- **`http_redact`**: quem decide é o teu próprio endpoint. O Pepe envia um POST com `{stage, text, session, map}`, e tu devolves `{text, map}`. A autenticação faz-se por `basic_auth` ou por `headers` arbitrários (sempre como `${ENV}`).
- **`presidio`**: o Analyzer e o Anonymizer do Microsoft Presidio, por HTTP, alojados por ti.

## Como se usam

```bash
pepe agent add support --hooks pii_redact,llm_redact --project acme --prompt "..."
pepe hooks list
# deixa um modelo montar uma configuração de pii_redact já validada, a partir de linguagem corrente:
pepe hooks generate "cpf, cnpj e os nossos números de apólice APOL-12345678" --model local --save
```

## Uma garantia sem margem para falhas

Marca uma ligação de modelo como **require_redaction** e o runtime recusa-se a enviar-lhe fosse o que fosse enquanto o agente não correr um hook de censura, o que impede uma configuração de agente esquecida de deixar escapar dados pessoais em cru para esse fornecedor.

<div class="note"><strong>A censura nunca trava a conversa.</strong> Um hook apoiado num modelo corre ao lado da sessão, fora do processo principal, e por isso nunca bloqueia uma resposta. O mapa reversível existe só em memória, e é limpo no reset, no <code>end_session</code> e na expiração por TTL.</div>

O panorama mais alargado, incluindo em que ponto exato do fluxo a censura acontece e como se articula com a barreira de permissão, fica na página [Segurança](../security/).
