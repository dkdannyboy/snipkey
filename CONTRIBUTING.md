# Contributing to SnipKey

Thanks for wanting to help. This file covers how to build the project, how the
tests work, and — most importantly — which behaviours are deliberate and should
not be "fixed".

한국어 안내는 [README.ko.md](README.ko.md)를 참고하세요.

---

## Build and test

```bash
swift build          # build
swift test           # 92 unit tests: parser, importer, matcher, key classifier
./scripts/build-app.sh --install   # build dist/SnipKey.app and install it
```

CI runs `swift build`, `swift test`, and the app bundle assembly on every pull
request. It does **not** run the end-to-end harness — see below.

## The end-to-end harness

`scripts/e2e.sh` types real keystrokes into TextEdit with System Events and
checks what SnipKey did, judging the result from the engine's own log rather
than from the document text alone. It covers the paths unit tests cannot reach:
the CGEvent tap, the expansion engine, and the injector.

It cannot run in CI. It needs Accessibility permission, a real GUI session, and
a real TextEdit — a cloud runner has none of those. Run it locally before
changing anything in `ExpansionEngine.swift`, `TextInjector.swift`, or
`KeyClassifier.swift`:

```bash
./scripts/e2e.sh
```

The harness takes over your keyboard for a few minutes. It refuses to start if
you have TextEdit documents open, because it would destroy unsaved work. It
backs up and restores your clipboard, and isolates your real snippet library
behind a temporary store — read the comments at the top of the script before you
change it.

**A test that cannot fail is worse than no test.** If you add or change a case,
prove it fails when the guard it protects is removed. Comment out the guard,
rebuild, watch the case go red, then restore the guard. Several cases in that
file exist because an earlier version of them passed while the bug was still
live.

---

## Deliberate behaviours — please read before "fixing" them

These look like bugs. They are not. Each one is load-bearing, each is covered by
an e2e case, and each exists because the alternative destroys what someone typed.

### Return and Tab do not terminate a bare-word abbreviation

`sig` followed by Return does not expand. This is on purpose.

SnipKey watches keystrokes without swallowing them, so by the time it can act,
the key has already reached the app — and Return and Tab *do things*. Return
sends the message in Slack. Tab moves focus to the next field. If SnipKey
expanded on them, `sig` would get sent as a message before the signature
arrived, or the signature would land in the field you just tabbed into.

Expanding in the wrong place is worse than not expanding. Finish with a space or
a punctuation mark instead, or use a `;sig`-style abbreviation.

Covered by e2e cases (f) and (g).

### Bare-word abbreviations wait for a terminator

`sig` does not expand the moment you type the third letter. It waits.

It has to. `sig` is the first three letters of `signal` and `signature`. If it
expanded immediately, those words would be impossible to type — SnipKey would
eat them mid-keystroke. Punctuation-prefixed abbreviations (`;sig`, `/addr`) are
unambiguous, so those expand immediately.

Covered by e2e cases (b), (d), and (e).

### Expansions get abandoned rather than risked

SnipKey throws away a matched expansion if anything suggests the backspaces
would land somewhere unintended: you kept typing past the trigger, focus moved
to another app, or you clicked somewhere before the replacement went out.

The event tap is listen-only, so your keystrokes reach the app before SnipKey's
do. An expansion that fires late deletes whatever you typed in the meantime, not
the abbreviation. Every one of these guards exists because that happened.

Covered by e2e cases (h), (i), (j), and (k).

### The store refuses to save when it could not be read

If the snippet library fails to load, SnipKey blocks saving instead of writing
an empty file over it. A corrupt file that still holds your snippets is
recoverable. An empty file is not.

---

## Style

- Comments explain **why**, not what. The interesting part of this codebase is
  the reasoning, and most of it is about a failure that already happened once.
- Match the surrounding code. Comments in `scripts/` and much of `Sources/` are
  in Korean; keep the file you are editing consistent rather than mixing.
- No force-unwrapping without a stated reason.

## Pull requests

- One concern per PR.
- If you fix a bug, add the test that reproduces it first and confirm it fails
  before your fix.
- If you touch the expansion or injection path, say in the PR that you ran
  `scripts/e2e.sh` and paste the summary line.
