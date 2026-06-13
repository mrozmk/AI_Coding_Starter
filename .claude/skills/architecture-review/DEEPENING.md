# Deepening

How to merge a cluster of shallow modules into fewer, deeper ones **safely** — given what each one depends on. Assumes the vocabulary in [GLOSSARY.md](GLOSSARY.md): **module**, **interface**, **seam**, **adapter**, **leverage**, **locality**.

Deepening is the core move this review proposes: take modules whose interface is nearly as complex as their implementation and fold them into a smaller number of modules with high leverage. The safety of that move depends entirely on **what the candidate depends on**. Classify each dependency before recommending a merge.

---

## Dependency categories

### 1. In-process

Pure computation, in-memory state, no I/O. **Always deepenable.** Merge the modules and test through the new interface directly — no adapter, no port. This is the easy case; most over-extracted "pure helper" clusters live here.

### 2. Local-substitutable

Dependencies that have a local, in-test stand-in (an embedded/in-memory equivalent of the real backing service, a virtual filesystem). **Deepenable if the stand-in exists.** Run the stand-in inside the test suite and test through the deepened module's interface. The seam is **internal** to the implementation — do not expose a port at the module's external interface just because the test uses one.

### 3. Remote but owned (Ports & Adapters)

Your own services across a network boundary (separately deployed services, internal HTTP/RPC). Define a **port** (interface) at the seam. The deep module owns the logic; the transport is injected as an **adapter** — a network adapter in production, an in-memory adapter in tests.

Recommendation shape: _"Define a port at the seam, implement a network adapter for production and an in-memory adapter for testing, so the logic sits in one deep module even though it's deployed across a network."_

### 4. True external (Mock)

Third-party services you don't control (payment, messaging, mail, any vendor API). The deepened module takes the external dependency as an **injected port**; tests provide a **mock adapter**. You can't run the real thing in tests, so the mock is mandatory — but it's still just one of two adapters across a real seam.

---

## Seam discipline

- **One adapter means a hypothetical seam. Two means a real one.** Don't introduce a port unless at least two adapters are justified (typically production + test). A single-adapter seam is just indirection that taxes every reader without buying flexibility anyone uses.
- **Internal seams vs external seams.** A deep module can have internal seams (private to its implementation, used by its own tests) as well as the external seam at its interface. Don't leak internal seams through the public interface just because tests happen to use them — that re-shallows the module you just deepened.

---

## Testing strategy: replace, don't layer

- Old unit tests written against the shallow modules become **waste** once tests at the deepened module's interface exist — delete them, don't keep both.
- Write new tests at the **deepened module's interface**. The interface is the test surface.
- Tests assert on **observable outcomes through the interface**, not internal state.
- Good tests survive internal refactors because they describe behaviour, not implementation. If a test has to change every time the implementation changes, it's testing past the interface — a sign the seam is in the wrong place.

---

## Pre-merge checklist

Before recommending a merge of N shallow modules into one deep module:

1. **Run the deletion test** on each shallow module. Keep only the ones whose deletion would scatter complexity across callers.
2. **Classify every dependency** into one of the four categories above. The hardest category present sets the testing strategy.
3. **Count required adapters.** Two or more → a port is justified. Exactly one → no port; keep the dependency internal.
4. **Confirm the deepened interface is smaller** than the sum of the interfaces it replaces. If it isn't, the merge moved complexity rather than concentrating it — not a deepening.
