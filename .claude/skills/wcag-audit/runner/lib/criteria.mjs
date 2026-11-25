// criteria.mjs — WCAG 2.2 / 2.1 A and AA success criteria as data. `since` is the WCAG minor version
// that introduced a criterion; 4.1.1 Parsing was removed in 2.2.
const TABLE = `
1.1.1|A|20|non-text-content|Non-text Content
1.2.1|A|20|audio-only-and-video-only-prerecorded|Audio-only and Video-only (Prerecorded)
1.2.2|A|20|captions-prerecorded|Captions (Prerecorded)
1.2.3|A|20|audio-description-or-media-alternative-prerecorded|Audio Description or Media Alternative (Prerecorded)
1.2.4|AA|20|captions-live|Captions (Live)
1.2.5|AA|20|audio-description-prerecorded|Audio Description (Prerecorded)
1.3.1|A|20|info-and-relationships|Info and Relationships
1.3.2|A|20|meaningful-sequence|Meaningful Sequence
1.3.3|A|20|sensory-characteristics|Sensory Characteristics
1.3.4|AA|21|orientation|Orientation
1.3.5|AA|21|identify-input-purpose|Identify Input Purpose
1.4.1|A|20|use-of-color|Use of Color
1.4.2|A|20|audio-control|Audio Control
1.4.3|AA|20|contrast-minimum|Contrast (Minimum)
1.4.4|AA|20|resize-text|Resize Text
1.4.5|AA|20|images-of-text|Images of Text
1.4.10|AA|21|reflow|Reflow
1.4.11|AA|21|non-text-contrast|Non-text Contrast
1.4.12|AA|21|text-spacing|Text Spacing
1.4.13|AA|21|content-on-hover-or-focus|Content on Hover or Focus
2.1.1|A|20|keyboard|Keyboard
2.1.2|A|20|no-keyboard-trap|No Keyboard Trap
2.1.4|A|21|character-key-shortcuts|Character Key Shortcuts
2.2.1|A|20|timing-adjustable|Timing Adjustable
2.2.2|A|20|pause-stop-hide|Pause, Stop, Hide
2.3.1|A|20|three-flashes-or-below-threshold|Three Flashes or Below Threshold
2.4.1|A|20|bypass-blocks|Bypass Blocks
2.4.2|A|20|page-titled|Page Titled
2.4.3|A|20|focus-order|Focus Order
2.4.4|A|20|link-purpose-in-context|Link Purpose (In Context)
2.4.5|AA|20|multiple-ways|Multiple Ways
2.4.6|AA|20|headings-and-labels|Headings and Labels
2.4.7|AA|20|focus-visible|Focus Visible
2.4.11|AA|22|focus-not-obscured-minimum|Focus Not Obscured (Minimum)
2.5.1|A|21|pointer-gestures|Pointer Gestures
2.5.2|A|21|pointer-cancellation|Pointer Cancellation
2.5.3|A|21|label-in-name|Label in Name
2.5.4|A|21|motion-actuation|Motion Actuation
2.5.7|AA|22|dragging-movements|Dragging Movements
2.5.8|AA|22|target-size-minimum|Target Size (Minimum)
3.1.1|A|20|language-of-page|Language of Page
3.1.2|AA|20|language-of-parts|Language of Parts
3.2.1|A|20|on-focus|On Focus
3.2.2|A|20|on-input|On Input
3.2.3|AA|20|consistent-navigation|Consistent Navigation
3.2.4|AA|20|consistent-identification|Consistent Identification
3.2.6|A|22|consistent-help|Consistent Help
3.3.1|A|20|error-identification|Error Identification
3.3.2|A|20|labels-or-instructions|Labels or Instructions
3.3.3|AA|20|error-suggestion|Error Suggestion
3.3.4|AA|20|error-prevention-legal-financial-data|Error Prevention (Legal, Financial, Data)
3.3.7|A|22|redundant-entry|Redundant Entry
3.3.8|AA|22|accessible-authentication-minimum|Accessible Authentication (Minimum)
4.1.1|A|20|parsing|Parsing
4.1.2|A|20|name-role-value|Name, Role, Value
4.1.3|AA|21|status-messages|Status Messages
`;

export const CRITERIA = TABLE.trim().split('\n').map((line) => {
  const [id, level, since, slug, title] = line.split('|');
  return { id, level, since: Number(since), slug, title, removedIn: id === '4.1.1' ? 22 : null };
});

// The one criteria set every source is filtered through for a run.
export function criteriaFor({ wcag = '2.2', level = 'AA' } = {}) {
  const ver = wcag === '2.1' ? 21 : 22;
  return CRITERIA.filter((c) => c.since <= ver && (c.removedIn === null || c.removedIn > ver) && (level === 'AA' || c.level === 'A'));
}

export function criterionById(id) {
  return CRITERIA.find((c) => c.id === id) ?? null;
}

export function understandingUrl(slug) {
  return `https://www.w3.org/WAI/WCAG22/Understanding/${slug}.html`;
}

// 'wcag258' → '2.5.8', 'wcag1410' → '1.4.10'; anything else (wcag2aa, wcag21a, best-practice) → null.
export function scFromAxeTag(tag) {
  const m = /^wcag(\d)(\d)(\d{1,2})$/.exec(tag);
  if (!m) return null;
  const id = `${m[1]}.${m[2]}.${m[3]}`;
  return criterionById(id) ? id : null;
}

export function axeTags({ wcag = '2.2', level = 'AA' } = {}) {
  if (level === 'A') return ['wcag2a', 'wcag21a'];
  return wcag === '2.1' ? ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] : ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'];
}

// The effective axe rule set of a profile: tagged for it, mapped to an SC of the run's set, not
// experimental or deprecated, and enabled by default (target-size is enabled explicitly for 2.2 AA).
// The same list is passed to axe as runOnly, so planned units equal configured rules.
export function axeRuleIds(axe, { wcag = '2.2', level = 'AA' } = {}) {
  const set = new Set(criteriaFor({ wcag, level }).map((c) => c.id));
  const enabled = new Map((axe._audit?.rules ?? []).map((r) => [r.id, r.enabled !== false]));
  return axe.getRules(axeTags({ wcag, level }))
    .filter((r) => !r.tags.includes('experimental') && !r.tags.includes('deprecated'))
    .filter((r) => enabled.get(r.ruleId) !== false || (r.ruleId === 'target-size' && wcag === '2.2' && level === 'AA'))
    .filter((r) => r.tags.map(scFromAxeTag).some((s) => s && set.has(s)))
    .map((r) => r.ruleId)
    .sort();
}

export function axeRuleSc(axe, ruleId, { wcag = '2.2', level = 'AA' } = {}) {
  const set = new Set(criteriaFor({ wcag, level }).map((c) => c.id));
  const rule = axe.getRules().find((r) => r.ruleId === ruleId);
  return rule ? [...new Set(rule.tags.map(scFromAxeTag).filter((s) => s && set.has(s)))] : [];
}

// The 4.1.1 status in a 2.1 run: obsolete per the W3C 2.1 errata.
export const OBSOLETE_411 = 'obsolete — W3C 2.1 errata: always satisfied for HTML/XML';
