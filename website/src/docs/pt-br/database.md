---
title: Banco de dados
description: Deixe um agente responder perguntas a partir do seu próprio banco Postgres, em modo leitura, com os dados de cada cliente isolados pelo próprio banco, não pelo modelo.
---

A tool `db_query` permite que um agente responda perguntas direto a partir dos seus dados:
ela roda consultas SQL somente leitura contra um banco Postgres externo, configurado pelo
operador (os dados são do cliente, não o armazenamento interno do Pepe). **Só Postgres.**
Quando esse banco guarda várias contas na mesma tabela (uma coluna no estilo `company_id`
separando os clientes entre si), o Pepe amarra o valor de tenant confiável à conexão e
nunca deixa o modelo ver ou alterar esse valor. Quem garante o isolamento de verdade é o
próprio Postgres, via Row-Level Security, não uma decisão tomada em tempo de execução pelo
código do Pepe.

## Por que o modelo nunca enxerga o valor do tenant

Um argumento de tool preenchido pelo modelo pode sair errado por engano, ou porque uma
página ou documento que o agente leu instruiu a usar outro valor. Isso não é uma falha de
redação: é um vazamento de dados entre clientes. Por isso o schema da tool `db_query`
simplesmente não tem parâmetro nenhum de tenant/`company_id`; o modelo só informa
`connection` (um nome) e `query` (SQL somente leitura). O valor do tenant vem da
configuração feita pelo operador, é resolvido do lado do servidor e é aplicado
automaticamente a toda consulta daquela conexão.

## Configure o Row-Level Security primeiro

Essa parte o Pepe não faz por você: o banco do operador precisa de um role dedicado, sem
privilégios, e de uma política de acesso. Rode algo assim uma vez, manualmente, direto no
banco de destino:

```sql
CREATE ROLE pepe_ro LOGIN PASSWORD '...' NOBYPASSRLS;
GRANT SELECT ON orders, invoices TO pepe_ro; -- as tabelas que o agente deve ler

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON orders
  USING (company_id = current_setting('app.pepe_tenant_id', true)::text);
```

Dois pontos merecem atenção aqui:

- **`NOBYPASSRLS`, nunca o dono da tabela.** Por padrão, superusuários e donos de tabela
  ignoram o RLS mesmo com a política ativa. Para a política valer alguma coisa, o role
  usado pelo Pepe precisa ser um role comum, sem privilégio nenhum.
- **`current_setting('app.pepe_tenant_id', true)`**: esse nome de GUC é fixo, faz parte da
  convenção do Pepe e não muda de conexão para conexão. O `true` como segundo argumento
  significa "devolve `NULL` se não estiver definido, sem gerar erro", e como
  `company_id = NULL` nunca é verdadeiro em SQL, uma conexão que por algum motivo rode sem
  esse valor definido fica sem acesso a nada, e não com acesso a tudo. É uma falha fechada
  por construção.

**Uma tabela sem política de RLS simplesmente não tem proteção nenhuma dessa
funcionalidade.** A `db_query` roda do mesmo jeito em qualquer tabela de uma conexão; se
uma tabela específica está de fato isolada depende só de ela ter, ou não, uma política que
funcione. Isso é intencional, não uma lacuna a ser fechada pelo Pepe: tentar garantir
isolamento de tenant reescrevendo ou validando, no código da aplicação, SQL arbitrário
escrito por um agente não é algo confiável de se fazer, uma cláusula `WITH`, um `JOIN`, um
agregado, qualquer um desses pode contornar uma checagem que olhe só o texto da consulta.
O Row-Level Security é o único mecanismo que se sustenta de fato, independentemente de
como a consulta foi escrita, porque age dentro do próprio motor do banco, não sobre o
texto dela.

## Adicionando uma conexão

A página **Bancos de dados** do dashboard lista as conexões existentes, mostra se cada uma
tem escopo de tenant, e traz um formulário para adicionar ou remover uma; o campo de senha
nunca aparece preenchido nem é reexibido depois de salvo. Pelo CLI funciona igual:

```bash
pepe db add clientes_prod --host db.internal --port 5432 --database billing \
  --user pepe_ro --password ${DB_CLIENTES_PROD_PASSWORD} \
  --tenant-column company_id --tenant-mode fixed --tenant-value acme-inc

pepe db list
pepe db remove clientes_prod
```

Uma conexão sem `--tenant-column` (ou com o campo "Coluna de tenant" vazio no dashboard)
fica sem escopo, o que é perfeitamente adequado para um banco que só guarda dados de um
único cliente, sem nada para isolar. Já uma conexão com coluna de tenant também precisa de
um modo:

- **`fixed`**: o valor é um literal fixo, por exemplo, uma conexão por cliente
  (a `clientes_prod` acima é sempre `acme-inc`, não importa quem pergunte).
- **`agent_field`**: o valor é `"project"` ou `"bare"`, resolvido a partir do próprio
  projeto ou handle do *agente que fez a chamada*, no momento da consulta. Útil quando uma
  única instalação do Pepe atende vários clientes, cada um mapeado ao seu próprio
  agente/projeto.

Um agente também pode gerenciar essas conexões durante uma conversa, com a tool
`manage_db` (as mesmas ações de add/list/remove), e consultar com `db_query` assim que
tiver as duas tools. Ambas são tools de risco: não fazem parte do conjunto sempre-seguro,
então cada chamada passa pelo aviso de permissão comum, como qualquer outra tool que
alcança algo fora do Pepe.

## O que o agente vê

O resultado de uma `db_query` volta embrulhado no mesmo marcador de conteúdo não confiável
que acompanha um resultado de `fetch_url`: é conteúdo vindo de fora da conversa, tratado da
mesma forma. A tool em si só funciona com Postgres; não existe equivalente para MySQL,
SQLite ou qualquer outro motor, já que o Row-Level Security, e a garantia de falha fechada
descrita acima, é uma característica específica do Postgres.
