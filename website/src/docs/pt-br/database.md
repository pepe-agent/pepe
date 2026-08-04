---
title: Banco de dados
description: Deixe um agente ler de um banco Postgres externo, com a multi-tenência do próprio cliente aplicada pelo banco, não pelo modelo.
---

A tool `db_query` deixa um agente rodar uma consulta SQL somente-leitura contra um banco
Postgres externo configurado pelo operador - dados do próprio cliente, não o armazenamento
interno do Pepe. **Só Postgres.** Se esse banco tem a própria multi-tenência (uma coluna no
estilo `company_id` separando os próprios clientes daquele cliente), o Pepe amarra o valor de
tenant confiável à conexão e nunca deixa o modelo ver ou definir esse valor - o isolamento de
verdade é aplicado pelo próprio Postgres, via Row-Level Security, não por algo que o código do
Pepe decide em tempo de execução.

## Por que o modelo nunca vê o valor do tenant

Um argumento de tool que o modelo preenche pode sair errado - por engano, ou porque uma
página ou documento que o agente leu disse pra usar um valor diferente. Isso não é uma falha
de redação, é um vazamento real de dados entre clientes. Por isso o schema da tool `db_query`
não tem nenhum parâmetro de tenant/`company_id`: o modelo só passa `connection` (um nome) e
`query` (SQL somente-leitura). O valor do tenant vem da configuração que o operador definiu,
resolvido do lado do servidor, e aplicado a toda consulta daquela conexão automaticamente.

## Configurando Row-Level Security (faça isso primeiro)

Essa é a parte que o Pepe não consegue fazer por você: o próprio banco do operador precisa de
um role dedicado e sem privilégios, e uma política. Rode algo assim uma vez, na mão, no banco
alvo:

```sql
CREATE ROLE pepe_ro LOGIN PASSWORD '...' NOBYPASSRLS;
GRANT SELECT ON orders, invoices TO pepe_ro; -- as tabelas que o agente deve ler

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON orders
  USING (company_id = current_setting('app.pepe_tenant_id', true)::text);
```

Duas coisas importam aqui:

- **`NOBYPASSRLS`, e nunca o dono da tabela.** Superusuários e donos de tabela ignoram RLS
  por padrão, mesmo com a política no lugar. O role com o qual o Pepe se conecta tem que ser
  um role comum, sem privilégios, pra a política significar alguma coisa.
- **`current_setting('app.pepe_tenant_id', true)`** - esse nome exato de GUC é a convenção
  fixa do Pepe, não é configurável por conexão. O `true` como segundo argumento significa
  "devolve `NULL` se não estiver definido, não dá erro" - e `company_id = NULL` nunca é
  verdadeiro em SQL, então uma conexão que de alguma forma roda sem o valor definido fica sem
  acesso a nada, não com acesso a tudo. Falha fechada, por construção.

**Uma tabela sem política de RLS não está protegida por essa funcionalidade de jeito
nenhum.** O `db_query` roda do mesmo jeito contra toda tabela de uma conexão; se uma tabela
específica está de fato isolada depende inteiramente de se *aquela tabela* tem uma política
que funciona. Isso é deliberado, não uma brecha pra tapar no Pepe: tentar aplicar isolamento
de tenant reescrevendo ou validando SQL arbitrário escrito pelo agente no código da aplicação
não dá pra fazer de forma confiável (uma cláusula `WITH`, um `JOIN`, um agregado podem
contrabandear uma leitura passando por uma checagem no nível de texto). Row-Level Security é
o único mecanismo que realmente se sustenta não importa como a consulta foi escrita, porque
atua dentro do próprio motor de banco de dados, não sobre o texto da consulta.

## Adicionando uma conexão

A página **Bancos de dados** do dashboard lista as conexões, mostra se cada uma tem escopo de
tenant, e tem um formulário pra adicionar ou remover uma - o campo de senha nunca vem
preenchido nem é reexibido depois de salvo. A mesma coisa pelo CLI:

```bash
pepe db add clientes_prod --host db.internal --port 5432 --database billing \
  --user pepe_ro --password ${DB_CLIENTES_PROD_PASSWORD} \
  --tenant-column company_id --tenant-mode fixed --tenant-value acme-inc

pepe db list
pepe db remove clientes_prod
```

Uma conexão sem `--tenant-column` (ou com o campo "Coluna de tenant" vazio no dashboard) não
tem escopo - tudo bem pra um banco de um único cliente, sem nada pra isolar. Uma com coluna de
tenant também precisa de um modo:

- **`fixed`** - o valor é um literal, ex.: uma conexão por cliente (`clientes_prod`
  acima é sempre `acme-inc`, não importa quem pergunte).
- **`agent_field`** - o valor é `"project"` ou `"bare"`, resolvido a partir do
  próprio projeto ou nome do *agente que está chamando* no momento da consulta - útil quando
  uma instalação do Pepe atende vários clientes, cada um mapeado pro próprio agente/projeto.

Um agente também pode gerenciar conexões de uma conversa com a tool `manage_db` (as mesmas
ações add/list/remove), e consultar com `db_query` uma vez que tenha as duas tools. As duas
são tools de risco - não estão no conjunto sempre-seguro, e passam pelo aviso de permissão
comum como qualquer outra tool que alcança pra fora.

## O que o agente vê

Um resultado de `db_query` volta embrulhado no mesmo marcador de conteúdo não confiável que
um resultado de `fetch_url` carrega - é conteúdo de fora da conversa, tratado do mesmo jeito.
A tool em si é só pra Postgres; não tem equivalente pra MySQL, SQLite ou qualquer outro
motor, já que Row-Level Security (e a garantia de falha fechada acima) é específica do
Postgres.
