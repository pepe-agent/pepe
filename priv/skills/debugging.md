# Debug a failure methodically instead of guessing - when code you ran errors, a test fails, output is wrong, or something "works on my machine but not here".

Use this the moment you catch yourself about to change something because it *might* help. A
guess that happens to work teaches you nothing and often breaks something else; a guess that
does not work costs a turn and moves you no closer. The method below is slower for one line
and far faster for anything real.

## The loop

**1. Reproduce it, smallest.** Get a single command that fails the same way every time. If
you cannot reproduce it, you cannot fix it - you can only hope. Strip the case down until
nothing non-essential is left: the failing test alone, the one input, the one request.

**2. Read the actual error.** The whole thing, bottom to top for a stack trace - the real
cause is usually the innermost frame, not the top line. Note the exact message, the file,
the line. Do not skim it and pattern-match to a fix you already have in mind.

**3. Form one hypothesis and make it testable.** "The value is nil here" is testable; "the
config is wrong somehow" is not. State what you believe and what you would see if it were
true.

**4. Get evidence before changing code.** Print the value, log the input, check the type,
inspect the state right before the failure. Confirm or kill the hypothesis with an
observation, not with an edit. This is the step people skip, and it is the one that matters:
you are narrowing down *where* reality diverges from what you assumed.

**5. Bisect when lost.** If you cannot see it, cut the problem in half. Comment out half the
pipeline, check an intermediate value halfway through, or `git bisect` across commits. Each
check should halve the space the bug can be hiding in.

**6. Fix the cause, then prove it.** Change the one thing your evidence pointed at. Re-run
the reproduction from step 1 and watch it pass. Then run the surrounding tests to make sure
the fix did not break a neighbour.

## Habits that pay off

- **Change one thing at a time.** Two changes at once, and a pass tells you nothing about
  which mattered - and a new failure could be either.
- **Believe the error over your memory of the code.** The message is what happened; your
  recollection is what you meant to happen. When they disagree, the message is right.
- **The bug is usually in your code, in the last thing you changed, and not where you first
  looked.** Check your recent diff before you suspect the language, the library, or the OS.
- **Write down what you ruled out.** A few notes keep you from re-testing the same dead end
  three times.
- **When truly stuck, explain it out loud** - to the user, or into a comment. Saying the
  assumption is often enough to see which one is false.
