#!/usr/bin/env bash
# The gate deciding which states a push or a pull request plans is a shell script living
# inside a generated workflow, and its failure mode is silent in the worst way: a slug it
# leaves out is a state that goes unplanned, which in a run's job list looks exactly like a
# state with nothing to do. Nothing above this file would notice — `protoconf compile` only
# checks that the script is a string.
#
# So the script under test is the shipped one, read out of the materialized workflow rather
# than copied here, and it runs against a real throwaway repository with real commits.
set -euo pipefail

cd "$(dirname "$0")"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

WORKFLOW=materialized_config/core_test/.github/workflows/terraform.yaml.materialized_JSON

python3 - "$WORKFLOW" > "$work/gate.sh" <<'PY'
import json, re, sys

workflow = json.load(open(sys.argv[1]))["value"]
step = [s for s in workflow["jobs"]["changed_paths"]["steps"] if s["id"] == "diff"][0]

# The quoted ${{ }} expressions are the only thing a runner fills in, and both of them are
# the base commit. Every other line runs here exactly as it ships.
sys.stdout.write(re.sub(r"'\$\{\{[^}]*\}\}'", '"$BASE"', step["run"]))
PY

grep -q '{{' "$work/gate.sh" && {
  echo "changed_paths: the gate script grew a \${{ }} expression this test does not fill in"
  exit 1
}
bash -n "$work/gate.sh"

# Four states, the ones core_test renders. Each gets a file, so each has a directory the
# gate can find a change under.
STATES="us-east-1/api-task/infra us-east-1/api-task/monitoring us-east-1/redis/infra us-east-1/redis/monitoring"
ALL='["us_east_1_api_task_infra","us_east_1_api_task_monitoring","us_east_1_redis_infra","us_east_1_redis_monitoring"]'

repo=$work/repo
git init -q "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
for state in $STATES; do
  mkdir -p "$repo/test/outputs/core_test/$state"
  echo '{}' > "$repo/test/outputs/core_test/$state/main.tf.json"
done
git -C "$repo" add -A
git -C "$repo" commit -qm base
base=$(git -C "$repo" rev-parse HEAD)

# One state edited, on a branch, so the same pair of commits serves both events.
git -C "$repo" checkout -qb change
echo '{"x":1}' > "$repo/test/outputs/core_test/us-east-1/redis/infra/main.tf.json"
git -C "$repo" commit -qam change

gate() { # event base -> the gate's `changed` output
  : > "$work/out"
  (cd "$repo" && GITHUB_EVENT_NAME=$1 BASE=$2 GITHUB_OUTPUT=$work/out RUNNER_TEMP=$work \
    bash "$work/gate.sh")
  sed -n 's/^changed=//p' "$work/out"
}

expect() { # what event base want
  got=$(gate "$2" "$3")
  [ "$got" = "$4" ] || {
    echo "changed_paths: $1: expected $4, got $got"
    exit 1
  }
}

# The whole point: one state's directory changed, so one state is named — not the other three
# that would each have spent a runner saying "No changes."
expect "a push names only the state it touched" push "$base" '["us_east_1_redis_infra"]'
expect "a pull request names only the state it touched" pull_request "$base" '["us_east_1_redis_infra"]'
expect "a push that touched no state names none" push HEAD '[]'

# A base this checkout cannot reach is the one case that must fail open: a gate blind to the
# change must not be the reason a state goes unplanned.
expect "an unreachable base names every state" push 0000000000000000000000000000000000000000 "$ALL"

# A plan job reads the output with `contains(..., '"<slug>"')`, and that match is only sound
# while no slug is a substring of another once quoted.
python3 - "$ALL" <<'PY'
import json, sys
slugs = json.loads(sys.argv[1])
for slug in slugs:
    others = [s for s in slugs if s != slug]
    assert not any('"%s"' % slug in '"%s"' % other for other in others), slug
PY

echo "changed_paths: the path gate names the states a change reaches"
