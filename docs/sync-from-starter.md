# Sync Claude Code workflow z AI_Coding_Starter

**Cel:** zaktualizuj definicje workflow (`.claude/`, `.agents/` framework, `.gitignore`, `.mcp.json.example`) w tym projekcie, używając https://github.com/mrozmk/AI_Coding_Starter jako źródła prawdy. **Zachowaj wszystkie treści specyficzne dla projektu** — wymieniaj tylko pliki workflow.

**Założenie:** projekt ma już `.claude/` i `CLAUDE.md` (nawet w starszej wersji). Jeśli ich nie ma — przerwij i powiedz mi, że to bootstrap, nie sync (wtedy użyj GitHub "Use this template" zamiast tego prompta).

---

## Krok 1: sklonuj starter do katalogu tymczasowego

```bash
rm -rf /tmp/ai-coding-starter-sync
git clone --depth 1 https://github.com/mrozmk/AI_Coding_Starter /tmp/ai-coding-starter-sync
```

Zapisz commit hash startera (`git -C /tmp/ai-coding-starter-sync rev-parse --short HEAD`) — wykorzystasz w finalnym commit message.

## Krok 2: klasyfikacja plików

### Kategoria A — **nadpisz całością ze startera** (workflow definitions, projekt-agnostyczne)

- `.claude/commands/*.md` — wszystkie slash commands
- `.claude/agents/*.md` — definicje subagentów
- `.claude/skills/**` — definicje skilli (np. `jira/SKILL.md`)
- `.claude/templates/*.md` — szablony (np. `CLAUDE-template.md`)

### Kategoria B — **merge ostrożnie**, najpierw pokaż diff i zapytaj

- `.claude/settings.json` — projekt może mieć własne permissions. Strategia: weź **union** wpisów `permissions.allow` / `permissions.deny` ze startera i projektu. Nie usuwaj wpisów z projektu których nie ma w starterze. Pokaż mi diff przed zapisem.
- `.agents/memory/index.md` — `Quick Reference` i `Loader Convention` ze startera, ale `When to Read` może mieć projektowe wiersze dopisane przez `/create-CLAUDE_MD`. Strategia: nadpisz strukturą startera, potem przywróć projektowe wiersze (te których nie ma w starterze).
- `.gitignore` — dopisz brakujące wpisy ze startera (np. `.claude/audit.log`, `.mcp.json`, `.agents/memory/archive/`), **nie usuwaj** projektowych.
- `.mcp.json.example` — nadpisz, jeśli starter ma nowszą wersję.

### Kategoria C — **nie ruszaj** (treść projektu)

- `CLAUDE.md` — projektowe rules. Jeśli starter ma nową strukturę sekcji, zgłoś to w raporcie i zaproponuj patch — ale nie nadpisuj automatycznie.
- `.agents/memory/architecture.md`, `project-brief.md`, `domain/*.md` — regenerowane na podstawie projektu (`/create-CLAUDE_MD`, `/refresh-brief`).
- `.agents/memory/errors.md`, `decisions.md`, `api.md`, `patterns.md` — append-only, historia projektu.
- `.agents/sources/`, `.agents/specs/`, `.agents/plans/`, `.agents/reference/`, `.agents/wiki/`, `.agents/memory/archive/` — content projektu.
- `README.md`, `CHANGELOG.md`, `docs/`, dowolne pliki kodu — dokumentacja i kod projektu.

## Krok 3: dry-run raport (PRZED jakąkolwiek zmianą)

Pokaż mi:

1. **Kategoria A — diff:**
   - Pliki **nowe** (są w starterze, nie ma w projekcie) → lista pełnych ścieżek
   - Pliki **zmienione** (różnią się treścią) → lista + zwięzła informacja "co się zmieniło" (1-2 linie na plik)
   - Pliki **identyczne** → tylko liczba, bez listy
   - Pliki **w projekcie ale nie w starterze** → lista, oznacz jako "projektowy custom command? sprawdź czy potrzebny" — NIE usuwaj automatycznie

2. **Kategoria B — proponowany merge:**
   - `settings.json`: pokaż które wpisy `allow`/`deny`/`hooks` doda starter, a które wpisy projektu zostają nietknięte
   - `index.md`: pokaż które wiersze `When to Read` są projektowe i zostaną przeniesione
   - `.gitignore`: pokaż linie do dopisania

3. **Kategoria C — sygnały:**
   - Jeśli nazwa sekcji w `CLAUDE.md` startera nie pasuje do projektowego CLAUDE.md (np. starter dodał "Loader Convention" do "Automatic Behaviors") — zgłoś jako sugestię, nie wymuszaj

**Czekaj na moją akceptację. Nie pisz nic do dysku przed potwierdzeniem.**

## Krok 4: apply (po mojej akceptacji)

W kolejności:
1. Skopiuj kategorię A (nowe + zmienione) — `cp -r` z `/tmp/ai-coding-starter-sync/` do projektu
2. Wykonaj merge kategorii B — najpierw `settings.json`, potem `index.md`, potem `.gitignore`
3. **Sanity check:**
   - Wszystkie linki w skopiowanych commands rozwiązują się (`rg -o '\[.*?\]\(.*?\.md.*?\)' .claude/commands/`)
   - `.agents/memory/index.md` zawiera sekcję `Loader Convention`
   - `CLAUDE.md` projektu nadal wspomina o aktywnych commands (te w `.claude/commands/`)
4. Posprzątaj: `rm -rf /tmp/ai-coding-starter-sync`

## Krok 5: raport końcowy

Pokaż:
- **Dodane pliki:** lista
- **Zaktualizowane pliki:** lista
- **Zmergowane pliki:** lista (settings.json, index.md, .gitignore)
- **Pominięte (kategoria C):** liczba
- **Sugestie do akcji:** np. "regeneruj `architecture.md` przez `/create-CLAUDE_MD` jeśli format się zmienił", "uruchom `/prime` żeby zwalidować nowy kontekst"

Zaproponuj commit message:
```
chore(workflow): sync .claude commands and skills from AI_Coding_Starter@<short-hash>
```

## Krytyczne zasady

- NIGDY nie usuwaj wpisów z `.claude/settings.json` których nie ma w starterze — to są projektowe permissions
- NIGDY nie nadpisuj plików kategorii C
- NIGDY nie kasuj projektowych slash commands z `.claude/commands/` — zgłoś, zapytaj
- NIGDY nie commituj automatycznie — pokaż message i czekaj na `/commit`
- Dry-run zawsze przed apply
- Posprzątaj `/tmp/ai-coding-starter-sync` na końcu
