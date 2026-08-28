---
title: Vigias
description: Peça ao Pepe para ficar de olho em algo e te avisar assim que acontecer. Ele mesmo faz a checagem, sobrevive a reinícios e avisa uma única vez.
---

## Vigias

Uma vigia responde a uma pergunta bem diferente das tarefas agendadas: não
"faça isso num horário fixo", mas "fica de olho nisso aqui e me avisa
quando acontecer". Ela recheca uma condição periodicamente e, assim que
essa condição se torna verdadeira, notifica você **uma única vez** e para
por ali. É durável: continua funcionando depois de um reinício ou do
encerramento da sessão que a criou, e sempre entrega a resposta no mesmo
canal onde nasceu.

### Sonda ou agente: dois jeitos de disparar

A parte barata de uma vigia é o **gatilho**, que roda a cada intervalo
configurado. Só quando esse gatilho dispara é que a notificação, essa sim
potencialmente cara, entra em ação, e só uma vez. Existem dois tipos de
gatilho:

- Uma **sonda** roda um comando de shell e não gasta token nenhum a cada
  checagem. Por padrão, sucesso é o comando sair com código 0, mas dá para
  exigir que uma string específica apareça na saída dele. Use sonda sempre
  que a condição puder ser resolvida por script: uma URL respondendo, um
  job que gravou um arquivo, uma linha específica aparecendo num log.
- Um gatilho de **agente** faz o agente responder de novo uma pergunta de
  sim ou não a cada intervalo, com uma chamada de modelo por checagem.
  Reserve isso para quando decidir se a condição foi atingida realmente
  exige julgamento.

Como cada checagem de agente custa tokens, o intervalo mínimo dela é maior:
300 segundos contra apenas 30 segundos de uma sonda. O intervalo padrão, de
qualquer forma, é 120 segundos.

### O que ela manda quando dispara

Quando o gatilho finalmente passa, a vigia entrega uma mensagem, que pode
ser um **texto fixo** definido de antemão (sem gastar chamada de modelo
nenhuma), ou algo **composto pelo próprio agente** no momento do disparo
(uma única chamada de modelo), o que permite incluir detalhes frescos, como
um resumo real do que acabou de acontecer.

A combinação que vale a pena conhecer é uma sonda gratuita controlando uma
mensagem composta pelo agente: o `curl` de sondagem não custa nada, e o
modelo só entra em cena, uma única vez, para escrever o resumo bem na hora
em que a condição se confirma.

### Criando uma vigia pela CLI

A CLI cria vigias baseadas em sonda. Vigias que dependem de julgamento do
agente nascem pela conversa, onde o modelo já está no circuito de qualquer
forma.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- A descrição informada (`"api-up"`) vira o id da vigia.
- `--probe` define o comando de shell sondado. Sem `--contains`, sucesso é
  o comando sair com código 0.
- `--contains STR` muda essa definição: sucesso passa a ser `STR` aparecer
  na saída do comando.
- `--message` é o texto enviado quando a vigia dispara. Se omitido, entra
  uma confirmação padrão.
- `--every` define o intervalo de sondagem em segundos (mínimo de 30).
- `--deliver telegram:<chat>` manda a notificação para aquele chat
  específico. Sem essa flag, a notificação cai no log da aplicação.

Gerenciando vigias já criadas:

```bash
pepe watch list                 # todas as vigias, com estado e contagem de checagens
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Fazendo pelo painel

A página **Watches**, disponível enquanto o `pepe serve` está no ar, lista
cada vigia com seu estado, gatilho, intervalo e quantas checagens já
consumiu do orçamento total. É dali que dá para pausar, retomar ou cancelar
qualquer uma delas. Vigias novas, porém, ainda nascem pela CLI ou pela
conversa, que é onde o gatilho e o destino de entrega são de fato
configurados.

### Fazendo pela conversa

Basta pedir em linguagem natural, e o agente cria a vigia usando a própria
ferramenta `watch`. Assim como `schedule_task`, essa ferramenta já vem
habilitada por padrão (tire-a das ferramentas de um agente se ele nunca
deve criar vigias sozinho), e cada criação continua passando pelo mesmo
pedido de permissão de sempre.

> Me avisa quando o deploy terminar. Confere a cada poucos minutos.

Quando a checagem é algo scriptável, o agente monta uma sonda; quando o
caso exige julgamento, ele monta um gatilho de agente, formulando sozinho a
pergunta de sim ou não que vai responder a cada intervalo. Ele também pode
optar por compor a mensagem final com o modelo em vez de usar um texto
fixo, deixando a notificação com um resumo real em vez de uma frase
genérica. As ações disponíveis na ferramenta `watch` são `create`, `list`,
`pause`, `resume` e `cancel`.

Para não deixar isso crescer sem controle, no máximo 50 vigias podem estar
ativas ao mesmo tempo, e o Pepe recusa criar uma vigia nova cuja condição
seja idêntica à de outra já em execução, evitando duplicatas acidentais.
Toda vigia também tem um teto de checagens: se a condição nunca se
confirmar dentro desse orçamento, ela simplesmente expira em silêncio, em
vez de continuar sondando para sempre.

### Entrega sempre no canal de origem

No momento em que é criada, uma vigia registra sua **origem**: o canal e a
conversa de onde partiu. Quando dispara, ela entrega ali mesmo, mesmo que
tenha havido um reinício pelo meio, seja um chat do Telegram (envio
direto), uma sessão de terminal ou WebSocket conectada, ou o log da
aplicação. Num WebSocket, a notificação chega como um evento `"watch"` no
canal; passando um `session` estável ao entrar, você continua recebendo
essas notificações mesmo depois de reconectar, em vez de depender do
mesmo socket que criou a vigia originalmente. No `pepe chat`, ela aparece
direto impressa no console. Já uma vigia criada pela API HTTP, que não tem
sessão de conversa nenhuma para responder de volta, cai automaticamente no
log.

Duas garantias sustentam essa confiabilidade:

- **No máximo uma entrega.** O novo estado da vigia (geralmente "done") é
  salvo em disco *antes* de qualquer tentativa de entrega. Se o processo
  cair bem entre o disparo e a entrega, a vigia não vai rechecar nem
  disparar uma segunda vez, apenas a entrega em si é tentada de novo.
- **Entrega assim que possível.** Se uma vigia dispara com o canal de
  destino offline, uma sessão de terminal desconectada, por exemplo, a
  mensagem fica retida e é reenviada a cada novo ciclo até conseguir
  chegar. Você recebe a notificação assim que volta, sem que a vigia tenha
  precisado rechecar nada.

Ao longo da vida, uma vigia passa por um conjunto pequeno de estados:
`pending` (ainda observando), `paused`, `done` (já disparou e entregou),
`expired` (esgotou o orçamento de checagens) ou `cancelled`.

<div class="note"><strong>Sem banco de dados para instalar, sem crontab.</strong> Tarefas agendadas continuam sendo registros simples dentro do <code>~/.pepe/config.json</code> (na chave <code>"crons"</code>), com um arquivo JSONL de histórico por tarefa em <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Vigias vivem no mesmo pequeno arquivo SQLite embutido que guarda os compromissos, sem nada para você instalar ou administrar à parte. De um jeito ou de outro, não existe nenhum processo extra para manter no ar: o agendador inteiro é só um cronômetro rodando dentro do próprio processo, seja ele o <code>pepe serve</code>, um gateway, ou um <code>pepe chat</code> interativo, e para assim que essa superfície para. Rode só uma dessas por vez sobre a mesma configuração: duas rodando juntas disparariam ao mesmo tempo, e uma vigia acabaria avisando duas vezes.</div>
