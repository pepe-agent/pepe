---
title: Delegação (fan-out)
description: A ferramenta delegate divide um trabalho amplo em workers paralelos descartáveis, cada um com a sua própria janela de contexto nova, por isso o conjunto demora o tempo da parte mais lenta, e não a soma.
---

"Compara estes oito concorrentes" não é uma tarefa, são oito, e fazê-lo numa única conversa custa a dobrar. Demora oito vezes mais. E cada página obtida para o concorrente um continua a ocupar a janela de contexto enquanto o modelo lê sobre o concorrente oito, por isso a janela enche-se de material que ninguém voltará a olhar, e a resposta final piora com isso.

A ferramenta `delegate` entrega as partes a workers descartáveis, todas ao mesmo tempo:

```
tu › compara as páginas de preços da stripe, da adyen e da mollie

agente › delegate(tasks: [
           "Lê stripe.com/pricing e indica a taxa de cartão e qualquer mínimo mensal.",
           "Lê adyen.com/pricing e indica a taxa de cartão e qualquer mínimo mensal.",
           "Lê mollie.com/pricing e indica a taxa de cartão e qualquer mínimo mensal."
         ])
```

Cada worker é uma execução nova, com a sua própria janela de contexto e o seu próprio trace. Lê o que precisa, responde à pergunta que recebeu e desaparece. O pai recebe três respostas e nunca vê as três transcrições, por isso o trabalho cabe numa janela onde antes não caberia. E, como os workers esperam pela rede ao mesmo tempo, o conjunto demora o tempo do mais lento, não a soma.

## Dar a ferramenta a um agente

Concedes o `delegate` da forma habitual, na lista de ferramentas:

```bash
pepe agent add lead --model openrouter --tools fetch_url,read_file,delegate
```

## Um worker pode ler; não pode agir

Um worker herda apenas as ferramentas que não pedem permissão: `read_file`, `list_dir`, `fetch_url`, `web_search` e afins. Tudo o que escreve, executa, instala ou apaga é retirado antes de o worker começar, e um worker não pode delegar mais adiante.

Isto não é uma limitação à espera de ser levantada. Três workers a correr ao mesmo tempo são três workers que iriam querer fazer-te três perguntas ao mesmo tempo, e *posso executar isto?* não é uma pergunta para se fazer em triplicado. Mais importante: o fan-out serve para **descobrir**, e descobrir é seguro de fazer em paralelo. **Agir** não é, e fica onde deve ficar, na única conversa que estás mesmo a acompanhar. Um worker que descobre que algo precisa de ser feito di-lo, e o pai fá-lo, na barreira de permissão, à tua frente.

A outra proteção é aritmética. Sem o "um worker não pode delegar", uma tarefa passa a oito, passa a sessenta e quatro, e a conta chega antes da resposta.

<div class="note"><strong>Um limite rígido de oito tarefas por chamada.</strong> O modelo é avisado do limite, por isso divide o trabalho em vez de ser apanhado de surpresa por ele.</div>

## Delegar como outro agente

```
delegate(tasks: [...], agent: "researcher")
```

Isto corre os workers como um agente diferente, com a persona e as ferramentas desse agente, ainda sem nada que aja. Obedece à mesma lista de permissões dirigida do `send_to_agent`: um agente só pode pedir emprestada a identidade de outro se já lhe era permitido enviar-lhe mensagem. Uma autoridade para o ato, não uma segunda e mais fraca. As rotas estão explicadas na página [Agentes](../agents/).

## Sem esperar pela resposta

```
delegate(tasks: [...], background: true)
```

A mesma divisão de trabalho, mas sem esperar: a chamada volta de imediato com uma confirmação, para o agente poder continuar a trabalhar ou avisar que já está a tratar disso, e os resultados chegam depois como uma mensagem de seguimento normal na mesma conversa assim que todos os workers terminarem. Vale a pena usar quando a divisão é genuinamente lenta (várias páginas para ler, um worker com raciocínio a sério pela frente); esperar uns segundos continua a ser mais simples e não precisa de explicação para o utilizador. Só funciona dentro de uma conversa real: uma execução de turno único não tem sessão à qual entregar os resultados.

## Quanto custa

Cada worker é uma chamada de modelo a sério, medida e faturada como qualquer outra, ao mesmo projeto. Oito workers são oito turnos. É essa a troca: estás a comprar de volta tempo de relógio e espaço na janela de contexto, e a pagá-lo em tokens. Para uma tarefa que nunca teria cabido numa só janela, nem sequer chega a ser uma troca.

Cada worker tem o seu próprio trace, por isso **Traces** no [painel](../dashboard/) mostra o que cada um fez de facto, não apenas o que o pai disse sobre isso.
