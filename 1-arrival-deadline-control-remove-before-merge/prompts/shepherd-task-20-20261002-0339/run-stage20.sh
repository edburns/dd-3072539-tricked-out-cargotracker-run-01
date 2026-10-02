#!/usr/bin/env bash
set -euo pipefail

REPO='edburns/dd-3072539-tricked-out-cargotracker-run-01'
PARENT_ISSUE=1
LOG_DIRECTORY='/home/edburns/workareas/dd-3072539-tricked-out-cargotracker-run-01-shepherd-control/1-arrival-deadline-control-remove-before-merge/prompts/shepherd-task-20-20261002-0339'
BODY_DIRECTORY="$LOG_DIRECTORY/issue-bodies"
LEDGER="$LOG_DIRECTORY/creation-ledger.json"
RESULT="$LOG_DIRECTORY/stage-20-result.json"
PRE_CHILDREN="$LOG_DIRECTORY/pre-creation-children.json"
FINAL_CHILDREN="$LOG_DIRECTORY/final-children.json"
BODY_VERIFIER='/home/edburns/.copilot/plugins/shepherd-task/scripts/verify-github-issue-body.sh'
CHILD_VERIFIER='/home/edburns/.copilot/plugins/shepherd-task/scripts/verify-stage20-child-links.sh'

atomic_write() {
  local path="$1" content="$2" temporary="${1}.tmp.$$"
  printf '%s\n' "$content" >"$temporary"
  mv "$temporary" "$path"
}

update_ledger_flag() {
  local number="$1" field="$2" value="$3" updated
  updated="$(
    jq \
      --argjson number "$number" \
      --arg field "$field" \
      --argjson value "$value" \
      'map(if .number == $number then .[$field] = $value else . end)' \
      "$LEDGER"
  )" || return 1
  atomic_write "$LEDGER" "$updated"
}

snapshot_children() {
  local destination="$1" raw="${1}.raw.$$" normalized
  gh api "repos/$REPO/issues/$PARENT_ISSUE/sub_issues" --paginate --slurp >"$raw"
  normalized="$(
    jq 'if length == 0 then [] elif all(.[]; type == "array") then add else . end' "$raw"
  )"
  rm "$raw"
  atomic_write "$destination" "$normalized"
}

reconcile_and_fail() {
  local operation="$1" error="$2" children_error='' failed_result
  set +e
  snapshot_children "$FINAL_CHILDREN"
  local snapshot_status=$?
  set -e
  if [[ $snapshot_status -eq 0 ]]; then
    local reconciled
    reconciled="$(
      jq \
        --slurpfile children "$FINAL_CHILDREN" \
        'map(.id as $id | .linked = ([ $children[0][].id ] | index($id) != null))' \
        "$LEDGER"
    )"
    atomic_write "$LEDGER" "$reconciled"
  else
    children_error='; child-state reconciliation query also failed'
  fi
  failed_result="$(
    jq -n \
      --arg operationError "$operation: $error$children_error" \
      '{
        schemaVersion: 1,
        status: "failed",
        ledgerFile: "creation-ledger.json",
        operationError: $operationError
      }'
  )"
  atomic_write "$RESULT" "$failed_result"
  printf 'FAILED OPERATION: %s\nERROR: %s%s\n' "$operation" "$error" "$children_error" >&2
  if [[ "$(jq 'length' "$LEDGER")" -eq 0 ]]; then
    printf 'No issues were created; no cleanup is required.\n' >&2
  else
    jq -r '.[] | "issue #\(.number) | \(.title) | \(.url) | \(.bodyFile) | body_verified=\(.body_verified) | linked=\(.linked)"' "$LEDGER" >&2
    jq -r --arg repo "$REPO" '.[] | "gh issue delete \(.number) --repo \"\($repo)\" --yes"' "$LEDGER" >&2
    printf 'The operation did not complete and no automatic rollback was performed. Delete every issue in the ledger before invoking stage 20 again.\n' >&2
  fi
  exit 1
}

