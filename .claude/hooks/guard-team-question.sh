#!/usr/bin/env bash
# No-op, kept for its settings entry (.claude/settings.json may not be edited by a ticket).
# It refused an AskUserQuestion with more than one question, because the retired screen sender
# could answer only one question at a time. The ask channel (team-ask-hook.sh) hands the whole
# call to the per-run TeamLead as JSON and returns every answer, so a stage may ask several
# questions in one call. Contract: .agents/reference/team-lead.md §6
exit 0
