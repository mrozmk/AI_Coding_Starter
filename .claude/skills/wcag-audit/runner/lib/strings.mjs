// strings.mjs — UI strings and remediation templates in en and pl. Verdicts and statuses never use a
// conformance word (a unit test scans both tables).
export const STRINGS = {
  en: {
    title: 'WCAG scan report',
    sections: {
      verdict: 'Verdict', scope: 'Scope', legal: 'Legal framing', summary: 'Summary by impact', matrix: 'Criterion matrix',
      barriers: 'Barriers', review: 'Needs-review queue', manual: 'Manual tasks', ledger: 'Coverage ledger', method: 'Method', disclaimer: 'Disclaimer',
    },
    status: {
      fails: 'fails', suspected: 'suspected', 'n/a': 'n/a', 'no automated failure found': 'no automated failure found', 'not tested': 'not tested',
    },
    verdict: {
      'nothing-scanned': 'Nothing was scanned — see the coverage ledger.',
      partial: 'The scan did not complete — partial results only.',
      fails: 'Automated failures were found in the scanned pages/states — see the barriers and the criterion matrix.',
      suspected: 'Only suspected issues were found — each needs a human check before it counts as a failure.',
      positive: 'No automated failure was found in the scanned pages/states for the criteria marked so, within this coverage. This is a scan, not a conformance audit.',
    },
    disclaimer: 'This report prepares a professional accessibility and legal review; it is not a conformance certificate. A scan covers only the given URLs and the states it opened — no sampling, no complete processes.',
    labels: {
      urls: 'URLs', viewports: 'Viewports', date: 'Date', wcag: 'WCAG', level: 'Level', tool: 'Tool and rule versions', engineB: 'Second engine',
      llm: 'Model judgement', on: 'on', off: 'off', retry: 'Desktop user-agent retry', none: 'none', criterion: 'Criterion', status: 'Status',
      ceiling: 'Coverage ceiling', reason: 'Reason', impact: 'Impact', count: 'Count', basis: 'Basis', where: 'Where', fix: 'How to fix',
      evidence: 'Evidence', kind: 'Kind', detail: 'Detail', steps: 'Steps', question: 'Question', last_verified: 'Legal facts last verified',
      unverified: 'unverified — check the source', client: 'Client type', lang_note: 'Remediation text is in English: the site language is not en or pl.',
      model_not_completed: 'model phase not completed', guard_inactive: 'read guard not active — model phases skipped', understanding: 'Understanding',
      partial: 'partial', status_run: 'Run status',
    },
    ledger: {
      'destination-blocked': 'request refused by the destination policy', 'non-get': 'non-GET request aborted', 'interaction-lockdown': 'request caused after load aborted (interaction lockdown)',
      'lazy-content-blocked': 'lazy content not loaded (lockdown after load)', 'websocket-blocked': 'WebSocket blocked', 'webrtc-blocked': 'WebRTC blocked',
      'cross-origin-frame-skipped': 'cross-origin frame not tested (masked in crops)', 'settle-timeout': 'network did not settle within 10 s',
      'page-error': 'page could not be scanned', 'dns-failed': 'host could not be resolved', 'state-cap': 'state limit reached', 'opened-without-network': 'state opened without network',
      'not-opened': 'state not opened', 'banner-not-dismissed': 'cookie banner could not be dismissed', 'pack-cap': 'judge pack item limit reached',
      'frame-owner-unresolved': 'frame owner not resolved — crops withheld', 'axe-error': 'axe failed on this page', 'check-error': 'a check failed',
      'walk-incomplete': 'keyboard walk incomplete', 'state-not-restored': 'state could not be restored for a check', 'retry-desktop-ua': 'retried with a desktop user agent',
      'evidence-cap': 'evidence item limit reached',
    },
    method: 'Engines: axe-core with the cumulative WCAG tag set (and target-size); own Playwright measurements where the engines are silent; optional model judgement that can only add suspected items. Every request goes through a pinned loopback proxy that enforces the destination policy; every request a runner interaction would cause is aborted. Outcomes, basis (● verified, ◐ suspected, ○ human required) and impact are kept apart and never merged into a score.',
  },
  pl: {
    title: 'Raport skanu WCAG',
    sections: {
      verdict: 'Werdykt', scope: 'Zakres', legal: 'Ramy prawne', summary: 'Podsumowanie wg wpływu', matrix: 'Macierz kryteriów',
      barriers: 'Bariery', review: 'Do przeglądu', manual: 'Zadania ręczne', ledger: 'Rejestr pokrycia', method: 'Metoda', disclaimer: 'Zastrzeżenie',
    },
    status: {
      fails: 'błąd', suspected: 'podejrzenie', 'n/a': 'nie dotyczy', 'no automated failure found': 'nie znaleziono błędu automatycznie', 'not tested': 'nie testowano',
    },
    verdict: {
      'nothing-scanned': 'Niczego nie przeskanowano — zobacz rejestr pokrycia.',
      partial: 'Skan nie został ukończony — tylko częściowe wyniki.',
      fails: 'Znaleziono błędy wykryte automatycznie na skanowanych stronach i stanach — zobacz bariery i macierz kryteriów.',
      suspected: 'Znaleziono tylko podejrzenia — każde wymaga sprawdzenia przez człowieka, zanim zostanie uznane za błąd.',
      positive: 'Nie znaleziono błędu automatycznie na skanowanych stronach i stanach dla tak oznaczonych kryteriów, w tym zakresie pokrycia. To skan, a nie audyt.',
    },
    disclaimer: 'Ten raport przygotowuje profesjonalny przegląd dostępności i przegląd prawny; nie jest certyfikatem zgodności. Skan obejmuje tylko podane adresy i otwarte stany — bez próbkowania i bez pełnych procesów.',
    labels: {
      urls: 'Adresy', viewports: 'Widoki', date: 'Data', wcag: 'WCAG', level: 'Poziom', tool: 'Wersje narzędzi i reguł', engineB: 'Drugi silnik',
      llm: 'Ocena modelu', on: 'włączona', off: 'wyłączona', retry: 'Ponowienie z UA desktopu', none: 'brak', criterion: 'Kryterium', status: 'Status',
      ceiling: 'Pułap pokrycia', reason: 'Powód', impact: 'Wpływ', count: 'Liczba', basis: 'Podstawa', where: 'Gdzie', fix: 'Jak naprawić',
      evidence: 'Dowód', kind: 'Rodzaj', detail: 'Szczegóły', steps: 'Kroki', question: 'Pytanie', last_verified: 'Fakty prawne ostatnio sprawdzone',
      unverified: 'niezweryfikowane — sprawdź źródło', client: 'Typ klienta', lang_note: 'Wskazówki naprawy są po angielsku: język strony to nie en ani pl.',
      model_not_completed: 'faza modelu nieukończona', guard_inactive: 'strażnik odczytu nieaktywny — fazy modelu pominięte', understanding: 'Understanding',
      partial: 'częściowy', status_run: 'Status przebiegu',
    },
    ledger: {
      'destination-blocked': 'żądanie odrzucone przez politykę celów', 'non-get': 'żądanie inne niż GET przerwane', 'interaction-lockdown': 'żądanie po załadowaniu przerwane (blokada interakcji)',
      'lazy-content-blocked': 'leniwa treść niezaładowana (blokada po załadowaniu)', 'websocket-blocked': 'WebSocket zablokowany', 'webrtc-blocked': 'WebRTC zablokowane',
      'cross-origin-frame-skipped': 'ramka z innego źródła nietestowana (zamaskowana)', 'settle-timeout': 'sieć nie ustabilizowała się w 10 s',
      'page-error': 'strony nie dało się przeskanować', 'dns-failed': 'nie rozwiązano nazwy hosta', 'state-cap': 'osiągnięto limit stanów', 'opened-without-network': 'stan otwarty bez sieci',
      'not-opened': 'stanu nie otwarto', 'banner-not-dismissed': 'nie zamknięto banera cookie', 'pack-cap': 'osiągnięto limit pozycji paczki',
      'frame-owner-unresolved': 'nie ustalono właściciela ramki — wycinki wstrzymane', 'axe-error': 'axe zawiódł na tej stronie', 'check-error': 'sprawdzenie zawiodło',
      'walk-incomplete': 'przejście klawiaturą nieukończone', 'state-not-restored': 'nie odtworzono stanu dla sprawdzenia', 'retry-desktop-ua': 'ponowiono z UA desktopu',
      'evidence-cap': 'osiągnięto limit dowodów',
    },
    method: 'Silniki: axe-core z kumulatywnym zestawem tagów WCAG (oraz target-size); własne pomiary Playwright tam, gdzie silniki milczą; opcjonalna ocena modelu, która może dodać tylko podejrzenia. Każde żądanie przechodzi przez przypięty lokalny proxy egzekwujący politykę celów; każde żądanie wywołane interakcją skanera jest przerywane. Wynik, podstawa (● zweryfikowane, ◐ podejrzenie, ○ wymaga człowieka) i wpływ są rozdzielone i nigdy nie łączą się w ocenę punktową.',
  },
};