create_one() {
  local subsection="$1" title="$2" body_name="$3"
  local body_file="$BODY_DIRECTORY/$body_name" created number id url issue_json linked_output=''

  if ! created="$(
    gh api "repos/$REPO/issues" \
      -X POST \
      -f title="$title" \
      -F "body=@$body_file" \
      --jq '{id,number,node_id,html_url,title}'
  )"; then
    reconcile_and_fail "create $subsection" "GitHub issue creation failed"
  fi

  number="$(jq -r '.number' <<<"$created")"
  id="$(jq -r '.id' <<<"$created")"
  url="$(jq -r '.html_url' <<<"$created")"
  local updated
  updated="$(
    jq \
      --arg implementationSubsection "$subsection" \
      --arg bodyFile "issue-bodies/$body_name" \
      --argjson id "$id" \
      --argjson number "$number" \
      --arg title "$title" \
      --arg url "$url" \
      '. + [{
        implementationSubsection: $implementationSubsection,
        bodyFile: $bodyFile,
        id: $id,
        number: $number,
        title: $title,
        url: $url,
        body_verified: false,
        linked: false
      }]' \
      "$LEDGER"
  )"
  atomic_write "$LEDGER" "$updated"

  if ! issue_json="$(
    "$BODY_VERIFIER" \
      "$REPO" \
      "$number" \
      "$body_file" \
      6 \
      5 \
      "$LOG_DIRECTORY/issue-$number-body-verification-failure.json"
  )"; then
    reconcile_and_fail "verify body for issue #$number" "Persisted GitHub issue body did not match $body_name"
  fi
  update_ledger_flag "$number" body_verified true

  local linked=false attempt
  for attempt in 1 2 3; do
    if linked_output="$(
      printf '{"sub_issue_id": %s}' "$id" |
        gh api "repos/$REPO/issues/$PARENT_ISSUE/sub_issues" -X POST --input - 2>&1
    )"; then
      linked=true
      break
    fi
    sleep 2
  done
  if [[ "$linked" != true ]]; then
    reconcile_and_fail "link issue #$number" "$linked_output"
  fi
  update_ledger_flag "$number" linked true
  printf 'Created and linked #%s: %s\n' "$number" "$title"
}

snapshot_children "$PRE_CHILDREN"
atomic_write "$LEDGER" '[]'
atomic_write "$RESULT" '{
  "schemaVersion": 1,
  "status": "in_progress",
  "ledgerFile": "creation-ledger.json",
  "operationError": null
}'

create_one '4.1' '4.1 — Add the application-layer deadline change operation' '01-4.1-body.md'
create_one '4.2' '4.2 — Expose deadline changes through the booking facade' '02-4.2-body.md'
create_one '4.3' '4.3 — Implement the deadline editor backing model' '03-4.3-body.md'
create_one '4.4' '4.4 — Implement the PrimeFaces deadline dialog' '04-4.4-body.md'
create_one '4.5' '4.5 — Integrate deadline editing into the Administration dashboard' '05-4.5-body.md'

if ! snapshot_children "$FINAL_CHILDREN"; then
  reconcile_and_fail 'snapshot final children' 'Unable to query final parent-child state'
fi
if ! verifier_output="$("$CHILD_VERIFIER" "$PRE_CHILDREN" "$FINAL_CHILDREN" "$LEDGER" 2>&1)"; then
  reconcile_and_fail 'verify child links' "$verifier_output"
fi
printf '%s\n' "$verifier_output"

while IFS=$'\t' read -r number body_file; do
  if ! issue_json="$(
    "$BODY_VERIFIER" \
      "$REPO" \
      "$number" \
      "$LOG_DIRECTORY/$body_file" \
      6 \
      5 \
      "$LOG_DIRECTORY/issue-$number-final-body-verification-failure.json"
  )"; then
    reconcile_and_fail "final body verification for issue #$number" 'GitHub issue body no longer matches persisted draft'
  fi
  if ! jq -e '.state == "open" and (.assignees | length == 0)' <<<"$issue_json" >/dev/null; then
    reconcile_and_fail "final issue-state verification for issue #$number" 'Issue is not open and unassigned'
  fi
done < <(jq -r '.[] | [.number, .bodyFile] | @tsv' "$LEDGER")

atomic_write "$RESULT" '{
  "schemaVersion": 1,
  "status": "complete",
  "ledgerFile": "creation-ledger.json",
  "operationError": null
}'

jq -e 'length == 5 and all(.[]; .body_verified == true and .linked == true)' "$LEDGER" >/dev/null
jq -e '.status == "complete" and .operationError == null' "$RESULT" >/dev/null
jq -r '.[] | "#\(.number) \(.title) \(.url)"' "$LEDGER"
