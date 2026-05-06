---
title: Vigias
description: Crie monitores duráveis que avisam uma única vez quando uma condição se torna verdadeira.
---

## Vigias

Uma vigia responde a uma pergunta diferente: não "faça isso pelo relógio", mas "fique de olho em algo e me avise no momento em que acontecer". Uma vigia recheca uma condição em um cronômetro e te notifica **uma vez** quando ela se torna verdadeira, e então para. Ela é durável: sobrevive a um reinício e ao fechamento da sessão que a criou, e sempre responde no canal em que foi criada.

### Gatilhos por sonda e por agente

A parte barata de uma vigia é o **gatilho**, que roda a cada intervalo. Só quando o gatilho dispara é que a notificação (possivelmente cara) roda, uma vez. Há dois tipos de gatilho:

- Uma **sonda** roda um comando de shell e não custa tokens por checagem. Sucesso é código de saída 0 por padrão, ou você pode exigir que uma string apareça na saída do comando. Use uma sonda sempre que a condição for scriptável (uma URL está acessível, um trabalho escreveu um arquivo, um log contém uma linha).
- Um gatilho de **agente** repergunta ao agente uma pergunta de sim/não a cada intervalo, uma chamada ao modelo por checagem. Use só quando decidir se a condição foi atingida exigir julgamento de verdade.

Como checagens de agente custam tokens, o intervalo mínimo delas é maior: 300 segundos para gatilhos de agente, 30 segundos para sondas. O intervalo padrão é de 120 segundos.

### O que ela envia quando dispara

Quando o gatilho enfim passa, uma vigia entrega uma mensagem. Essa mensagem é ou um **texto fixo** (que você define de antemão, sem chamada ao modelo), ou é **composta pelo agente** na hora do disparo (uma chamada ao modelo, uma vez), para que possa incluir detalhe fresco, como um resumo do que de fato aconteceu.

### Criar uma vigia pela CLI

A CLI cria vigias por sonda. Vigias julgadas por agente são criadas pela conversa, onde o modelo já está no loop.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- A descrição (`"api-up"`) vira o id da vigia.
- `--probe` é o comando de shell a sondar. Sem `--contains`, sucesso significa que o comando sai com 0.
- `--contains STR` em vez disso faz o sucesso significar que `STR` aparece na saída do comando.
- `--message` é o texto a enviar quando dispara. Omita para uma confirmação padrão.
- `--every` é o intervalo de sondagem em segundos (mínimo 30).
- `--deliver telegram:<chat>` envia a notificação para aquele chat. Omita e a notificação vai para o log da aplicação.

Gerenciando vigias:

```bash
pepe watch list                 # all watches, with state and check count
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Faça pelo painel

Abra a página **Watches** sob `pepe serve` para ver cada vigia com o estado, o gatilho, o intervalo e quantas checagens ela já usou do orçamento dela. Dali você pode pausar, retomar e cancelar uma vigia. Vigias novas são criadas pela CLI ou pela conversa, onde o gatilho e o destino de entrega são configurados.

### Faça pela conversa

Peça em linguagem natural e o agente cria a vigia pela ferramenta `watch` dele. Assim como `schedule_task`, a ferramenta `watch` precisa estar no conjunto do agente e passa pelo mesmo pedido de permissão a cada criação, então vale o mesmo duplo aceite.

> Me avise quando o deploy terminar. Cheque a cada poucos minutos.

Para uma checagem scriptável o agente configura uma sonda. Para algo que precisa de julgamento ele configura um gatilho de agente, formulando uma pergunta de sim/não que responde a cada intervalo. Ele também pode escolher compor a mensagem de disparo com o modelo em vez de usar um texto fixo, para que a notificação carregue um resumo real em vez de uma linha enlatada. As ações da ferramenta `watch` são `create`, `list`, `pause`, `resume` e `cancel`.

Para manter as coisas limitadas, pode haver no máximo 50 vigias ativas ao mesmo tempo, e o Pepe recusa uma vigia nova cuja condição seja idêntica a uma já em execução, então você não empilha duplicatas sem querer. Uma vigia também tem um número máximo de checagens; se a condição nunca se tornar verdadeira dentro desse orçamento, a vigia expira em silêncio em vez de sondar para sempre.

### Entrega no canal de origem

Uma vigia registra a **origem**, o canal e a conversa em que foi criada, no momento da criação. Quando dispara, ela entrega de volta ali, mesmo após um reinício, seja um chat do Telegram, uma sessão de terminal ou WebSocket conectada, ou o log da aplicação. Se a vigia foi criada pela API HTTP sem estado (que não tem conversa para responder), ela recorre ao log.

Duas garantias tornam isso confiável:

- **No máximo uma vez.** O novo estado da vigia (normalmente "done") é salvo em disco *antes* de a entrega ser tentada. Se o processo quebrar entre o disparo e a entrega, ela não vai rechecar nem disparar uma segunda vez. Só a entrega é retentada.
- **Entregar quando alcançável.** Se uma vigia dispara enquanto o canal dela está offline (uma sessão de terminal que desconectou, por exemplo), a mensagem é retida e reenviada a cada disparo até chegar. Você recebe a notificação quando volta, sem a vigia rechecar.

Uma vigia passa por um pequeno conjunto de estados ao longo da vida: `pending` (ainda vigiando), `paused`, `done` (disparada e entregue), `expired` (esgotou o orçamento de checagens) ou `cancelled`.

<div class="note"><strong>Sem banco de dados, sem crontab.</strong> Tarefas e vigias são registros simples no <code>~/.pepe/config.json</code>, e o histórico de execuções das tarefas é um arquivo JSONL por tarefa sob <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Não há mais nada para instalar ou manter rodando. Todo o agendador é um cronômetro dentro do processo que inicia quando você roda <code>pepe serve</code> ou um gateway, e para quando você os para.</div>