export const REMEDIATION = {
  'keyboard-trap': { en: 'Let Tab, Shift+Tab or Escape move focus out of the component; never cancel Tab without a way out.', pl: 'Pozwól, by Tab, Shift+Tab lub Escape wyprowadzały fokus z komponentu; nie blokuj Tab bez wyjścia.' },
  'keyboard-walk': { en: 'Make every interactive element reachable with Tab (native elements, or tabindex="0" with key handlers).', pl: 'Zapewnij dostęp klawiszem Tab do każdego elementu interaktywnego (natywne elementy albo tabindex="0" z obsługą klawiszy).' },
  'focus-visible': { en: 'Give focused elements a visible indicator (outline or an equivalent style change); never remove the outline without a replacement.', pl: 'Daj elementom z fokusem widoczny wskaźnik (outline lub równoważna zmiana stylu); nie usuwaj outline bez zamiennika.' },
  'focus-obscured': { en: 'Keep the focused element visible: add scroll-padding for sticky headers or move the overlay.', pl: 'Utrzymaj element z fokusem widoczny: dodaj scroll-padding dla przyklejonych nagłówków albo przesuń nakładkę.' },
  'arrow-widgets': { en: 'Implement arrow-key navigation for composite widgets (roving tabindex or aria-activedescendant).', pl: 'Zaimplementuj nawigację strzałkami w widżetach złożonych (roving tabindex lub aria-activedescendant).' },
  'target-spacing': { en: 'Make pointer targets at least 24×24 CSS px, or space them so 24 px circles do not overlap.', pl: 'Daj celom wskaźnika co najmniej 24×24 px CSS albo odstępy, by okręgi 24 px się nie nakładały.' },
  reflow: { en: 'Let content reflow at 320 CSS px: remove fixed widths and overflow:hidden that clip controls.', pl: 'Pozwól treści przepływać przy 320 px CSS: usuń stałe szerokości i overflow:hidden ucinające kontrolki.' },
  'text-resize': { en: 'Use flexible boxes (min-height, no fixed height with overflow:hidden) so text at 200 % is not clipped.', pl: 'Używaj elastycznych pudełek (min-height, bez stałej wysokości z overflow:hidden), by tekst przy 200 % nie był ucinany.' },
  'text-spacing': { en: 'Do not fix the height of text boxes; let them grow when line, letter and word spacing increase.', pl: 'Nie ustalaj wysokości pudełek z tekstem; pozwól im rosnąć przy większych odstępach.' },
  'contrast-render': { en: 'Raise the text contrast against the darkest/lightest part of its background (4.5:1, 3:1 for large text).', pl: 'Zwiększ kontrast tekstu względem najjaśniejszej/najciemniejszej części tła (4.5:1, 3:1 dla dużego tekstu).' },
  'hover-focus': { en: 'Content shown on hover or focus must be dismissible (Escape), hoverable and persistent.', pl: 'Treść pokazywana po najechaniu lub fokusie musi dać się zamknąć (Escape), najechać i trwać.' },
  'skip-link': { en: 'Point the skip link at a focusable target (e.g. <main id="main" tabindex="-1">).', pl: 'Skieruj link pomijania do celu, który może przyjąć fokus (np. <main id="main" tabindex="-1">).' },
  'accessible-auth': { en: 'Allow paste and password managers on credential fields; offer an alternative to cognitive tests.', pl: 'Pozwól na wklejanie i menedżery haseł w polach logowania; zapewnij alternatywę dla testów poznawczych.' },
  dragging: { en: 'Offer a single-pointer alternative (buttons) to every drag operation.', pl: 'Zapewnij alternatywę jednym wskaźnikiem (przyciski) dla każdego przeciągania.' },
  'pause-control': { en: 'Give moving or auto-playing content a pause/stop control.', pl: 'Daj ruchomej lub samoodtwarzającej się treści przycisk pauzy/zatrzymania.' },
  'status-messages': { en: 'Announce form errors and status changes through a live region (role="status" or role="alert").', pl: 'Ogłaszaj błędy formularza i zmiany statusu przez region na żywo (role="status" lub role="alert").' },
  orientation: { en: 'Do not lock or hide content in landscape orientation.', pl: 'Nie blokuj ani nie ukrywaj treści w orientacji poziomej.' },
  'broken-image': { en: 'Fix the image URL (the server answered with an error) before judging its text alternative.', pl: 'Napraw adres obrazu (serwer zwrócił błąd), zanim ocenisz jego tekst alternatywny.' },
};

export function pick(lang) {
  if (STRINGS[lang]) return { lang, s: STRINGS[lang], note: null };
  return { lang: 'en', s: STRINGS.en, note: `unknown language "${String(lang).slice(0, 10)}" — English used` };
}

export function remediation(key, lang, fallback) {
  const r = REMEDIATION[key];
  if (r) return r[lang] ?? r.en;
  return fallback ?? null;
}
