<!-- TUTORIAL — beginner-first guide for the AI Coding Starter.
     Written in Polish on purpose (developer-facing manual). Code/commands stay in English.
     Add new scenarios below the divider following the SAME step rhythm as Scenario 1. -->

# 🚀 Samouczek


Ten template to **zestaw narzędzi**, dzięki którym Claude Code staje się Twoim partnerem do budowania aplikacji — pamięta projekt, planuje, koduje, sprawdza jakość i commituje.

---

## 🚦 Który przypadek jest Twój?

Wybierz wiersz, który najbardziej do Ciebie pasuje, i kliknij scenariusz.

| Twoja sytuacja | Scenariusz |
|----------------|-----------|
| Zaczynam **nowy projekt**, to będzie **tylko backend** | 👉 **[Scenariusz 1: Nowy projekt backendowy](#scenariusz-1-nowy-projekt-backendowy-od-zera)** |
| Zaczynam **nowy projekt** z **backendem i frontendem** (jest interfejs użytkownika) | 👉 **[Scenariusz 2: Nowy projekt z frontendem](#scenariusz-2-nowy-projekt-z-frontendem-od-zera)** |
| **Mam już gotowe designy** (pliki HTML / Figma) i chcę je wdrożyć | 👉 **[Scenariusz 3: Mam gotowe designy](#scenariusz-3-mam-gotowe-designy-htmlfigma)** |
| Chcę **wnieść ten workflow do ISTNIEJĄCEGO projektu** (kod już jest) | 👉 **[Scenariusz 4: Istniejący projekt (brownfield)](#scenariusz-4-istniejący-projekt-brownfield)** |
| Jestem **analitykiem (BA)** — chcę tworzyć zadania w Jirze | 👉 **[Scenariusz 5: Ścieżka analityka (BA → Jira)](#scenariusz-5-ścieżka-analityka-ba--jira)** |

---

## 📖 Jak czytać ten samouczek

Każdy krok ma zawsze ten sam, powtarzalny rytm. Szukaj tych czterech ikon:

- 📋 **Wpisz** — dokładnie to przepisz do Claude Code
- 💬 **Co się stanie** — czego się spodziewać po tej komendzie
- ✅ **Skąd wiesz, że OK** — jak sprawdzić, że krok się udał, zanim pójdziesz dalej
- ⏭️ **Dalej** — co robić następnie



---

# Scenariusz 1: Nowy projekt backendowy

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

---

# Scenariusz 2: Nowy projekt z frontendem (od zera)

**Co zbudujemy:** to samo TODO, ale **z ekranem** — backend (API) + frontend (interfejs, w którym klikasz). Użytkownik dodaje zadania w przeglądarce, nie tylko przez API.

**Czego się nauczysz:** tego samego rytmu co w Scenariuszu 1 **plus** dwóch nowych komend dla warstwy wizualnej: **`/design`** (projekt UI) i **`/test-e2e`** (testy w przeglądarce).

> 📌 **To rozszerzenie Scenariusza 1, nie nowy schemat.** Rytm `PRD → stack → backlog → prime → brainstorm → plan → execute → check → commit` jest identyczny. Poniżej opisuję **tylko to, co dochodzi lub się zmienia** — resztę bierzesz wprost ze Scenariusza 1. Jeśli nie robiłeś S1 — zacznij od niego, tu będzie łatwiej.

---

## Zanim zaczniesz (jednorazowo)

Tak samo jak w Scenariuszu 1 — [stwórz swoje repo z template'u i pobierz je](#stwórz-swoje-repo-z-tego-templateu-i-pobierz-je). Otwórz sesję Claude Code w folderze projektu (`claude`).

---

### Krok 1–3: PRD, stack, backlog — jak w S1, z jedną różnicą

Przejdź [Krok 1](#krok-1-opisz-co-chcesz-zbudować-prd), [Krok 2](#krok-2-pozwól-claude-dobrać-technologię-stack) i [Krok 3](#krok-3-rozpisz-plan-dostarczenia-backlog) **dokładnie jak w Scenariuszu 1**. Jedyna różnica jest w opisie PRD — napisz wprost, że chcesz **interfejs użytkownika**:

📋 **Wpisz** (przykład):
```
/setup:create-PRD Zbuduj aplikację listy zadań (TODO) z interfejsem w przeglądarce: dodawanie zadania, lista zadań, odhaczanie jako zrobione, usuwanie. Backend (API) + frontend (web UI). Bez logowania. Uwzględnij materiały z .agents/sources/.
```

💬 **Co się zmienia dalej:** `/setup:stack-research` zaproponuje teraz **dwie** warstwy (backend + frontend), a `/setup:create-backlog` rozpisze backlog, w którym oprócz `E0-1: szkielet projektu` pojawią się zadania frontendowe. Reszta (jak czytać, jak sprawdzić) — identyczna.

⏭️ **Dalej:** Krok 4.

---

### Krok 4–5: Szkielet + reguły projektu — jak w S1

Wykonaj [Krok 4](#krok-4-zbuduj-szkielet-projektu-pierwszy-przejazd-pipelineem) (`/prime` → `/brainstorm` → `/plan-feature` → `/execute` na zadaniu `E0-1`) i [Krok 5](#krok-5-stwórz-reguły-projektu-claudemd) (`/setup:create-CLAUDE_MD`) **bez zmian**. Szkielet będzie teraz zawierał też część frontendową (Claude wymieni utworzone pliki).

⏭️ **Dalej:** Krok 6 — pierwsza funkcja, tu zaczyna się część nowa.

---

### Krok 6: Zaprojektuj pierwszą funkcję (brainstorm) — jak w S1

Świeży czat → `/prime`, potem zaprojektuj funkcję — [tak jak w Kroku 6 S1](#krok-6-zaprojektuj-pierwszą-funkcję-brainstorm):

📋 **Wpisz:**
```
/prime
/brainstorm dodawanie i wyświetlanie zadań TODO (API + ekran)
```

💬 **Co się stanie:** powstanie spec w `.agents/specs/` — opis *co i jak*, łącznie z tym, że funkcja ma warstwę wizualną. Wciąż **bez kodu**.

⏭️ **Dalej:** Krok 6.5 — **NOWY krok: projekt UI.**

---

### 🆕 Krok 6.5: Zaprojektuj wygląd (design)

> To krok, którego **nie ma** w Scenariuszu 1. Zanim napiszesz frontend, najpierw projektujesz, jak ma wyglądać — żeby kod realizował konkretny, przemyślany layout, a nie „cokolwiek".

📋 **Wpisz:**
```
/design ekran listy zadań TODO
```

💬 **Co się stanie:** Claude wczyta wiedzę o projektowaniu i tokeny designu projektu, zapyta, czy chcesz **1 wariant** (dopracowanie) czy **3** (różne podejścia), wygeneruje makietę(-y) i **sam sprawdzi** każdą względem zasad jakości, zanim Ci ją pokaże. Zatwierdzony projekt zapisze do `.agents/specs/design/Ready/`.

✅ **Skąd wiesz, że OK:** w `.agents/specs/design/Ready/` jest plik z makietą Twojego ekranu, a Claude potwierdził, że przeszła bramkę self-check.

⏭️ **Dalej:** Krok 7 — plan i kod.

<details>
<summary>💡 TIP — czym jest „Ready/" i dlaczego design jest osobnym krokiem</summary>

`.agents/specs/design/Ready/` to umówione miejsce na **zatwierdzone** makiety — sięgają do niego później bramka `/gates:design-quality-check` i pipeline `/orchestrate`, żeby porównać gotowy UI z projektem. Oddzielenie „jak ma wyglądać" (design) od „jak to napisać" (plan) sprawia, że `/execute` ma konkretny wzorzec do odwzorowania, a nie zgaduje layout. Jeśli **masz już gotowe designy** (HTML/Figma) i nie chcesz ich generować — to Scenariusz 3.
</details>

---

### Krok 7–8: Plan i kod (plan-feature → execute) — jak w S1

Wykonaj [Krok 7](#krok-7-zrób-szczegółowy-plan-plan-feature) i [Krok 8](#krok-8-napisz-kod-execute) **bez zmian**. Różnica jest tylko w treści: `/plan-feature` uwzględni makietę z `Ready/`, a `/execute` napisze **i backend, i frontend** wg planu.

⏭️ **Dalej:** Krok 9 — jakość, tu dochodzą testy przeglądarki.

---

### Krok 9: Sprawdź jakość (check-implementation) — jak w S1

Wykonaj [Krok 9](#krok-9-sprawdź-jakość-check-implementation) **bez zmian** — ta sama pętla code-review → bramki, zostawia czyste drzewo, sam nie commituje.

⏭️ **Dalej:** Krok 9.5 — **NOWE: testy w przeglądarce.**

---

### 🆕 Krok 9.5: Przetestuj klikając (test-e2e)

> Drugi krok, którego nie ma w S1. Skoro masz ekran, warto sprawdzić, że **realnie działa w przeglądarce** — kliknięcie „dodaj", pojawienie się zadania, odhaczenie.

📋 **Wpisz:**
```
/test-e2e dodawanie zadania
```

💬 **Co się stanie:** Claude **najpierw wyklika** Twój ekran w prawdziwej przeglądarce (przez Playwright), pokaże plan testu i **poczeka na Twoją zgodę** — dopiero potem wygeneruje testy E2E i je uruchomi.

✅ **Skąd wiesz, że OK:** powstał plik testu E2E, a uruchomienie kończy się na zielono (Claude pokaże wynik).

⏭️ **Dalej:** Krok 10 — commit.

<details>
<summary>💡 TIP — co, jeśli nie mam jeszcze skonfigurowanego Playwrighta</summary>

`/test-e2e` korzysta z MCP Playwright (automatyzacja przeglądarki). Jeśli backend frontu nie wystawia jeszcze serwera deweloperskiego albo nie masz Playwrighta, Claude o tym powie i zaproponuje, co skonfigurować. Na pierwszym, prostym ekranie możesz ten krok pominąć i wrócić do niego później — testy E2E nie są wymagane do commita. Argument może też być pusty (`/test-e2e`) — wtedy bierze listę przepływów z `Testing Strategy` w aktywnym planie.
</details>

---

### Krok 10–11: Commit i push — jak w S1

[Krok 10 (`/commit`)](#krok-10-zapisz-zmiany-commit) i [Krok 11 (`/push`)](#krok-11-wyślij-na-github-opcjonalnie) — **bez zmian**.

---

## 🎉 Gratulacje — masz działającą aplikację z ekranem!

Cykl jest ten sam co w S1, wzbogacony o dwa kroki wizualne:
**pomysł → PRD → stack → backlog → szkielet → brainstorm → 🆕 design → plan → kod → jakość → 🆕 testy E2E → commit.**

**Kolejna funkcja z ekranem?** Powtarzasz: świeży czat → `/prime` → `/brainstorm <funkcja>` → `/design <ekran>` → `/plan-feature` → `/execute` → `/check-implementation` → `/test-e2e <flow>` → `/commit`. Funkcje *bez* warstwy wizualnej (czysto backendowe) robisz krótszą ścieżką z S1 — pomijasz `/design` i `/test-e2e`.

> Masz już gotowe makiety (HTML/Figma) zamiast generować je `/design`? → **Scenariusz 3**.

---

# Scenariusz 3: Mam gotowe designy (HTML/Figma)

**Co zbudujemy:** to samo TODO z ekranem co w Scenariuszu 2 — ale **nie generujemy** wyglądu komendą `/design`. Wygląd już masz: makiety HTML albo plik w Figmie. Zadaniem Claude jest **wdrożyć je wiernie** i sprawdzić, czy kod zgadza się z projektem co do piksela.

**Czego się nauczysz:** jak **wprowadzić zewnętrzny design** do template'u i jak działa **bramka parytetu** `/gates:design-quality-check` (kod vs. projekt).

> 📌 **To wariant Scenariusza 2.** Różnica jest jedna i prosta: zamiast *generować* makietę (`/design`), **dostarczasz własną** — i dochodzi krok sprawdzania zgodności z nią. Cały rytm `PRD → stack → backlog → szkielet → brainstorm → plan → execute → check → commit` jest identyczny. Jeśli nie robiłeś S2 — przejrzyj go najpierw, tu będzie jasniej.

---

## Zanim zaczniesz (jednorazowo)

Tak samo jak wcześniej — [stwórz swoje repo z template'u i pobierz je](#stwórz-swoje-repo-z-tego-templateu-i-pobierz-je), otwórz sesję Claude Code (`claude`).

**Przygotuj swój design** — wybierz JEDEN ze sposobów:

- **Mam makiety HTML/CSS** → najprostsze. Zapamiętaj, gdzie są te pliki (w Kroku 6.5 przeniesiemy je w umówione miejsce).
- **Mam projekt w Figmie** → upewnij się, że masz podpięty **Figma MCP** w Claude Code (i link do węzła/ekranu). Wtedy Claude pobierze design **na żywo** z Figmy.

⏭️ **Dalej:** Kroki 1–6 jak w S2.

---

### Krok 1–6: PRD, stack, backlog, szkielet, reguły, brainstorm — jak w S2

Przejdź [Krok 1–3](#krok-13-prd-stack-backlog--jak-w-s1-z-jedną-różnicą), [Krok 4–5](#krok-45-szkielet--reguły-projektu--jak-w-s1) i [Krok 6 (brainstorm)](#krok-6-zaprojektuj-pierwszą-funkcję-brainstorm--jak-w-s1) **dokładnie jak w Scenariuszu 2** — łącznie z opisem PRD wskazującym, że jest interfejs użytkownika. Nic się tu nie zmienia.

⏭️ **Dalej:** Krok 6.5 — tu zaczyna się różnica między S3 a S2.

---

### 🔀 Krok 6.5: Wprowadź swój design (zamiast generować)

> W Scenariuszu 2 ten krok *generował* makietę przez `/design`. **Tu go pomijasz** — bo design już masz. Zamiast tego **udostępniasz** swój projekt Claude.

**Wariant A — masz makiety HTML/CSS:**

Połóż każdą makietę w umówionym katalogu **`.agents/specs/design/Ready/{obszar}/{Nazwa}.html`** (np. `.agents/specs/design/Ready/todo/TaskList.html`). Możesz to zrobić ręcznie albo poprosić Claude:

📋 **Wpisz** (przykład):
```
Mam gotowe makiety w folderze ./moje-designy. Przenieś je do .agents/specs/design/Ready/ w odpowiednie obszary i dodaj wymagany frontmatter (name, priority, status).
```

**Wariant B — masz Figmę:**

Nic nie kopiujesz. Trzymaj pod ręką **link do węzła/ekranu w Figmie** — podasz go w kroku sprawdzania parytetu. Bramka pobierze design na żywo z Figmy (Figma jest źródłem nadrzędnym).

💬 **Co się stanie:** ustawiasz **źródło prawdy o wyglądzie**. Od teraz `/plan-feature`, `/execute` i bramka parytetu mają konkretny wzorzec do odwzorowania — zamiast zgadywać layout.

✅ **Skąd wiesz, że OK:** (A) w `.agents/specs/design/Ready/.../` leżą Twoje pliki `.html` z frontmatterem; (B) masz działający Figma MCP i link do ekranu.

⏭️ **Dalej:** Krok 7 — plan i kod.

<details>
<summary>💡 TIP — dlaczego akurat „Ready/" i co to za frontmatter</summary>

`.agents/specs/design/Ready/` to to samo miejsce, do którego `/design` zapisuje *wygenerowane* makiety — więc reszta narzędzi (bramka parytetu, `/orchestrate`) szuka projektu zawsze tam, niezależnie czy powstał automatycznie, czy go wniosłeś. Frontmatter (`name` + `priority` + `status`) na górze pliku pozwala narzędziom rozpoznać i uporządkować makiety. Figma nie wymaga kopiowania do `Ready/` — przy podpiętym MCP bramka czyta projekt bezpośrednio i wygrywa on z ewentualnym statycznym HTML przy rozbieżności.
</details>

---

### Krok 7–9: Plan, kod, jakość — jak w S2

Wykonaj [Krok 7–8 (`/plan-feature` → `/execute`)](#krok-78-plan-i-kod-plan-feature--execute--jak-w-s1) i [Krok 9 (`/check-implementation`)](#krok-9-sprawdź-jakość-check-implementation--jak-w-s1) **bez zmian**. `/execute` napisze kod odwzorowujący **Twoją** makietę z `Ready/` (lub z Figmy).

⏭️ **Dalej:** Krok 9.4 — **NOWE w S3: sprawdzenie zgodności z designem.**

---

### 🆕 Krok 9.4: Sprawdź zgodność z projektem (design-quality-check)

> Krok specyficzny dla S3 (i przydatny zawsze, gdy masz wzorcowy design). Skoro masz **konkretny** projekt, warto zweryfikować, czy kod odwzorował go **dokładnie** — kolory, odstępy, typografia, zachowanie.

📋 **Wpisz** (A — HTML; podaj nazwę sekcji):
```
/gates:design-quality-check lista zadań
```
📋 lub (B — Figma; dodaj link do węzła):
```
/gates:design-quality-check lista zadań <link-do-wezla-figma>
```

💬 **Co się stanie:** Claude porówna gotowy ekran z Twoim wzorcem i **wypisze każdą rozbieżność** (wizualną, układu, dostępności, zachowania). **Niczego nie naprawia** — tylko raportuje. Ty decydujesz, co poprawić.

✅ **Skąd wiesz, że OK:** dostajesz raport rozbieżności. Brak różnic (albo same „autoryzowane") = parytet osiągnięty.

⏭️ **Dalej:** jeśli są rozbieżności → popraw je (`/execute` lub `/check-implementation`) i uruchom bramkę ponownie. Gdy czysto → Krok 9.5.

<details>
<summary>💡 TIP — to bramka raportująca, nie naprawiająca</summary>

`/gates:design-quality-check` jest odwrotnością `/gates:verify-implementation`: tamta sprawdza kod względem *planu*, ta — wierność względem *designu*. Filozofia: **w designie nie ma „drobnych" różnic** — jeśli wzorzec ma jakąś wartość, a kod inną, to defekt. Bramka go wymieni; decyzja o akceptacji należy do Ciebie. Przy podpiętej Figmie audyt bierze wartości na żywo z Figmy; bez niej — ze statycznego HTML w `Ready/`.
</details>

---

### Krok 9.5–11: Testy E2E, commit, push — jak w S2

[Krok 9.5 (`/test-e2e`)](#-krok-95-przetestuj-klikając-test-e2e), [Krok 10 (`/commit`)](#krok-10-zapisz-zmiany-commit) i [Krok 11 (`/push`)](#krok-11-wyślij-na-github-opcjonalnie) — **bez zmian**.

---

## 🎉 Gratulacje — wdrożyłeś własny design!

Cykl jak w S2, ale wygląd pochodzi od Ciebie, a kod jest z nim zweryfikowany co do piksela:
**pomysł → PRD → stack → backlog → szkielet → brainstorm → 🔀 Twój design w `Ready/` → plan → kod → jakość → 🆕 parytet z designem → testy E2E → commit.**

**Kolejny ekran z gotowym designem?** Powtarzasz: świeży czat → `/prime` → `/brainstorm <funkcja>` → *(połóż makietę w `Ready/`)* → `/plan-feature` → `/execute` → `/check-implementation` → `/gates:design-quality-check <sekcja>` → `/test-e2e <flow>` → `/commit`.

> Chcesz, żeby Claude **sam zaprojektował** wygląd zamiast dostarczać własny? → **Scenariusz 2** (krok `/design`).

---

# Scenariusz 4: Istniejący projekt (brownfield)

**Co zrobimy:** weźmiemy **projekt, który już ma kod** (powstał bez tego template'u) i **wniesiemy do niego cały ten workflow** — pamięć projektu, mapę architektury, reguły, backlog. Cel: od jutra pracować nad tym kodem tym samym rytmem co w S1–S3.

**Czego się nauczysz:** jak Claude **rozumie cudzy/starszy kod** komendą **`/setup:map-codebase`** i jak z tego zrozumienia powstaje pamięć projektu, do której podpinasz dalszą pracę.

> 📌 **To inny początek niż S1–S3.** Tam zaczynałeś od pustego pomysłu (PRD → stack → szkielet). Tu **kod już jest** — więc najpierw template trzeba *wnieść* do repo, a Claude musi *zrozumieć* to, co zastał. Dopiero potem wracasz do znajomego rytmu `brainstorm → plan → execute → check → commit`. 🔴 Trudniejszy, bo dotyczy realnego, istniejącego kodu.

---

## Zanim zaczniesz — wnieś template do swojego repo

> **Nie** używasz tu „Use this template". Twój projekt już istnieje — to do **niego** dokładamy narzędzia.

W terminalu, w folderze **swojego** projektu (zrób najpierw kopię/branch zapasowy):

```bash
# w katalogu istniejącego projektu
git checkout -b adopt-ai-workflow      # bezpieczny branch na adopcję
# skopiuj z template'u tylko warstwę narzędzi (bez jego kodu/aplikacji):
#   .claude/  i  .agents/  oraz  CLAUDE.md
```

📋 Najprościej: pobierz template obok, skopiuj z niego `.claude/`, `.agents/` i `CLAUDE.md` do swojego repo:
```bash
git clone https://github.com/mrozmk/AI_Coding_Starter /tmp/ai-starter
cp -R /tmp/ai-starter/.claude /tmp/ai-starter/.agents /tmp/ai-starter/CLAUDE.md .
```

💬 **Co się stanie:** Twój projekt dostaje warstwę `.claude/` (komendy, hooki, ustawienia) i `.agents/` (pamięć, reference, specs, plans) oraz `CLAUDE.md` z regułami. **Twój kod pozostaje nietknięty** — dokładamy tylko rusztowanie.

✅ **Skąd wiesz, że OK:** obok swojego kodu masz teraz foldery `.claude/` i `.agents/` oraz plik `CLAUDE.md` (z placeholderami `{...}` — wypełnimy je za chwilę).

⏭️ **Dalej:** otwórz sesję Claude Code (`claude`) i przejdź do Kroku 1.

<details>
<summary>💡 TIP — dlaczego kopiujemy tylko `.claude/`, `.agents/` i `CLAUDE.md`</summary>

To są jedyne części template'u, które są „silnikiem" workflow — reszta repozytorium template'u (przykładowy `README.md`, `docs/`, `LICENSE`) dotyczy *samego template'u*, nie Twojego projektu. Wnosząc tylko warstwę narzędzi, nie mieszasz swojego kodu z cudzym. Branch `adopt-ai-workflow` daje Ci czysty punkt cofnięcia, gdyby coś poszło nie tak.
</details>

---

### Krok 1: Pozwól Claude zrozumieć Twój kod (map-codebase)

> To **serce** tego scenariusza i zarazem jego największa różnica względem S1–S3. Zamiast pisać PRD od zera, Claude **czyta istniejący kod** i odtwarza z niego wiedzę o projekcie.

📋 **Wpisz:**
```
/prime
/setup:map-codebase
```

💬 **Co się stanie:** `/setup:map-codebase` przeskanuje repo, podzieli je na moduły i **równolegle** (wiele agentów) zrozumie kod, a potem wytworzy: `.agents/memory/architecture.md` (mapa projektu) **oraz zrekonstruowany `docs/PRD.md`** (co ta aplikacja właściwie robi). Po drodze **dwa razy zapyta Cię o zgodę** — najpierw co analizować (zakres, lista pomijanych plików), potem przy podsumowaniu. Na koniec sam pociągnie dalej: odświeży brief i wygeneruje `CLAUDE.md`.

✅ **Skąd wiesz, że OK:** powstały `.agents/memory/architecture.md` i `docs/PRD.md`, a `CLAUDE.md` ma wypełnione sekcje o Twoim projekcie (nie placeholdery `{...}`).

⏭️ **Dalej:** Krok 2.

> ⚠️ **Mały projekt (< ~50 plików)?** `/setup:map-codebase` sam Ci powie, że fan-out jest zbędny i poprosi, żebyś zamiast niego uruchomił po prostu **`/setup:create-CLAUDE_MD`** (analizuje kod bezpośrednio). Wtedy pomijasz map-codebase i robisz tę jedną komendę.

<details>
<summary>💡 TIP — dlaczego to oddzielna, „ciężka" komenda</summary>

Duży, istniejący kod nie zmieści się w jednym kontekście. `/setup:map-codebase` rozkłada pracę na wielu agentów, z których **każdy zwraca tylko zwięzłe streszczenie (~1–2k)** — dzięki temu rozmiar repo wpływa na *liczbę* agentów, nie na zapchanie kontekstu. To jednorazowy bootstrap: raz zrozumiany kod ląduje w pamięci projektu (`architecture.md`, PRD, brief), z której korzystają wszystkie kolejne komendy. Pełny opis: [README → Adoption scenarios](../README.md).
</details>

---

### Krok 2: Rozpisz backlog na bazie istniejącego kodu (opcjonalnie)

> Tak jak w S1, backlog jest źródłem prawdy o kolejności pracy — ale tu powstaje **na bazie zmapowanego kodu i zrekonstruowanego PRD**, nie pustego pomysłu.

📋 **Wpisz:**
```
/setup:create-backlog
```

💬 **Co się stanie:** Claude przeczyta zrekonstruowany PRD + `architecture.md` i rozpisze mapę dostarczenia dla **dalszego rozwoju** projektu. Uwaga na różnicę: zadanie `E0-1` **nie** jest „stwórz szkielet" (szkielet już masz) — będzie to „zaadaptuj/uporządkuj istniejący szkielet" albo zostanie pominięte.

✅ **Skąd wiesz, że OK:** powstał `.agents/backlog.md` z zadaniami opisującymi to, co chcesz dalej zbudować/zmienić w istniejącym kodzie.

⏭️ **Dalej:** Krok 3 — i od tej pory jesteś już w znajomym rytmie.

> 💡 Backlog jest opcjonalny. Jeśli masz konkretną zmianę do wprowadzenia od razu, możesz go pominąć i przejść do Kroku 3, podając temat wprost w `/brainstorm`.

---

### Krok 3: Pracuj jak w S1 — kolejna zmiana w istniejącym kodzie

> Od tego miejsca **brownfield wygląda identycznie jak greenfield.** Masz już pamięć projektu, mapę i reguły — więc każda zmiana to ten sam cykl co w Scenariuszu 1, tyle że Claude działa na realnym, istniejącym kodzie.

📋 **Wpisz** (świeży czat na każdą zmianę):
```
/prime
/brainstorm <opis zmiany, np. dodaj eksport zadań do CSV>
/plan-feature
/execute
/check-implementation
/commit
```

💬 **Co się stanie:** dokładnie to samo co w [Krokach 6–10 Scenariusza 1](#krok-6-zaprojektuj-pierwszą-funkcję-brainstorm) — z tą różnicą, że `/brainstorm` i `/plan-feature` uwzględniają **istniejącą architekturę** (z `architecture.md`), więc nowy kod wpasowuje się w to, co już jest, zamiast tworzyć duplikaty.

✅ **Skąd wiesz, że OK:** zmiana jest zaimplementowana zgodnie z istniejącymi wzorcami projektu, bramki jakości przeszły, commit utworzony.

⏭️ **Dalej:** powtarzasz Krok 3 dla każdej kolejnej zmiany; `/push` gdy chcesz wypchnąć (jak [Krok 11 S1](#krok-11-wyślij-na-github-opcjonalnie)).

> 🖥️ **Projekt ma frontend / gotowe designy?** Dołóż do tego cyklu kroki z S2/S3 — `/design` (lub własna makieta w `Ready/`), `/gates:design-quality-check`, `/test-e2e`. Brownfield łączy się z każdym z nich.

---

## 🎉 Gratulacje — Twój istniejący projekt mówi teraz tym samym językiem!

Zamiast zaczynać od pomysłu, zaczęliśmy od **kodu, który już był**:
**wnieś template → 🆕 zrozum kod (`map-codebase`) → pamięć + mapa + reguły → backlog → i od teraz zwykły rytm `brainstorm → plan → execute → check → commit`.**

Najtrudniejszą część (zrozumienie zastanego kodu) robisz **raz**. Potem brownfield niczym nie różni się od greenfielda — ta sama pętla, te same komendy, te same bramki jakości.

> Projekt jest nowy, a nie istniejący? → wróć do **Scenariusza 1** (backend) lub **2/3** (z frontendem).

---

# Scenariusz 5: Ścieżka analityka (BA → Jira)

**Co zrobimy:** zamienimy **pomysł** w uporządkowaną pracę — PRD, **backlog** (mapa dostarczenia), a na końcu **zadania w Jirze** dla zespołu. **Bez pisania kodu.** To ścieżka analityka biznesowego / Product Ownera.

**Czego się nauczysz:** jak z surowych materiałów zrobić PRD i backlog, oraz jak **wyeksportować backlog do Jiry** (epiki + taski) komendą `/jira` — pamiętając, że **backlog jest źródłem prawdy, a Jira jego lustrem**.

> 📌 **To ścieżka „bez kodu".** Kończysz tam, gdzie deweloper zaczyna kodować: na gotowym backlogu i zadaniach w Jirze. Pierwsze kroki (PRD, backlog) są wspólne z S1 — różnica jest w priorytecie (kontekst produktowy, nie implementacyjny) i w finale (eksport do Jiry).

---

## Zanim zaczniesz (jednorazowo)

[Stwórz swoje repo z template'u i pobierz je](#stwórz-swoje-repo-z-tego-templateu-i-pobierz-je) (albo dołącz do istniejącego repo zespołu). Otwórz sesję Claude Code (`claude`).

**Chcesz eksportować do Jiry (Krok 4)?** Potrzebujesz skonfigurowanego **MCP Atlassian** — zmiennych `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`. Jak je ustawić: [.agents/reference/jira-mcp-atlassian.md](../.agents/reference/jira-mcp-atlassian.md). Bez tego zrobisz Kroki 1–3 (PRD + backlog), a eksport dołożysz później.

⏭️ **Dalej:** Krok 1.

---

### Krok 1: Zbierz materiały i opisz produkt (sources + PRD)

> Jako analityk najczęściej masz już **materiały wejściowe** — notatki ze spotkań, brief, transkrypcje, zrzuty wymagań. To Twój punkt startu.

**Wrzuć materiały do `.agents/sources/`.** Skopiuj tam wszystkie pliki (briefy, transkrypcje, PDF-y, szkice). Claude przeczyta je **automatycznie** przy tworzeniu PRD.

📋 **Wpisz:**
```
/setup:create-PRD Na podstawie materiałów z .agents/sources/ opisz produkt: <jedno zdanie o co chodzi>. Dla kogo, jaki problem rozwiązuje, co jest w MVP.
```

💬 **Co się stanie:** Claude przeczyta `.agents/sources/`, dopyta o braki (użytkownicy, zakres MVP, co odpuszczamy) i zapisze `docs/PRD.md` — formalny opis *co i dlaczego*.

✅ **Skąd wiesz, że OK:** powstał `docs/PRD.md` z sekcjami „Target Users", „MVP Scope", „Implementation Phases".

⏭️ **Dalej:** Krok 2.

<details>
<summary>💡 TIP — to ten sam PRD co w S1; tu tylko bardziej go „dopieszczasz"</summary>

PRD jest wspólnym fundamentem wszystkich scenariuszy. Różnica w ścieżce BA: zwykle spędzasz tu więcej czasu (to Twój główny produkt pracy), korzystasz mocno z `.agents/sources/` i nie przechodzisz potem do kodu. Stack możesz zostawić pusty albo uruchomić `/setup:stack-research` jako rekomendację dla zespołu — to opcjonalne.
</details>

---

### Krok 2: Wczytaj kontekst produktowy (prime-ba)

> Dla pracy analityka jest **dedykowana** komenda priming — ładuje kontekst **produktowy** (PRD, specy, decyzje, backlog), a nie implementacyjny jak zwykłe `/prime`.

📋 **Wpisz:**
```
/prime-ba
```

💬 **Co się stanie:** Claude wczyta `PRD.md`, materiały z `sources/`, zatwierdzone specy z `.agents/specs/`, decyzje i żywy backlog — czyli wszystko, czego analityk potrzebuje, by rozpisywać i porządkować pracę.

✅ **Skąd wiesz, że OK:** Claude wypisze podsumowanie produktu (dla kogo, MVP, stan prac) bez sięgania po szczegóły implementacyjne.

⏭️ **Dalej:** Krok 3.

---

### Krok 3: Rozpisz backlog (źródło prawdy)

📋 **Wpisz:**
```
/setup:create-backlog
```

💬 **Co się stanie:** Claude zamieni PRD w **mapę dostarczenia** w `.agents/backlog.md` — epiki, zadania z ID (`E0-1`, `E1-2`, …), zależności (DAG) i kolejność. To **kanoniczna** lista „co budować, w jakiej kolejności".

✅ **Skąd wiesz, że OK:** powstał `.agents/backlog.md` z tabelą epików i zadań.

⏭️ **Dalej:** Krok 4 — eksport do Jiry.

> 🔑 **Backlog jest źródłem prawdy, Jira jego lustrem.** Zadania w Jirze tworzysz **na podstawie** backloga (jednokierunkowo: backlog → Jira). Nie utrzymujesz dwóch równoległych list — backlog jest pierwszy i nadrzędny, Jira to jego eksport dla zespołu.

<details>
<summary>💡 TIP — dlaczego backlog, a nie od razu Jira</summary>

Backlog (`.agents/backlog.md`) żyje **w repo, obok kodu** — jest wersjonowany, czytany przez resztę pipeline'u (`/brainstorm`, `/plan-feature`) i nie wymaga połączenia z Jirą. Jira jest świetna dla zespołu, ale jako *odbiorca* struktury, nie jej autor. Gdybyś rozpisywał strukturę bezpośrednio w Jirze, reszta narzędzi template'u nie miałaby z czego korzystać. Dlatego kolejność jest zawsze: PRD → backlog → (opcjonalnie) Jira.
</details>

---

### Krok 4: Wyeksportuj backlog do Jiry (opcjonalnie)

> Krok dla zespołów na Jirze. Przenosisz strukturę z backloga do Jiry — **Ty prowadzisz, Claude wykonuje**, z potwierdzeniem przed każdym zapisem.

**Najpierw epiki.** Dla każdego epiku z backloga utwórz Epic w Jirze:

📋 **Wpisz** (przykład):
```
/jira create Epic — utwórz epiki odpowiadające epikom z .agents/backlog.md
```

**Potem taski pod każdym epikiem** — komendą `bulk` (masowe tworzenie pod jednym parentem):

📋 **Wpisz** (przykład, podmień klucz epiku):
```
/jira bulk PROJ-100 — utwórz taski z zadań epiku E1 z .agents/backlog.md
```

💬 **Co się stanie:** Claude pokaże **plan jako tabelę i poczeka na Twoje `y`** przed jakimkolwiek zapisem do Jiry (Jira nie ma cofania — to celowe zabezpieczenie). Po potwierdzeniu utworzy epiki i taski.

✅ **Skąd wiesz, że OK:** w Jirze pojawiły się epiki i taski odpowiadające backlogowi; Claude pokaże raport z kluczami utworzonych zadań.

⏭️ **Dalej:** gotowe — zespół ma zadania, Ty masz backlog jako źródło prawdy.

> ⚠️ **To eksport ręcznie prowadzony, nie automatyczna synchronizacja.** Nie ma „przycisku sync". Ty decydujesz, co i kiedy przenieść; Claude generuje treść zadań z backloga i tworzy je po Twoim potwierdzeniu. Kierunek jest jednokierunkowy — zmiany robisz w backlogu, potem ewentualnie odtwarzasz w Jirze.

<details>
<summary>💡 TIP — co dokładnie robi `/jira bulk` i dlaczego dry-run</summary>

`/jira bulk <EPIC-KEY> <ile> <temat>` tworzy wiele tasków pod jednym Epikiem. Treść zadań **generuje model** na podstawie tematu i kontekstu (tu: zadań z backloga) — to dlatego krok jest „assisted", a nie automatyczny import 1:1. Każda operacja zapisująca (create, bulk, update, link) ma **twardą zasadę dry-run**: najpierw tabela do akceptacji, dopiero po `y` realny zapis. Pełny opis i parametry: [.claude/skills/jira/SKILL.md](../.claude/skills/jira/SKILL.md).
</details>

---

## 🎉 Gratulacje — masz gotowy backlog i zadania dla zespołu!

Przeszedłeś ścieżkę analityka bez pisania kodu:
**materiały (`sources/`) → PRD → kontekst produktowy (`prime-ba`) → backlog (źródło prawdy) → 🔁 eksport do Jiry (lustro).**

**Co dalej?** Deweloperzy biorą Twój backlog i wchodzą w ścieżki S1–S4: świeży czat → `/prime` → puste `/brainstorm` (samo bierze **następne wolne zadanie z backloga**) → `/plan-feature` → `/execute` → … Twoja struktura napędza ich pracę bez przepisywania.

> Chcesz też **zaprojektować ekrany** dla zespołu (nie tylko zadania)? Zajrzyj do **Scenariusza 2/3** — krok `/design`.

