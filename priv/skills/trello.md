# Work with Trello - find cards, create them, move them across lists, comment, and read a board - so a request in chat becomes the right card on the right list.

Use this when a task is about a Trello board: "cria um card pra isso no To Do", "o que está
em andamento", "move o card do cliente pra Concluído", "quem está nesse card". The point is
that the user talks to you and the board updates, without them opening Trello.

## Prefer the connected tool

If the operator has wired a Trello MCP server, use those tools first - they carry the auth
and speak Trello's model directly, so there is nothing to build or guard. Check what you have
before reaching for the shell. This skill's REST path is the fallback.

## The shell fallback: the REST API

Trello is a REST API at `https://api.trello.com/1`. Auth is a **key** and a **token** passed
as query parameters on every call. The token acts as your account, so treat it as a secret:
take both from the environment (`$TRELLO_KEY`/`$TRELLO_TOKEN`), whether the operator set them
as plain env vars (via `secrets.expose_env`) or keeps them in a vault injected with `op run`
(the tidier habit, see the `vaults` skill). Do not paste the literal token into a command,
where it lands in the trace.

```bash
# key/token from the environment (a vault via op, or plain exposed env vars)
op run -- curl -s "https://api.trello.com/1/members/me/boards?key=$TRELLO_KEY&token=$TRELLO_TOKEN" \
  | jq '.[] | {id, name}'
```

Trello's model is **board → list → card**, and you work by id, so you usually look ids up
first:

- **Boards** - `GET /1/members/me/boards`.
- **Lists on a board** - `GET /1/boards/{boardId}/lists` (the columns: To Do, Doing, Done).
- **Cards on a list** - `GET /1/lists/{listId}/cards`.
- **Create a card** - `POST /1/cards` with `idList`, `name`, and optionally `desc`, `due`,
  `idMembers`.
  ```bash
  op run -- curl -s -X POST "https://api.trello.com/1/cards?key=$TRELLO_KEY&token=$TRELLO_TOKEN" \
    --data-urlencode "idList=LIST_ID" --data-urlencode "name=Follow up with client" \
    --data-urlencode "desc=..."
  ```
- **Move a card** - `PUT /1/cards/{cardId}?idList=NEW_LIST_ID`. Moving between lists *is* the
  status change; there are no separate transitions like Jira has.
- **Comment** - `POST /1/cards/{cardId}/actionsComments` with `text`.
- **Search** - `GET /1/search?query=...` across your boards.

## Manners

- Look up the list id once and reuse it; do not create a card on a guessed id.
- Search before creating so you do not duplicate a card that already exists.
- Creating, moving, and commenting change a shared board, so the permission gate asks first;
  for anything others will see, confirm intent with the user.
- Put enough in a card that the next person can act on it - a bare title is a second
  conversation waiting to happen.
