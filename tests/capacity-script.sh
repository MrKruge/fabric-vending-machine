#!/usr/bin/env bash
# Offline test of scripts/capacity.sh with a fake `az`: no Azure access, no sleeping.
# The fake keeps its state in a file; a `resume` POST flips it to Active after a few reads.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/az" <<'FAKE'
#!/usr/bin/env bash
state_file="$FAKE_STATE_FILE"; log="$FAKE_LOG"
echo "az $*" >> "$log"
method=""; url=""
while [ $# -gt 0 ]; do case "$1" in --method) method="$2"; shift 2 ;; --url) url="$2"; shift 2 ;; *) shift ;; esac; done
case "$method:$url" in
  get:*)  s="$(cat "$state_file")"; [ "$s" = "missing" ] && exit 1
          # Pausing settles to Paused after two reads; Resuming becomes Active after two reads.
          n=$(( $(cat "$state_file.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$state_file.n"
          if [ "$s" = "Pausing" ] && [ "$n" -ge 3 ]; then echo Paused > "$state_file"; fi
          if [ "$s" = "Resuming" ] && [ "$n" -ge 3 ]; then echo Active > "$state_file"; fi
          echo "$s" ;;
  post:*/resume*)  echo Resuming > "$state_file"; echo 0 > "$state_file.n" ;;
  post:*/suspend*) echo Pausing > "$state_file"; echo 0 > "$state_file.n" ;;
esac
FAKE
chmod +x "$work/bin/az"

# A throwaway environment file, so the test never depends on (or leaks) real tenant values.
mkdir -p "$work/env"
cat > "$work/env/testenv.tfvars" <<'TFVARS'
capacity_name            = "testcapacity"
capacity_resource_group  = "rg-test"
capacity_subscription_id = "00000000-0000-0000-0000-000000000000"
TFVARS
{ cat "$work/env/testenv.tfvars"; echo 'capacity_keep_running = true # event'; } > "$work/env/keepenv.tfvars"
export CAPACITY_ENV_DIR="$work/env"

export PATH="$work/bin:$PATH" CAPACITY_SETTLE_SLEEP=0 CAPACITY_ACTIVE_SLEEP=0
export FAKE_STATE_FILE="$work/state" FAKE_LOG="$work/log"
fail=0
check() { # name expected-exit expected-final-state initial-state action
  local name="$1" want_rc="$2" want_state="$3" init="$4" action="$5" envname="${6:-testenv}"
  echo "$init" > "$FAKE_STATE_FILE"; echo 0 > "$FAKE_STATE_FILE.n"; : > "$FAKE_LOG"
  bash "$root/scripts/capacity.sh" "$envname" "$action" > "$work/out" 2>&1; rc=$?
  final="$(cat "$FAKE_STATE_FILE")"
  if [ "$rc" = "$want_rc" ] && [ "$final" = "$want_state" ]; then echo "ok   $name"
  else echo "FAIL $name: rc=$rc (want $want_rc) final=$final (want $want_state)"; sed 's/^/     /' "$work/out"; fail=1; fi
}

check "resume a paused capacity"                 0 Active  Paused   resume
check "resume waits for a pause in progress"     0 Active  Pausing  resume
check "resume leaves an active capacity alone"   0 Active  Active   resume
check "suspend an active capacity"               0 Pausing Active   suspend
check "suspend leaves a paused capacity alone"   0 Paused  Paused   suspend
check "missing capacity is skipped"              0 missing missing  resume
check "keep_running: suspend is skipped"         0 Active  Active   suspend keepenv
check "keep_running: resume still works"         0 Active  Paused   resume  keepenv

bash "$root/scripts/capacity.sh" testenv explode >/dev/null 2>&1; [ $? = 2 ] && echo "ok   rejects an unknown action" || { echo "FAIL rejects an unknown action"; fail=1; }
bash "$root/scripts/capacity.sh" nosuchenv resume >/dev/null 2>&1; [ $? = 2 ] && echo "ok   rejects an unknown environment" || { echo "FAIL rejects an unknown environment"; fail=1; }
exit $fail
