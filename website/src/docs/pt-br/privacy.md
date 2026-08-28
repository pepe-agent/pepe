---
title: Hooks de privacidade (censura de dados pessoais)
description: Deixe um agente tirar dados pessoais das mensagens antes que elas cheguem a um modelo externo, e devolver os valores reais na resposta. Vem desligado, você liga por agente.
---

Hooks de privacidade deixam um agente limpar dados pessoais (nome, e-mail, número de documento) do fluxo de mensagens antes que qualquer coisa chegue a um modelo externo, devolvendo os valores reais só na resposta final. São opcionais: sem nenhum hook ligado, o agente roda cru, exatamente como sempre rodou.

Você liga isso por agente (com `--hooks`, ou pelo formulário de Agentes no painel), pode herdar um padrão de projeto inteiro (`default_hooks`), e configura cada hook uma única vez, em `"hooks"` dentro da configuração.

## Quatro hooks, um único contrato

Dá para combinar os quatro, porque todos alimentam o mesmo mapa reversível: o registro de o que foi trocado pelo quê, usado depois para restaurar os valores reais na saída.

- **`pii_redact`**: casamento de padrões (regex) rodando inteiro na sua própria máquina, sem nada saindo para fora. Reconhecedores de e-mail, cartão (via Luhn), CPF/CNPJ (com dígito verificador), CEP e telefone, agrupados em pacotes (`intl`, `br`, `us`), mais os seus próprios em `custom` com `{name, pattern, replace}`. Troca dado pessoal estruturado por token, e restaura na saída.
- **`llm_redact`**: um modelo, configurado ou local, troca dados pessoais por pseudônimos realistas e devolve um mapa `falso -> real`, mantido consistente ao longo dos turnos. Dá conta de nomes e texto livre que a regex não pega, em qualquer idioma, e mantém esse dado longe do modelo principal.
- **`http_redact`**: quem decide é o seu próprio endpoint. O Pepe manda um POST com `{stage, text, session, map}`, e você devolve `{text, map}`. Autentica por `basic_auth` ou por `headers` arbitrários (sempre como `${ENV}`).
- **`presidio`**: o Analyzer e o Anonymizer do Microsoft Presidio, por HTTP, auto-hospedados.

## Usando

```bash
pepe agent add support --hooks pii_redact,llm_redact --project acme --prompt "..."
pepe hooks list
# deixe um modelo montar uma configuração validada de pii_redact a partir de linguagem simples:
pepe hooks generate "cpf, cnpj e os nossos números de apólice APOL-12345678" --model local --save
```

## Uma garantia que não tem furo

Marque uma conexão de modelo como **require_redaction** e o runtime passa a recusar qualquer envio para ela enquanto o agente não estiver rodando um hook de censura, então nem um agente mal configurado consegue vazar dado pessoal cru para aquele provedor.

<div class="note"><strong>A censura nunca prende a conversa.</strong> Um hook apoiado em modelo roda ao lado da sessão, fora do processo principal, e por isso nunca segura uma resposta. O mapa reversível existe só na memória, e é apagado no reset, no <code>end_session</code> e quando o TTL expira.</div>

O quadro completo, incluindo em que ponto do fluxo a censura entra e como ela se relaciona com a barreira de permissão, está na página de [Segurança](../security/).
