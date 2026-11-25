// manual.mjs — the manual task list: fixed tasks, one per manual-only criterion in the run's set,
// and one per needs-review queue item. Each task carries steps and a pass/fail question in en and pl.
import { STATUS } from './criteria.mjs';

const FIXED = [
  {
    id: 'screen-reader', sc: ['1.3.1', '4.1.2', '2.4.3'],
    en: { title: 'Screen-reader pass', steps: ['Open the key flows with VoiceOver (macOS/iOS) or NVDA (Windows).', 'Navigate by headings, landmarks and form fields.', 'Complete each flow without sight.'], question: 'Can every key flow be completed, with every control announced by a meaningful name, role and state?' },
    pl: { title: 'Przejście czytnikiem ekranu', steps: ['Otwórz kluczowe ścieżki z VoiceOver (macOS/iOS) lub NVDA (Windows).', 'Nawiguj po nagłówkach, punktach orientacyjnych i polach formularzy.', 'Ukończ każdą ścieżkę bez patrzenia.'], question: 'Czy każdą kluczową ścieżkę da się ukończyć, a każda kontrolka ma sensowną nazwę, rolę i stan?' },
  },
  {
    id: 'dragging', sc: ['2.5.7'],
    en: { title: 'Dragging alternatives', steps: ['Find every drag interaction (sliders, sortable lists, maps).', 'Try to achieve the same result with single clicks or taps.'], question: 'Does every drag operation have a single-pointer alternative?' },
    pl: { title: 'Alternatywy dla przeciągania', steps: ['Znajdź każde przeciąganie (suwaki, sortowane listy, mapy).', 'Spróbuj uzyskać ten sam efekt pojedynczymi kliknięciami.'], question: 'Czy każde przeciąganie ma alternatywę jednym wskaźnikiem?' },
  },
  {
    id: 'redundant-entry', sc: ['3.3.7'],
    en: { title: 'Redundant entry', steps: ['Walk each multi-step process.', 'Note every field that asks again for information already given.'], question: 'Is previously entered information auto-filled or selectable instead of re-typed?' },
    pl: { title: 'Ponowne wprowadzanie', steps: ['Przejdź każdy proces wieloetapowy.', 'Zanotuj pola, które ponownie pytają o podane już dane.'], question: 'Czy wcześniej podane dane są uzupełniane lub do wyboru zamiast ponownego wpisywania?' },
  },
  {
    id: 'accessible-auth', sc: ['3.3.8'],
    en: { title: 'Accessible authentication', steps: ['Log in and recover a password.', 'Try paste and a password manager; note any puzzle or memory test.'], question: 'Can a user authenticate without a cognitive function test (or with a supported alternative)?' },
    pl: { title: 'Dostępne uwierzytelnianie', steps: ['Zaloguj się i odzyskaj hasło.', 'Spróbuj wkleić hasło i użyć menedżera haseł; zanotuj zagadki i testy pamięci.'], question: 'Czy można się uwierzytelnić bez testu funkcji poznawczych (albo z obsługiwaną alternatywą)?' },
  },
  {
    id: 'media', sc: ['1.2.1', '1.2.2', '1.2.3', '1.2.4', '1.2.5'],
    en: { title: 'Captions and audio description', steps: ['List every audio and video item.', 'Check captions, transcripts and audio description.'], question: 'Does every prerecorded/live media item have the required captions and audio description?' },
    pl: { title: 'Napisy i audiodeskrypcja', steps: ['Wypisz wszystkie materiały audio i wideo.', 'Sprawdź napisy, transkrypcje i audiodeskrypcję.'], question: 'Czy każdy materiał ma wymagane napisy i audiodeskrypcję?' },
  },
  {
    id: 'processes', sc: [],
    en: { title: 'Complete processes and third-party steps', steps: ['Walk every complete process (checkout, registration, contact) end to end, including payment and third-party steps the scan did not reach.'], question: 'Is every step of every complete process accessible?' },
    pl: { title: 'Pełne procesy i kroki zewnętrzne', steps: ['Przejdź każdy pełny proces (zakup, rejestracja, kontakt) od początku do końca, z płatnością i krokami zewnętrznymi, których skan nie objął.'], question: 'Czy każdy krok każdego pełnego procesu jest dostępny?' },
  },
  {
    id: 'content', sc: ['3.1.2', '2.4.6', '3.3.2'],
    en: { title: 'Understandable content', steps: ['Read headings, labels, instructions and error messages in context.'], question: 'Are headings, labels, instructions and errors clear and specific?' },
    pl: { title: 'Zrozumiała treść', steps: ['Przeczytaj nagłówki, etykiety, instrukcje i komunikaty błędów w kontekście.'], question: 'Czy nagłówki, etykiety, instrukcje i błędy są jasne i konkretne?' },
  },
  {
    id: 'beyond-wcag', sc: [],
    en: { title: 'EAA / EN 301 549 requirements beyond WCAG', steps: ['Check the accessibility information about the service, the support channels, identification/authentication/payment, the terms of service, and user preferences for web pages (EN 301 549 clause 9.7).'], question: 'Are the requirements beyond WCAG met for this service?' },
    pl: { title: 'Wymagania EAA / EN 301 549 poza WCAG', steps: ['Sprawdź informacje o dostępności usługi, kanały wsparcia, identyfikację/uwierzytelnianie/płatność, regulamin oraz preferencje użytkownika dla stron (EN 301 549 klauzula 9.7).'], question: 'Czy wymagania poza WCAG są spełnione dla tej usługi?' },
  },
];

