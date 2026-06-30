<!-- TUTORIAL — beginner-first guide for the AI Coding Starter.
     Written in Polish on purpose (developer-facing manual). Code/commands stay in English.
     Add new scenarios below the divider following the SAME step rhythm as Scenario 1. -->

# 🚀 Samouczek — od zera do działającej aplikacji

> Ten dokument jest **drzwiami wejściowymi** do całego template'u. Jeśli to Twój pierwszy raz — jesteś we właściwym miejscu.
> Pełna referencja frameworka (wszystkie komendy, mechanika, ustawienia) żyje w [README.md](../README.md) — wróć tam, gdy już ogarniesz podstawy.

Ten template to **zestaw narzędzi**, dzięki którym Claude Code staje się Twoim partnerem do budowania aplikacji — pamięta projekt, planuje, koduje, sprawdza jakość i commituje. Sam w sobie **nie zawiera żadnej aplikacji** — dostarcza tylko „rusztowanie", które tę aplikację pomoże Ci zbudować.

---

## 🚦 Który przypadek jest Twój?

Wybierz wiersz, który najbardziej do Ciebie pasuje, i kliknij scenariusz. **Nie czytaj całego dokumentu** — przejdź tylko swoją ścieżkę.

| Twoja sytuacja | Scenariusz | Trudność |
|----------------|-----------|----------|
| Zaczynam **nowy projekt**, to będzie **tylko backend** (API, serwer, narzędzie — bez ekranu) | 👉 **[Scenariusz 1: Nowy projekt backendowy](#scenariusz-1-nowy-projekt-backendowy-od-zera)** | 🟢 najłatwiejszy |
| Zaczynam **nowy projekt** z **backendem i frontendem** (jest interfejs użytkownika) | ⏳ Scenariusz 2 *(wkrótce)* | 🟡 |
| **Mam już gotowe designy** (pliki HTML / Figma) i chcę je wdrożyć | ⏳ Scenariusz 3 *(wkrótce)* | 🟡 |
| Chcę **wnieść ten workflow do ISTNIEJĄCEGO projektu** (kod już jest) | ⏳ Scenariusz 4 *(wkrótce)* | 🔴 |
| Jestem **analitykiem (BA)** — chcę z pomysłu zrobić zadania w Jirze, nie kodować | ⏳ Scenariusz 5 *(wkrótce)* | 🟡 |

> **Dlaczego zaczynamy od backendu?** Bo jest najprostszy — nie ma ekranów, designów ani testów przeglądarki. Gdy opanujesz ten rytm, pozostałe scenariusze to ten sam schemat + kilka dodatkowych kroków.

---

## 📖 Jak czytać ten samouczek

Każdy krok ma zawsze ten sam, powtarzalny rytm. Szukaj tych czterech ikon:

- 📋 **Wpisz** — dokładnie to przepisz do Claude Code
- 💬 **Co się stanie** — czego się spodziewać po tej komendzie
- ✅ **Skąd wiesz, że OK** — jak sprawdzić, że krok się udał, zanim pójdziesz dalej
- ⏭️ **Dalej** — co robić następnie

> Wszystkie „dlaczego" i niuanse są schowane w zwijanych blokach **„ℹ️ Chcesz głębiej?"**. Możesz je pomijać przy pierwszym przejściu — główna ścieżka działa bez nich.

---

# Scenariusz 1: Nowy projekt backendowy (od zera)

**Co zbudujemy:** prościutkie API listy zadań (TODO) — backend, który pozwala dodawać zadania i odhaczać je jako zrobione. Bez ekranu, bez designu. Idealne na pierwszy raz.

**Czego się nauczysz:** pełnego rytmu pracy z tym template'em — od pomysłu do zacommitowanego kodu.



---

## Zanim zaczniesz (jednorazowo)

> Ten samouczek zakłada, że masz już zainstalowane **Claude Code** i **Git**. Jeśli nie — patrz [README → Requirements](../README.md#requirements).

### Stwórz swoje repo z tego template'u i pobierz je

Najprościej — i od razu z **własnym repozytorium na GitHubie** (przyda się później przy wysyłaniu kodu):

1. Wejdź na **[github.com/mrozmk/AI_Coding_Starter](https://github.com/mrozmk/AI_Coding_Starter)** → kliknij zielony przycisk **„Use this template"** → **„Create a new repository"**.
2. Nadaj nazwę (np. `moja-apka-todo`), wybierz prywatne/publiczne, **Create repository**.
3. Skopiuj swoje repo na dysk — w **terminalu** wklej (podmień `twoj-login` na swój):
   ```bash
   git clone https://github.com/twoj-login/moja-apka-todo.git
   cd moja-apka-todo
   ```

💬 **Co się stanie:** powstanie **Twoje własne repo** (kopia template'u z czystą historią), a `git clone` pobierze je lokalnie. Ważne: zdalne repozytorium jest **od razu podpięte** (`origin`) — więc w Kroku 11 wystarczy `/push`, nic nie trzeba konfigurować.

✅ **Skąd wiesz, że OK:** w folderze `moja-apka-todo` widzisz pliki `CLAUDE.md`, `README.md` oraz foldery `.claude/` i `.agents/`. Komenda `git remote get-url origin` pokazuje URL Twojego repo.

⏭️ **Dalej:** Krok 1 — zaczynamy budować.

<details>
<summary>💡 TIP — wolisz bez konta GitHub? (czysty git clone)</summary>

Możesz pobrać template bez tworzenia repo na GitHubie:
```bash
git clone https://github.com/mrozmk/AI_Coding_Starter moja-apka-todo
cd moja-apka-todo
rm -rf .git
git init
```
To daje świeżą, lokalną historię Gita — ale **bez** zdalnego repo. Wtedy w Kroku 11, przed pierwszym `/push`, będziesz musiał ręcznie utworzyć repo i podpiąć je (`git remote add origin <url>`). Wszystkie metody opisuje [README → Quick start](../README.md#quick-start).
</details>

---

## Część właściwa — budujemy TODO API

> Otwórz w tym folderze sesję Claude Code (uruchom `claude` w terminalu).

---

### Krok 1: Opisz, co chcesz zbudować (PRD)

**(opcjonalnie) Wrzuć swoje materiały do `.agents/sources/`.** Masz już jakieś notatki, brief, zrzut rozmowy, szkic, PDF, listę wymagań etc. Skopiuj te pliki do folderu **`.agents/sources/`**. Claude **automatycznie** je przeczyta przy tworzeniu PRD — nie musisz nic więcej robić, sam fakt że tam są wystarczy.

📋 **Wpisz** w Claude Code — możesz podać samą komendę i odpowiadać na pytania, ALBO od razu opisać pomysł:
```
/setup:create-PRD
```
albo z opisem od razu - Claude ma od czego zacząć:
```
/setup:create-PRD Zbuduj mi proste API listy zadań (TODO): dodawanie zadania, lista zadań, oznaczanie jako zrobione, usuwanie. Użytkownik korzysta przez API. Bez logowania i bez UI. Uwzględnij materiały z .agents/sources/.
```

💬 **Co się stanie:** Claude przeczyta Twój opis **oraz** wszystko, co wrzuciłeś do `.agents/sources/`, dopyta o braki (kto użytkownik, co w MVP, co odpuszczamy) i zapisze dokument `docs/PRD.md`.


✅ **Skąd wiesz, że OK:** powstał plik `docs/PRD.md` z sekcjami m.in. „Target Users", „MVP Scope".

⏭️ **Dalej:** Krok 2.

<details>
<summary>💡 TIP — czym jest PRD i po co; czym jest folder sources</summary>

PRD (Product Requirements Document) to opis **co** budujesz i **dlaczego** — nie jak. To fundament, z którego wynika cała reszta: stack, plan, kod. Technologię (stack) celowo zostawiamy na razie pustą — wybierzemy ją w następnym kroku.

`.agents/sources/` to **warstwa wejściowa** projektu — wrzucasz tu surowe materiały (briefy, transkrypcje, szkice, PDF-y), a komendy takie jak `/setup:create-PRD` traktują je jako kontekst wejściowy. Claude **nigdy** ich nie modyfikuje — to Twój materiał źródłowy, tylko do odczytu. Pełny opis: [README → krok 3](../README.md#3-define-the-product).
</details>

---

### Krok 2: Pozwól Claude dobrać technologię (stack)

📋 **Wpisz:**
```
/setup:stack-research
```

💬 **Co się stanie:** Claude przeszuka sieć, zaproponuje 2–3 zestawy technologii pasujące do Twojego PRD (z plusami i minusami), poprosi Cię o zatwierdzenie rekomendacji, a potem **wpisze wybrany stack do PRD**.

> 💡 **Nie musisz znać żadnej technologii.** Na tym etapie wystarczy przeczytać rekomendację Claude i ją zaakceptować. Dla prostego TODO API będzie to coś lekkiego.

✅ **Skąd wiesz, że OK:** w `docs/PRD.md` sekcja „Technology Stack" jest wypełniona, a Claude potwierdził dopisanie decyzji do `.agents/memory/decisions.md`.

⏭️ **Dalej:** Krok 3.

<details>
<summary>💡 TIP — dlaczego stack jest osobnym krokiem</summary>

Wybór technologii to decyzja, którą warto podjąć świadomie i **zapisać**, żeby przyszłe sesje Claude jej nie podważały. Dlatego `/setup:stack-research` nie tylko wybiera, ale i zapisuje uzasadnienie do pamięci projektu. Stack-agnostyczność to cecha tego template'u — komendy działają tak samo niezależnie od tego, czy wybierzesz Node, Pythona, czy cokolwiek innego.
</details>

---

### Krok 3: Rozpisz plan dostarczenia (backlog)

📋 **Wpisz:**
```
/setup:create-backlog
```

💬 **Co się stanie:** Claude przeczyta PRD i rozpisze **mapę dostarczenia** do `.agents/backlog.md` — listę „epików" i zadań w kolejności zależności. **Pierwszym zadaniem zawsze jest `E0-1: szkielet projektu`** — fundament, na którym stoi reszta. (Backlog tylko *opisuje* to zadanie — plików nie tworzy; szkielet powstanie w Kroku 4, gdy je wykonasz.)

✅ **Skąd wiesz, że OK:** powstał plik `.agents/backlog.md`, a w nim na górze tabeli zadanie `E0-1` typu „project scaffold / szkielet projektu".

⏭️ **Dalej:** Krok 4.

> 👥 **Pracujesz z zespołem na Jirze?** Backlog i tak powstaje pierwszy — to **źródło prawdy**. Taski w Jirze tworzysz **na jego podstawie** (ręcznie, komendą `/jira`), nie zamiast niego. Jak to zrobić — patrz **scenariusz 5 (ścieżka analityka/BA)** poniżej. W scenariuszu 1 (solo) Jira nie jest potrzebna.

<details>
<summary>💡 TIP — po co backlog i dlaczego szkielet to zadanie, a nie ręczny krok</summary>

Backlog to **warstwa między PRD a pojedynczym planem**: PRD mówi *co i dlaczego* (proza), backlog mówi *w jakiej strukturze zależności to dostarczyć* (zadania z ID, DAG, kolejność). Dzięki temu szkielet projektu nie jest „ręcznym hackiem w terminalu", tylko **pierwszym normalnym zadaniem pipeline'u** — przejdzie przez te same bramki jakości co każda inna funkcja.

`.agents/backlog.md` jest **jednym źródłem prawdy** dla „co budować w jakiej kolejności".
</details>

---

### Krok 4: Zbuduj szkielet projektu (pierwszy przejazd pipeline'em)

> 🆕 **Tu po raz pierwszy przechodzisz pełny cykl pracy:** `/prime` → `/brainstorm` → `/plan-feature` → `/execute`. Zrobisz go najpierw na **zadaniu szkieletu** (`E0-1` z backloga) — to lekka rozgrzewka. Potem (Krok 6) powtórzysz ten sam cykl na prawdziwej funkcji. Ten rytm to serce całego workflow.

📋 **Wpisz** (kolejno, czekając aż każda komenda skończy):
```
/prime
/brainstorm
/plan-feature
/execute
```

💬 **Co się stanie, po kolei:**
- `/prime` — Claude wczyta kontekst projektu (PRD, backlog, reguły).
- `/brainstorm` — bez argumentu **sam weźmie pierwsze wolne zadanie z backloga** (czyli `E0-1: szkielet projektu`), ogłosi które, i zaprojektuje *jak* ma wyglądać. Spec zapisze do `.agents/specs/`.
- `/plan-feature` — rozpisze plan krok po kroku do `.agents/plans/active/`.
- `/execute` — **utworzy realne pliki szkieletu** (manifest zależności, plik startowy serwera, układ katalogów) i przeniesie plan do `.agents/plans/done/`.

✅ **Skąd wiesz, że OK:** w projekcie pojawiły się startowe pliki właściwe dla Twojego stacku (Claude je wymieni), a plan trafił z `active/` do `done/`. Masz „pusty dom", który zaraz umeblujesz funkcją TODO.

⏭️ **Dalej:** Krok 5.

> 💡 **Puste `/brainstorm` = „weź następne zadanie z backloga".** Gdy nie podasz tematu (i nie wskażesz zadania Jiry), `/brainstorm` sam sięga do `backlog.md`, bierze pierwsze **wolne** zadanie (status `TODO`, zależności spełnione) i upewnia się, że naprawdę nie jest już zrobione. Dzięki temu nie musisz przepisywać nazw zadań — po prostu pracujesz „od góry backloga". Chcesz konkretne zadanie? Podaj temat: `/brainstorm oznaczanie zadania jako zrobione`.

> 💡 **Dlaczego szkielet jest osobnym przejazdem, a nie ręczną komendą?** Bo dzięki temu nawet fundament projektu przechodzi przez normalny, kontrolowany pipeline — a Ty ćwiczysz cały rytm na czymś prostym, zanim zrobisz to na prawdziwej funkcji.

<details>
<summary>💡 TIP — co robi każda z tych czterech komend</summary>

To są cztery filary codziennej pracy:
- **`/prime`** — ładuje kontekst projektu na start sesji (reguły, mapę, streszczenie PRD). Zawsze pierwsza komenda w świeżym czacie.
- **`/brainstorm`** — twarda brama projektowa: najpierw *co i jak*, dopiero potem kod. Zapobiega pisaniu czegoś, co za chwilę trzeba wyrzucić.
- **`/plan-feature`** — zamienia spec w konkretny plan i sam go „przepytuje" (samokrytyka), zanim cokolwiek napisze.
- **`/execute`** — dopiero teraz powstaje kod, ściśle wg planu.

Każda z nich ma w README pełny opis: [Two daily flows](../README.md#two-daily-flows).
</details>

---

### Krok 5: Stwórz reguły projektu (CLAUDE.md)

> Teraz, gdy szkielet **już istnieje**, Claude ma co przeanalizować. (Gdyby repo było puste, ta komenda nie miałaby z czego czytać — dlatego jest po Kroku 4, nie przed.)

📋 **Wpisz:**
```
/setup:create-CLAUDE_MD
```

💬 **Co się stanie:** Claude przeanalizuje Twój świeży szkielet i wygeneruje trzy rzeczy: dopracowany `CLAUDE.md` (reguły projektu), `.agents/memory/architecture.md` (mapę projektu) oraz **nowy `README.md` opisujący TWÓJ projekt** (dotychczasowy przewodnik frameworka przeniesie się do `.claude/README.md`).

✅ **Skąd wiesz, że OK:** `CLAUDE.md` ma teraz wypełnione sekcje o Twoim projekcie (nie placeholdery `{...}`), a w roocie jest README o Twojej apce TODO.

⏭️ **Dalej:** Krok 6 — pierwsza prawdziwa funkcja.

<details>
<summary>💡 TIP — co się stało z oryginalnym README</summary>

Przy pierwszym uruchomieniu `/setup:create-CLAUDE_MD` template robi „zamianę": przenosi swój przewodnik frameworka do `.claude/README.md` (zostaje dostępny), a w roocie tworzy README Twojego projektu. Dzięki temu strona Twojego repo opisuje Twoją apkę, a nie template. Ten samouczek (`docs/TUTORIAL.md`) zostaje nietknięty. Szczegóły: [README → „The root README is yours"](../README.md#the-root-readme-is-yours--the-framework-guide-moves-aside).
</details>

---

### Krok 6: Zaprojektuj pierwszą funkcję (brainstorm)

> 🆕 **Drugi przejazd tym samym cyklem** — tym razem na prawdziwej funkcji TODO. Zwróć uwagę: kroki są praktycznie identyczne jak w Kroku 4. To NIE przypadek — `/brainstorm` → `/plan-feature` → `/execute` → `/check-implementation` → `/commit` to rytm, który powtarzasz dla **każdej** funkcji do końca życia projektu.

Najpierw odśwież kontekst, nowe okni chatu a następnie `/prime`):

📋 **Wpisz:**
```
/prime
```
💬 **Co się stanie:** Claude wczyta reguły projektu, mapę architektury i streszczenie PRD. Teraz „wie", co budujecie — łącznie ze świeżo utworzonym szkieletem.

✅ **Skąd wiesz, że OK:** Claude wypisze krótkie podsumowanie projektu bez ostrzeżeń o pustych plikach.

Teraz zaprojektuj funkcję:

📋 **Wpisz:**
```
/brainstorm dodawanie i wyświetlanie zadań TODO
```

💬 **Co się stanie:** Claude przeanalizuje wymaganie, zaproponuje 2–3 podejścia i zapisze dokument projektowy (spec) do `.agents/specs/`. **Na tym etapie nie powstaje jeszcze żaden kod** — to brama projektowa przed pisaniem.

✅ **Skąd wiesz, że OK:** powstał plik w `.agents/specs/` z datą i nazwą tematu, a Claude opisał wybrane podejście.

⏭️ **Dalej:** Krok 7.

---

### Krok 7: Zrób szczegółowy plan (plan-feature)

📋 **Wpisz:**
```
/plan-feature
```

💬 **Co się stanie:** Claude weźmie najnowszy spec, przeanalizuje Twój kod i napisze **plan krok po kroku** do `.agents/plans/active/`. Potem sam go „przepyta" (samokrytyka), żeby wyłapać luki, zanim cokolwiek napisze.

✅ **Skąd wiesz, że OK:** w `.agents/plans/active/` jest plik z planem (lista konkretnych kroków implementacji), a Claude zgłosił, że plan jest gotowy.

⏭️ **Dalej:** Krok 8.

---

### Krok 8: Napisz kod (execute)

📋 **Wpisz:**
```
/execute
```

💬 **Co się stanie:** Claude wykona plan od góry do dołu — napisze prawdziwy kod TODO API. Gdy skończy, przeniesie plan z `active/` do `done/`.

✅ **Skąd wiesz, że OK:** powstał kod realizujący funkcję, a plan zniknął z `.agents/plans/active/` i pojawił się w `.agents/plans/done/`.

⏭️ **Dalej:** Krok 9 — sprawdzamy jakość.

---

### Krok 9: Sprawdź jakość (check-implementation)

📋 **Wpisz:**
```
/check-implementation
```

💬 **Co się stanie:** Claude uruchomi pełną pętlę jakości — znajdzie i **naprawi** błędy logiczne, posprząta kod, a potem przepuści całość przez bramki (testy, lint, build). Pętla powtarza się (do 3 razy), aż wszystko przejdzie. Na koniec zostawia **czyste, gotowe do commita** drzewo — ale **sam nie commituje**.

✅ **Skąd wiesz, że OK:** Claude zgłasza, że bramki zaakceptowały zmiany („DONE / APPROVE") i kod jest gotowy do commita.

⏭️ **Dalej:** Krok 10.

<details>
<summary>💡 TIP — czym to się różni od zwykłego sprawdzenia</summary>

Jest też `/gates:verify-implementation` — ale ona tylko **raportuje** problemy, nie naprawia. `/check-implementation` **naprawia** (code-review --fix → deep-review → bramka), w pętli. Jeśli masz zainstalowany `codex`, na końcu drugi, niezależny model przejrzy kod „na świeżo" — często łapie to, co pierwszy model przeoczył. Specjalnie nie commituje, żeby ostatnie słowo należało do Ciebie.
</details>

---

### Krok 10: Zapisz zmiany (commit)

📋 **Wpisz:**
```
/commit
```

💬 **Co się stanie:** Claude utworzy commit z porządną wiadomością (w formacie konwencjonalnym, np. `feat: add TODO creation endpoint`) i przy okazji zapisze ewentualne wnioski/decyzje do pamięci projektu.

✅ **Skąd wiesz, że OK:** `git log` pokazuje Twój nowy commit; drzewo robocze jest czyste.

⏭️ **Dalej:** Krok 11 (opcjonalny) lub kolejna funkcja.

---

### Krok 11: Wyślij na GitHub (opcjonalnie)

Jeśli pobrałeś projekt przez **„Use this template"** (zalecana metoda z sekcji „Zanim zaczniesz"), Twoje zdalne repo jest już podpięte — wystarczy:

📋 **Wpisz** (w Claude Code):
```
/push
```

💬 **Co się stanie:** Claude wypchnie Twoje commity do zdalnego repo (najpierw przeskanuje je pod kątem sekretów — to wbudowane zabezpieczenie). Tę komendę powtarzasz po każdym `/commit`, który chcesz opublikować.

✅ **Skąd wiesz, że OK:** push przeszedł bez błędów; odświeżasz stronę repo na GitHubie i widzisz swój kod.

> 🔌 **Pobierałeś przez czysty `git clone` (wariant z TIP-a)?** Wtedy nie masz jeszcze zdalnego repo. Raz, przed pierwszym `/push`: utwórz puste repo na GitHub/GitLab, skopiuj jego URL i w **terminalu** wklej `git remote add origin <url>`. (`git remote add` jest celowo zablokowane dla Claude — robisz to świadomie sam.)

---

## 🎉 Gratulacje — zamknąłeś pełny cykl!

Właśnie przeszedłeś całą drogę: **pomysł → PRD → stack → projekt → plan → kod → jakość → commit**.

### Co dalej?

**Kolejna funkcja?** Powtórz **kroki 6–10** dla nowej rzeczy (np. „oznaczanie zadania jako zrobione"). Świeży czat → `/prime` → `/brainstorm <funkcja>` → `/plan-feature` → `/execute` → `/check-implementation` → `/commit`. To Twój codzienny rytm — ten sam, który przećwiczyłeś dwa razy (na szkielecie i na pierwszej funkcji).

**Chcesz szybciej, bez klikania każdego kroku?** Gdy nabierzesz wprawy, kroki 8–11 możesz zastąpić **jedną** komendą:
```
/orchestrate
```
Ona sama wykona: napisz kod → posprzątaj → sprawdź → commit → push, pętląc poprawki i pytając Cię tylko przy realnym problemie. To ścieżka „hands-off". **Polecam ją dopiero, gdy rozumiesz, co dzieje się w krokach 7–9 osobno** — żeby umieć zareagować, gdy coś pójdzie nie tak.

> Pełne porównanie obu ścieżek (manualnej A i automatycznej B) oraz opis, co dokładnie robi każda komenda: [README → Two daily flows](../README.md#two-daily-flows).

