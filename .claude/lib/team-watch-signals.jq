# team-watch signal filter:
#   {now, esc_unsent_secs, snapshot, mail: {<role>: [lines]}, mail_errors: {<role>: text},
#    esc_mail: [lines], esc_mail_error, snapshot_error, routing,
#    roles: {<role>: {sub, fp, anchor, screen}}} → [{key, kind, team, role, head, screen, to}]
# Destinations mirror TW_ROLES (team-watch-route.sh): team signals → TeamLead, the role-level
# ones (silence, role prompts, unrouted mail errors) → Supervisor; single routing → the receiver.
# Each team is evaluated on its own object: one team's state never hides another's signals.
# Keys carry team and run, so identical record names in two teams or runs never collide.

def sig($key; $kind; $team; $role; $head; $screen; $to):
  {key: $key, kind: $kind, team: $team, role: $role, head: $head, screen: ($screen // []),
   to: $to};

def single($R): $R.mode != "split";

# Routing is decided here, when the signal is created, never at delivery.
def dest($R; $kind; $role):
  if single($R) then $R.receiver
  elif $kind == "mail" then $role
  else "TeamLead" end;

def finished($t): $t.finished == true;

def attended($r): ($r.role == "planner" or $r.role == "wrapup")
  and ($r.attention_pending == true or $r.attended_pending == true);

def attention($t; $R):
  $t.roles[]? as $r
  | select($r.live == true and ($r.menu_open == true or $r.prompt_open == true or attended($r)))
  | (if $r.menu_open == true then "menu" elif $r.prompt_open == true then "permission"
     else "question" end) as $sub
  | sig("att:\($t.team):\($t.run):\($r.role):\($r.attempt):\($r.attention_count):\($r.anchor)";
        "attention"; $t.team; $r.role;
        "ATTENTION \($t.team) \($r.role) (\($sub)): \($r.anchor)"; $r.screen;
        dest($R; "attention"; null));

def record($t; $R):
  $t.roles[]? as $r
  | select($r.record_open == true and $r.record != null)
  | sig("rec:\($t.team):\($t.run):\($r.record.file)"; "record"; $t.team; $r.role;
        "RECORD \($t.team) \($r.role): \($r.record.file) \($r.record.verdict)"
        + " — \($r.record.message // "")";
        $r.screen; dest($R; "record"; null));

def runner($t; $R):
  select($t.runner != "up" and (finished($t) | not))
  | ([$t.roles[]?.record | select(. != null)] | sort_by(.written_at // "") | last | .file // "none")
      as $newest
  | sig("run:\($t.team):\($t.run):\($newest)"; "runner"; $t.team; null;
        "RUNNER \($t.team) \(if $t.runner == "stale" then "stale" else "stopped" end)"
        + " (run \($t.run))";
        []; dest($R; "runner"; null));

# A merged/abandoned PR (state free) closes READY: an idle finished team would be reminded forever.
def ready($t; $R):
  select(finished($t) and $t.runner != "up" and $t.state != "free")
  | sig("ready:\($t.team):\($t.run)"; "ready"; $t.team; null;
        "READY \($t.team): PR \($t.pr_id // "?")"
        + (if $t.pr_status then " (" + $t.pr_status + ")" else "" end);
        []; dest($R; "ready"; null));

# An escalation request without `sent:`: at once after a failed send, else past $min seconds. An
# old producer without `.now` still gets the failed ones. The key has no state: a retry of the
# same seq keeps one incident.
def escalation($t; $R; $now; $min):
  $t.esc_unsent[]? as $e
  | ($e.since | try fromdateiso8601 catch null) as $since
  | select($since != null)
  | select($e.state == "failed" or ($now != null and $now - $since >= $min))
  | sig("esc:\($t.team):\($t.run):\($e.q):\($e.seq)"; "escalation"; $t.team; null;
        "ESCALATION \($t.team) \($e.q) seq \($e.seq): "
        + (if $e.state == "failed" then "not sent — \($e.reason)"
           else "started without sent > \(($min / 60) | ceil) min (since \($e.since))" end);
        []; dest($R; "escalation"; null));

def team_signals($R):
  .now as $now | (.esc_unsent_secs // 180) as $min
  | .snapshot.teams[]? as $t
  | select($t.run != null)
  | attention($t; $R), record($t; $R), runner($t; $R), ready($t; $R),
    escalation($t; $R; $now; $min);

def escalations: [.snapshot.teams[]? as $t | $t.escalations[]? | {team: $t.team} + .];

def epoch: try fromdateiso8601 catch null;

# An unread Advisor reply on an esc-* thread that no live team-escalate.sh waiter will consume.
def escreply($R):
  escalations as $E
  | .esc_mail[]? | strings
  | ([capture("#(?<id>[0-9]+)")] | .[0]) as $i | ([capture("thread=(?<t>\\S+)")] | .[0]) as $th
  | select($i != null and $th != null)
  | ([$E[] | select(.thread == $th.t)] | .[0]) as $e
  | if $e == null then
      sig("escreply:\($i.id)"; "escreply"; null; null;
          "ESCALATION \($th.t): Advisor reply #\($i.id) without a current q"; [];
          dest($R; "escreply"; null))
    elif $e.waiter != "live" then
      sig("escreply:\($i.id)"; "escreply"; $e.team; $e.role;
          "ESCALATION \($e.team) \($e.q): Advisor reply #\($i.id)"
          + " without a waiter (\($e.state))"; [];
          dest($R; "escreply"; null))
    else empty end;

# One episode per Advisor silence, from ledger facts only: it opens on a timeout after the last
# recorded Advisor reply and closes only when a new reply moves that point, never on an answer.
def silence($R):
  escalations as $E
  | ([$E[].replies[]? | {s: ., n: epoch} | select(.n != null)] | max_by(.n)) as $last
  | [ $E[] | . as $e
      | [.timeouts[]? | epoch | select(. != null and ($last == null or . > $last.n))] as $ts
      | select($ts | length > 0) | $e + {first: ($ts | min)} ] as $timed
  | select($timed | length > 0)
  | [ $timed[] | select((.state | IN("sent", "consumed", "recorded", "revoked")) | not)
      | select(.last_outcome != "reviewer-fallback") ] as $waiting
  | sig("advisor-silent:\($last.s // "none")"; "silence"; null; null;
        "ADVISOR silent since \([$timed[].first] | min | todateiso8601): "
        + "\($waiting | length) escalation(s) waiting";
        [$waiting[] | "\(.team) \(.q) tier \(.tier) class \(.class)"];
        (if single($R) then $R.receiver else "Supervisor" end));

def esc_mail_error($R):
  .esc_mail_error // empty | strings
  | sig("err:esc_mail"; "error"; null; null; "ERROR esc_mail: \(.)"; []; dest($R; "error"; null));

def surfaced_error:
  test("^(team .*: failed|teams: (failed|invalid output)|[a-z0-9-]+/[a-z]+: failed"
    + "|[a-z0-9-]+: (unreadable session.json|bad mode in team.json|events failed)|tmux: .*)$");

# Single routing: one mail probe (mail_unread), so one key and head without the role.
def mail_error($R):
  (.mail_errors // {}) | to_entries[]
  | if single($R) then sig("err:mail"; "error"; null; null; "ERROR mail: \(.value)"; [];
                          $R.receiver)
    else sig("err:mail:\(.key)"; "error"; null; null; "ERROR mail \(.key): \(.value)"; [];
             (if $R.live[.key] == true then .key else "Supervisor" end)) end;

def error_signals($R):
  (select(.snapshot_error != null)
   | sig("err:snapshot"; "error"; null; null; "ERROR snapshot: \(.snapshot_error)"; [];
         dest($R; "error"; null))),
  mail_error($R),
  (select(.snapshot_error == null) | .snapshot.errors[]? | strings | select(surfaced_error)
   | sig("err:" + .; "error"; null; null; "ERROR " + .; []; dest($R; "error"; null)));

def mail_signals($R):
  (.mail // {}) | to_entries[] | .key as $r | .value[]? | strings | select(length > 0)
  | if single($R) then sig("mail:" + .; "mail"; null; null; "MAIL " + .; []; $R.receiver)
    else sig("mail:\($r):" + .; "mail"; null; null; "MAIL \($r) " + .; []; dest($R; "mail"; $r))
    end;

# A role session's own prompt or menu: the Supervisor decides (tier 1 via the session launcher's
# answer); single routing keeps it with the receiver unless the receiver is the one asking.
def role_signals($R):
  (.roles // {}) | to_entries[] | .key as $r | .value as $p
  | sig("ratt:\($r):\($p.sub):\($p.fp)"; "role-attention"; null; $r;
        "ATTENTION \($r) (\($p.sub)) fp=\($p.fp): \($p.anchor)"; $p.screen;
        (if single($R) and $R.receiver != $r then $R.receiver else "Supervisor" end));

(.routing // {mode: "single", receiver: "Supervisor", live: {}}) as $R
| [ (if .snapshot_error == null then team_signals($R), escreply($R), silence($R) else empty end),
    mail_signals($R), error_signals($R), esc_mail_error($R), role_signals($R) ]
