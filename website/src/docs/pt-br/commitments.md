---
title: Compromissos
description: Retornos percebidos automaticamente na conversa - um lembrete que o usuário pediu, ou uma promessa que seu agente fez.
---

## Compromissos

Um compromisso é diferente de toda outra automação do Pepe: não é algo que você configura. Ele é percebido sozinho, depois de um turno, a partir do que foi realmente dito: o usuário pedindo para ser lembrado de algo, ou o próprio agente prometendo verificar algo e voltar com a resposta. Ative por agente (`commitments`, desligado por padrão) e dê a esse agente um `utility_model` - sem os dois, nada é extraído, e uma promessa continua sendo só palavras.

### Dois tipos de retorno, entregues de duas formas diferentes

Esse é o detalhe que vale entender antes de ligar, porque os dois casos não são tratados da mesma forma:

- **O lembrete do próprio usuário** ("me lembra de mandar o relatório sexta") é resolvido com uma mensagem na hora certa - a mesma coisa que um [watch](../watches/) já faz. Se seu agente tem a tool `watch`, ainda vale a pena que ele use isso diretamente no momento; compromissos existem como a rede de segurança para quando ele não usa.
- **A promessa do próprio agente** ("deixa eu verificar o deploy e te aviso amanhã") *não* é resolvida com um lembrete dizendo que a promessa foi feita. Quando chega a hora, o Pepe reexecuta essa sessão com uma instrução: fazer de verdade o que foi prometido, e só então responder com o que encontrou. A mensagem que sai é uma resposta real, não um modelo fixo - assim uma promessa nunca vira silenciosamente um "lembrete: eu disse que ia verificar isso".

### Confiança, e o que acontece quando não está claro

Uma chamada barata a um modelo lê a última troca de mensagens e decide se existe um compromisso de verdade, com uma pontuação de confiança. Se ela for alta o suficiente, e o prazo tiver sido resolvido, o compromisso já entra agendado - sem passo extra, batendo com "perceber sem precisar pedir duas vezes". Abaixo disso, ou quando o prazo não pôde ser resolvido a partir do que foi dito (um vago "em breve" não é uma data), ele entra **aguardando sua confirmação**: você é perguntado diretamente, uma vez, em vez de ficar rastreando silenciosamente algo que ninguém pediu de verdade.

### Gerenciando pelo chat

A tool `commitment` do agente tem três ações: `list` (o que está sendo acompanhado agora), `confirm id: <id>` (promove um que está aguardando - passe `due_when` também se a data nunca foi resolvida), e `cancel id: <id>`.

### Fazendo pelo dashboard

Abra a página **Compromissos** em `pepe serve` pra ver tudo que está sendo acompanhado, agrupado em aguardando confirmação, agendados e entregues. Confirme ou cancele direto por lá.

<div class="note"><strong>Sem servidor pra rodar, só um arquivo local.</strong> Compromissos vivem num pequeno arquivo SQLite embutido, ao lado do <code>config.json</code>, não é um banco de dados que você precisa instalar ou administrar - disparados pelo mesmo tipo de timer interno que já move watches e tarefas agendadas, que só roda enquanto uma superfície de longa duração (<code>pepe serve</code>, um gateway, ou uma sessão interativa) estiver de pé. Atualizando de um Pepe mais antigo que guardava compromissos direto no <code>config.json</code>? Rode <code>mix pepe config migrate-commitments</code> uma vez pra trazer os antigos - o `pepe doctor` avisa se você esquecer.</div>
