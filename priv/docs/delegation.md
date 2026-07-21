# Delegation - split work across throwaway workers, at the same time

The `delegate` tool hands several independent pieces of work to fresh copies of you and
gives you back only their answers.

Reach for it when a task splits cleanly into parts that do not depend on each other:
compare N things, check N sources, summarize N documents. Doing those one after another
in this conversation costs twice over. It takes N times as long, and everything you read
for part one is still filling your context window while you work on part N, which makes
your final answer worse.

```
delegate(tasks: [
  "Read stripe.com/pricing and report the card fee and any monthly minimum.",
  "Read adyen.com/pricing and report the card fee and any monthly minimum.",
  "Read mollie.com/pricing and report the card fee and any monthly minimum."
])
```

Each task must be **self-contained**: the worker sees only the sentence you give it, not
this conversation. Say what to find out and what to hand back. You get one section per
task, in the order you asked.

## What a worker can and cannot do

A worker can **read**: files, directories, URLs, the web. It cannot write, run commands,
install anything, or delegate further. Those tools are taken away before it starts.

So delegate to **find things out**. If the answers show that something needs *doing*, do
it yourself afterwards, in this conversation, where the user can see it and authorize it.

Up to **8 tasks** per call. If the work is bigger than that, split it and call twice.

## Delegating as another agent

`delegate(tasks: [...], agent: "researcher")` runs the workers as another agent, with its
persona. You may only name an agent you are already allowed to message.

## Not waiting for it

`delegate(tasks: [...], background: true)` dispatches the same fan-out without waiting.
The call returns right away with an acknowledgment - keep working, or tell the user
you're on it - and the results arrive later as a follow-up message in this same
conversation, once every worker is done. Reach for this when the fan-out is slow enough
that waiting would leave the user staring at silence; for anything that answers in a few
seconds, just wait normally. Only works inside a real conversation - a one-shot run has
no session to deliver the results back into, so `background` is refused there.

## The cost

Every worker is a real model call, billed like any other. Eight workers is eight turns.
It buys back time and context-window room; it is not free. Do not fan out a task that was
one question in the first place.
