# Notas da Versão — 0.12.0

Uma versão sobre **cobrar cliente sem trabalho manual**. Até aqui os números de consumo existiam só no painel e no terminal, então entregar a um cliente o gasto dele significava exportar uma fatura na mão. Agora o sistema dele lê os números direto, por HTTP, com um token que só sabe ler.

E vem junto a resposta para a pergunta que uma fatura nunca respondeu: **por que aquela mensagem custou tanto**.

---

## ✨ Novidades

### O cliente lê o próprio consumo, pela API

Quatro endpoints, quatro níveis de detalhe sobre o mesmo registro:

| Endpoint | Uma linha por |
| --- | --- |
| `GET /v1/usage` | intervalo de tempo (hora, dia, semana, mês, ano) |
| `GET /v1/usage/events` | chamada de modelo |
| `GET /v1/usage/runs` | mensagem recebida |
| `GET /v1/usage/runs/:id` | aquela mensagem, chamada por chamada |

O mesmo cabeçalho `Authorization: Bearer` do resto da API, e cada leitura responde apenas sobre os projetos que o token alcança. Dá para filtrar por projeto, agente, modelo, origem, conversa e janela de tempo.

### Um token que só lê, e não gasta

Antes, um token era um token: quem tinha acesso podia rodar agente. Se você quisesse mostrar o consumo ao cliente, entregava junto uma credencial capaz de gastar o seu orçamento de modelo.

Agora o token carrega permissões separadas do alcance dele:

```bash
pepe token add --project acme --no-chat --usage --prices billable
```

Esse token lê o consumo, **não** roda agente, vê só o projeto `acme`, e vê só o que o cliente paga.

O `--prices` é quem decide quanto dos valores aparece:

- `billable` — com o seu markup aplicado, o que o cliente paga. O padrão.
- `list` — os mesmos tokens ao preço do modelo, sem markup.
- `all` — os dois, mais o seu custo e a sua margem. Para um token que **você** guarda.

Quem manda é sempre o token, nunca a requisição: um cliente que pedir `?prices=all` recebe de volta a visão do próprio token, não a que pediu. E os dois primeiros são exclusivos de propósito — mostrar `billable` e `list` lado a lado entrega a razão entre eles, que é justamente o markup.

Dá para mudar depois sem trocar o segredo, então a integração do cliente continua funcionando enquanto o que ela vê muda:

```bash
pepe token permissions abc123 --prices list
```

Nada do que você já criou mudou de comportamento: um token existente continua podendo conversar e continua **sem** poder ler consumo.

### Por que aquela mensagem custou tanto

Uma mensagem recebida raramente é uma chamada de modelo. O agente responde, chama uma ferramenta, lê o resultado, chama outra, responde de novo — e cada volta reenvia um contexto que o resultado anterior acabou de aumentar. O relatório por ciclo conta chamadas, então nunca conseguiu mostrar isso.

Agora cada chamada guarda a qual mensagem pertence, e cada mensagem tem seu próprio registro: quais ferramentas rodaram, quanto tempo levou, como terminou.

No painel, a página de Uso ganhou a tabela **Por mensagem**. Clique numa linha e ela abre nas chamadas de modelo daquele turno, uma a uma. No terminal:

```bash
pepe usage runs                 # uma linha por mensagem
pepe usage runs <id>            # aquela mensagem, chamada por chamada
```

O detalhe mostra que uma mensagem com três ferramentas são quatro chamadas de modelo. É o número de chamadas que encarece, não o número de ferramentas.

Esse registro por mensagem **não guarda conteúdo de conversa**, e é por isso que ele é mantido em vez de podado como os traces. Se você quiser o conteúdo no detalhe, é uma permissão à parte (`--content`), desligada por padrão: um relatório de consumo é uma fatura, e fatura não é transcrição.

---

## 🐛 Correções

### Uma resposta pendente não derruba mais as outras

O sistema anota toda resposta que deve a um chat, para reenviar se cair no meio do envio. Uma anotação gravada por uma versão antiga, num formato que ainda não tinha o nome do bot, fazia essa varredura de recuperação quebrar **inteira**, em silêncio: a resposta devida de todos os outros bots se perdia por causa de uma única anotação velha. Agora a anotação antiga é ignorada e o resto é entregue normalmente.

---

## 📖 Documentação

Uma página nova, **API de consumo**, nos quatro idiomas, com exemplo de requisição e de resposta para cada endpoint, a tabela de filtros e a de erros. As páginas de Autenticação e de Cobrança ganharam as seções correspondentes.
