---
title: Compromissos
description: Se alguém diz "lembra-me na sexta", ou o teu agente diz "vou verificar e digo-te", o Pepe apanha isso sozinho e trata de cumprir.
---

## Compromissos

Um compromisso não é como as outras automações do Pepe: não há nada para configurares.
Ele é detetado sozinho, mesmo depois de um turno de conversa já ter terminado, a partir
do que foi dito de facto, seja o utilizador a pedir para ser lembrado de algo, seja o
próprio agente a prometer verificar algo e voltar com a resposta. Ativa-se por agente
(`commitments`, desligado por omissão) e exige um `utility_model` nesse agente; falta um
dos dois e nada é extraído, ficando a promessa apenas em palavras.

### Dois tipos de seguimento, tratados de formas diferentes

Vale a pena perceber isto antes de ligar a funcionalidade, porque os dois casos não
seguem o mesmo caminho:

- **Um lembrete pedido pelo próprio utilizador** ("lembra-me de enviar o relatório
  sexta") resolve-se com uma mensagem no momento certo, exatamente como já faz um
  [watch](../watches/). Se o agente já tiver a tool `watch`, continua a compensar que a
  use diretamente ali; os compromissos servem de rede de segurança para as vezes em que
  não usa.
- **Uma promessa feita pelo próprio agente** ("deixa-me verificar o deploy e digo-te
  amanhã") não fica resolvida com um simples lembrete de que a promessa existiu. Quando
  chega a hora, o Pepe volta a correr essa sessão com uma instrução clara: fazer mesmo o
  que foi prometido, e só depois responder com o que encontrou. A mensagem final é uma
  resposta real, não um texto genérico, por isso uma promessa nunca se transforma
  silenciosamente num "lembrete: disse que ia verificar isso".

### Confiança, e o que acontece quando fica por confirmar

Uma chamada barata a um modelo lê a última troca de mensagens e decide se ali existe
mesmo um compromisso, atribuindo-lhe uma pontuação de confiança. Quando essa pontuação é
suficientemente alta e o prazo dá para resolver, o compromisso é agendado logo, sem
nenhum passo extra, o que é a própria ideia de "detetar sem precisar de perguntar duas
vezes". Abaixo desse nível, ou quando não dá para extrair um prazo do que foi dito (um
vago "qualquer dia destes" não é uma data), o compromisso fica **a aguardar
confirmação**: perguntam-te diretamente, uma única vez, em vez de o sistema andar a
seguir sozinho algo que ninguém pediu de facto.

### Gerir pelo chat

A tool `commitment` do agente tem três ações: `list` (o que está a ser acompanhado neste
momento), `confirm id: <id>` (promove um compromisso que estava à espera; passa também
`due_when` se a data nunca chegou a resolver-se) e `cancel id: <id>`.

### Gerir pelo dashboard

A página **Compromissos**, dentro de `pepe serve`, mostra tudo o que está a ser
acompanhado, dividido entre à espera de confirmação, agendados e já entregues. Confirmar
ou cancelar faz-se ali mesmo.

<div class="note"><strong>Nenhum servidor a correr, só um ficheiro local.</strong> Os compromissos ficam guardados num pequeno ficheiro SQLite embutido, ao lado do <code>config.json</code>, e não numa base de dados à parte que seja preciso instalar ou manter. Disparam através do mesmo temporizador interno que já move os watches e as tarefas agendadas, e esse temporizador só corre enquanto alguma superfície de longa duração estiver ativa, seja <code>pepe serve</code>, um gateway ou uma sessão interativa.</div>
