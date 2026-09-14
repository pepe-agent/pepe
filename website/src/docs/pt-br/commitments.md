---
title: Compromissos
description: Se alguém pede "me lembra sexta", ou o próprio agente diz "vou verificar e te aviso", o Pepe percebe isso sozinho e garante que aconteça.
---

## Compromissos

Um compromisso é diferente de toda outra automação do Pepe porque você não configura ele:
ele nasce sozinho, ao final de um turno, a partir do que foi realmente dito ali, seja o
usuário pedindo para ser lembrado de algo, seja o próprio agente prometendo checar algo e
voltar com a resposta. Ligue isso por agente (`commitments`, desligado por padrão) e dê a
esse agente um `utility_model`; falta um dos dois e nada é extraído, a promessa vira só
palavra.

### Dois tipos de retorno, dois jeitos de entregar

Vale entender essa diferença antes de ligar a funcionalidade, porque os dois casos não são
tratados do mesmo jeito:

- **Um lembrete pedido pelo usuário** ("me lembra de mandar o relatório sexta") se resolve
  com uma mensagem na hora certa, exatamente o que um [watch](../watches/) já faz. Se o seu
  agente tem a tool `watch`, o ideal ainda é que ele recorra a ela diretamente, na hora;
  compromissos funcionam como a rede de segurança para quando isso não acontece.
- **Uma promessa feita pelo próprio agente** ("deixa eu checar o deploy e te falo amanhã")
  não pode ser resolvida com um lembrete avisando que a promessa existiu. Quando o prazo
  chega, o Pepe reexecuta aquela sessão com uma instrução simples: fazer de fato o que foi
  prometido, e só depois responder com o que encontrou. A mensagem que chega é uma resposta
  de verdade, não um texto pronto, então uma promessa nunca vira, em silêncio, um "lembrete:
  eu disse que ia checar isso".

### Confiança, e o que acontece na dúvida

Uma chamada barata a um modelo lê a última troca de mensagens e decide, com uma pontuação
de confiança, se há de fato um compromisso ali. Quando essa confiança é alta e o prazo dá
para resolver, o compromisso já sai agendado, sem nenhum passo extra: é exatamente "perceber
sozinho, sem precisar pedir duas vezes". Abaixo disso, ou quando o prazo não dá para
extrair do que foi dito (um "em breve" vago não é uma data), ele fica **aguardando sua
confirmação**: você é perguntado uma vez, direto, em vez de o sistema ficar rastreando
silenciosamente algo que ninguém pediu de fato.

### Gerenciando pelo chat

A tool `commitment` do agente tem três ações: `list` (o que está sendo acompanhado agora),
`confirm id: <id>` (promove um compromisso que estava aguardando; inclua `due_when` também
se a data nunca tiver sido resolvida) e `cancel id: <id>`.

### Ou pelo dashboard

Abra a página **Compromissos** dentro de `pepe serve` para ver tudo que está sendo
acompanhado, agrupado em aguardando confirmação, agendados e já entregues. Confirmar ou
cancelar é feito direto ali.

<div class="note"><strong>Nenhum servidor para rodar, só um arquivo local.</strong> Compromissos moram num pequeno arquivo SQLite embutido, ao lado do <code>config.json</code>, e não num banco de dados que você precisa instalar ou administrar. O disparo usa o mesmo tipo de timer interno que já move watches e tarefas agendadas, e esse timer só roda enquanto alguma superfície de longa duração estiver de pé (<code>pepe serve</code>, um gateway, ou uma sessão interativa).</div>
