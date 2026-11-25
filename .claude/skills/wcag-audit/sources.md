# /wcag-audit — legal sources

Every fact in `legal.json` has one row here: its primary source, what it supports, and when it was
last verified. A fact with `"verified": false` is printed in the report as "unverified — check the
source"; flip it only after reading the official text.

| Fact id | Source | Supports | Verified |
|---|---|---|---|
| `wcag22-rec` | https://www.w3.org/WAI/standards-guidelines/wcag/ · https://www.iso.org/standard/91029.html | WCAG 2.2 Rec 2023-10-05, updated 2024-12-12; ISO/IEC 40500:2025; WCAG 3.0 WD | 2026-11-25 |
| `en301549-v411` | https://www.etsi.org/deliver/etsi_en/301500_301599/301549/04.01.01_60/en_301549v040101p.pdf | V4.1.1 adoption, announcement, normative WCAG 2.2 reference, Annex ZA/ZB; no OJ citation found | 2026-11-25 |
| `en301549-beyond-wcag` | same ETSI PDF | clauses 4, 5.2–5.4, 6, 7, 9.7, 11, 12, 13 | 2026-11-25 |
| `en301549-v321-wad` | https://eur-lex.europa.eu/eli/dec_impl/2021/1339/oj | V3.2.1 under the Web Accessibility Directive | 2026-11-25 |
| `eaa-application` | https://eur-lex.europa.eu/eli/dir/2019/882/oj | application date 2025-06-28 (mirrored by Dz.U. 2024 poz. 731) | 2026-11-25 |
| `eaa-microenterprise` | https://eur-lex.europa.eu/eli/dir/2019/882/oj | Art. 4(5) services-only exemption (mirrored by Dz.U. 2024 poz. 731 Art. 4 pkt 1) | 2026-11-25 |
| `eaa-art3-microenterprise` | https://eur-lex.europa.eu/eli/dir/2019/882/oj | Art. 3 microenterprise definition wording | not verified — EUR-Lex not fetched |
| `eaa-annex-i-services` | https://eur-lex.europa.eu/eli/dir/2019/882/oj | Annex I service items | not verified — EUR-Lex not fetched |
| `eaa-art15` | https://eur-lex.europa.eu/eli/dir/2019/882/oj | Art. 15 presumption of conformity | 2026-11-25 |
| `pl-731-scope` | https://api.sejm.gov.pl/eli/acts/DU/2024/731/text.html | transposition act, in force 2025-06-28 | 2026-11-25 |
| `pl-731-authorities` | same | Art. 38(3), Art. 39, e-commerce authority | 2026-11-25 |
| `pl-731-fines` | same | Art. 73 | 2026-11-25 |
| `pl-731-terms` | same | Art. 32 ust. 2 pkt 1 | 2026-11-25 |
| `pl-731-microentrepreneurs` | same | Art. 4 pkt 1 | 2026-11-25 |
| `pl-1440-scope` | https://api.sejm.gov.pl/eli/acts/DU/2023/1440/text.html | Art. 5 ust. 3, clauses 9–11 | 2026-11-25 |
| `pl-1440-declaration` | same | Art. 10, Art. 11 (31 March review) | 2026-11-25 |
| `pl-1440-request` | same | Art. 18 | 2026-11-25 |
| `pl-1440-fines` | same | Art. 19 | 2026-11-25 |

## Change log

- 2026-11-25 — initial verification (planning, #309). EUR-Lex could not be fetched from the planning
  session; the EAA Art. 3 wording and the Annex I service items stay `verified: false`.
