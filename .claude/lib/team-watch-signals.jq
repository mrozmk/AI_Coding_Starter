# team-watch signal filter:
#   {snapshot, mail: {<role>: [lines]}, mail_errors: {<role>: text}, snapshot_error, routing,
#    roles: {<role>: {sub, fp, anchor, screen}}} → [{key, kind, team, role, head, screen, to}]
# Destinations mirror TW_ROLES (team-watch-route.sh): every signal → Supervisor, mail to its own
# role in split; single routing → the receiver. Team stops are the per-run TeamLead's and the
# Advisor escalation path is retired: neither produces a signal here.

def sig($key; $kind; $team; $role; $head; $screen; $to):
  {key: $key, kind: $kind, team: $team, role: $role, head: $head, screen: ($screen // []),
   to: $to};

def single($R): $R.mode != "split";

# Routing is decided here, when the signal is created, never at delivery.
def dest($R; $kind; $role):
  if single($R) then $R.receiver
  elif $kind == "mail" then $role
  else "Supervisor" end;

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
| [ mail_signals($R), error_signals($R), role_signals($R) ]
