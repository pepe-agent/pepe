---
title: Compromissos
description: Seguimentos detetados automaticamente na conversa - um lembrete que o utilizador pediu, ou uma promessa que o teu agente fez.
---

## Compromissos

Um compromisso é diferente de qualquer outra automação do Pepe: não é algo que configuras. É detetado sozinho, depois de um turno, a partir do que foi realmente dito: o utilizador a pedir para ser lembrado de algo, ou o próprio agente a prometer verificar algo e voltar com a resposta. Ativa por agente (`commitments`, desligado por defeito) e dá a esse agente um `utility_model` - sem os dois, nada é extraído, e uma promessa fica só em palavras.

### Dois tipos de seguimento, entregues de duas formas diferentes

Este é o pormenor que vale a pena entender antes de ligar, porque os dois casos não são tratados da mesma forma:

- **O lembrete do próprio utilizador** ("lembra-me de enviar o relatório sexta") é resolvido com uma mensagem na hora certa - a mesma coisa que um [watch](../watches/) já faz. Se o teu agente tem a tool `watch`, continua a valer a pena que a use diretamente nesse momento; os compromissos existem como rede de segurança para quando não usa.
- **A promessa do próprio agente** ("deixa-me verificar o deploy e digo-te amanhã") *não* é resolvida com um lembrete a dizer que a promessa foi feita. Quando chega a hora, o Pepe volta a executar essa sessão com uma instrução: fazer mesmo o que foi prometido, e só depois responder com o que encontrou. A mensagem que sai é uma resposta real, não um modelo fixo - assim uma promessa nunca se transforma silenciosamente num "lembrete: disse que ia verificar isso".

### Confiança, e o que acontece quando não está claro

Uma chamada barata a um modelo lê a última troca de mensagens e decide se existe um compromisso genuíno, com uma pontuação de confiança. Se for suficientemente alta, e o prazo tiver sido resolvido, o compromisso fica logo agendado - sem passo extra, tal como "detetar sem seres pedido duas vezes". Abaixo disso, ou quando o prazo não pôde ser resolvido a partir do que foi dito (um vago "daqui a pouco" não é uma data), fica **a aguardar a tua confirmação**: és questionado diretamente, uma vez, em vez de andar a acompanhar silenciosamente algo que ninguém pediu de facto.

### Gerir pelo chat

A tool `commitment` do agente tem três ações: `list` (o que está a ser acompanhado agora), `confirm id: <id>` (promove um que está à espera - passa `due_when` também se a data nunca foi resolvida), e `cancel id: <id>`.

### Fazer pelo dashboard

Abre a página **Compromissos** em `pepe serve` para ver tudo o que está a ser acompanhado, agrupado em a aguardar confirmação, agendados e entregues. Confirma ou cancela diretamente por lá.

<div class="note"><strong>Sem servidor para correr, só um ficheiro local.</strong> Os compromissos vivem num pequeno ficheiro SQLite embutido, ao lado do <code>config.json</code>, não é uma base de dados que precises de instalar ou gerir. São disparados pelo mesmo tipo de temporizador interno que já move os watches e as tarefas agendadas, que só corre enquanto uma superfície de longa duração (<code>pepe serve</code>, um gateway, ou uma sessão interativa) estiver ativa. A atualizar a partir de um Pepe mais antigo que guardava compromissos diretamente no <code>config.json</code>? Corre <code>mix pepe config migrate-commitments</code> uma vez para trazer os antigos. O <code>pepe doctor</code> avisa se te esqueceres.</div>