export function manualTasks(run) {
  const set = new Set(run.criteria_set || []);
  const tasks = [];
  for (const t of FIXED) {
    const sc = t.sc.filter((s) => set.has(s));
    if (t.sc.length && !sc.length) continue;
    tasks.push({ id: t.id, sc, en: t.en, pl: t.pl });
  }
  const covered = new Set(tasks.flatMap((t) => t.sc));
  for (const c of run.criteria || []) {
    if (c.ceiling !== 'manual-only' || c.status === STATUS.NA || covered.has(c.id)) continue;
    tasks.push({
      id: `sc-${c.id}`, sc: [c.id],
      en: { title: `${c.id} ${c.title || ''}`.trim(), steps: ['No automated contributor covers this criterion — evaluate it by hand on the scanned pages.'], question: `Is ${c.id} met on every scanned page and state?` },
      pl: { title: `${c.id} ${c.title || ''}`.trim(), steps: ['Żadne automatyczne sprawdzenie nie obejmuje tego kryterium — oceń je ręcznie na skanowanych stronach.'], question: `Czy ${c.id} jest spełnione na każdej skanowanej stronie i w każdym stanie?` },
    });
  }
  for (const q of run.needs_review_queue || []) {
    const sc = (q.sc ? [].concat(q.sc) : []).filter((s) => set.has(s));
    tasks.push({
      id: `review-${q.item_id}`, sc,
      en: { title: `Review ${q.kind} item ${q.item_id}`, steps: ['Open the evidence for this item in the report.', 'Decide whether it is a barrier.'], question: 'Is this item an accessibility barrier?' },
      pl: { title: `Przejrzyj pozycję ${q.kind} ${q.item_id}`, steps: ['Otwórz dowód tej pozycji w raporcie.', 'Zdecyduj, czy to bariera.'], question: 'Czy ta pozycja jest barierą dostępności?' },
    });
  }
  if (!run.llm || !run.model?.phases?.disprove) {
    const kinds = [...new Set((run.semantic_items || []).map((i) => i.kind))];
    for (const kind of kinds) {
      tasks.push({
        id: `judge-${kind}`, sc: [],
        en: { title: `Judge the ${kind} items by hand`, steps: ['The model phase did not run or did not complete; review these items yourself.'], question: `Are the ${kind} items acceptable?` },
        pl: { title: `Oceń ręcznie pozycje ${kind}`, steps: ['Faza modelu nie została uruchomiona lub ukończona; przejrzyj te pozycje samodzielnie.'], question: `Czy pozycje ${kind} są w porządku?` },
      });
    }
  }
  return tasks;
}
