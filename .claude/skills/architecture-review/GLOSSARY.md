# Architecture Review — Glossary

Shared vocabulary for every observation and suggestion this review makes. **Use these terms exactly — don't substitute.** Consistent language is the whole point: don't drift into "component," "service," "API," or "boundary." The terms come from Ousterhout (_A Philosophy of Software Design_) and Feathers (_Working Effectively with Legacy Code_).

---

## Terms

**Module**
Anything with an interface and an implementation. Deliberately **scale-agnostic** — applies equally to a function, a class, a package, or a tier-spanning slice.
_Avoid_: unit, component, service.

**Interface**
Everything a caller must know to use the module correctly. It is the **full contract**: the type signature, but also invariants, ordering constraints, error modes, required configuration, and performance characteristics. Not just the type-level surface.
_Avoid_: API, signature (too narrow — those name only the type-level part).

**Implementation**
The code inside a module — its body. Distinct from **Adapter**: a thing can be a small adapter with a large implementation (a real database repo) or a large adapter with a small implementation (an in-memory fake). Reach for "adapter" when the seam is the topic; "implementation" otherwise.

**Depth**
**Leverage per unit of interface complexity.** A module is **deep** when a large amount of behaviour sits behind a small interface — high leverage, good. A module is **shallow** when the interface is nearly as complex as the implementation — a thin wrapper or pass-through, bad. Depth is a property of the **interface**, not of how many lines the implementation has.

**Leverage**
What callers get from depth: more capability per unit of interface they have to learn. One implementation pays back across N call sites and M tests.

**Locality**
What maintainers get from depth: where change, bugs, knowledge, and verification **concentrate**. A deep module means fixes land in one place; a shallow one scatters maintenance across every caller. Fix once, fixed everywhere.

**Seam** _(from Michael Feathers)_
A place where you can alter behaviour **without editing in that place** — the location at which a module's interface lives. Choosing where to put the seam is its own design decision, distinct from what goes behind it.
_Avoid_: boundary (overloaded with DDD's bounded context).

**Adapter**
A concrete thing that satisfies an interface at a seam. Names a **role** (what slot it fills), not substance (what's inside).

---

## Principles

- **The deletion test.** Imagine deleting the module. If complexity **vanishes**, the module was hiding nothing — a pass-through, a candidate to delete or merge. If complexity **reappears scattered across N callers**, the module was earning its keep — leave it. A "yes, deleting it would scatter complexity" is the signal that a module is genuinely deep.

- **Depth is a property of the interface, not the implementation.** A deep module can be internally composed of small, swappable parts — they just aren't part of the interface. A module can have **internal seams** (private to its implementation, used by its own tests) as well as the **external seam** at its interface.

- **The interface is the test surface.** Callers and tests cross the same seam. If you find yourself wanting to test _past_ the interface, the module is probably the wrong shape.

- **One adapter = a hypothetical seam. Two adapters = a real one.** Don't introduce a port/abstraction unless something actually varies across it (typically production + test). A single-adapter seam is just indirection.

---

## Rejected framings

- **Depth as ratio of implementation-lines to interface-lines** (a literal reading of Ousterhout): rewards padding the implementation. Use **depth-as-leverage** instead.
- **"Interface" as only the type-level surface** (the language `interface` keyword or a class's public method list): too narrow — interface here includes every fact a caller must know.
- **"Boundary"**: overloaded with DDD's bounded context. Say **seam** or **interface**.
