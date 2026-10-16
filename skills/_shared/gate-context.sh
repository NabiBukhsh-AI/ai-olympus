#!/usr/bin/env bash
# gate-context.sh — relevance-gated context retrieval step before optional knowledge is loaded.
#
# Why this exists
#   Stop paying for project knowledge a task does not need. Runs can pull rules,
#   architecture notes, historical learnings and previous task memory before
#   knowing whether any of it bears on the task. A relevance gate decides that
#   question first, cheaply, and its default answer is NO.
#
#   This is the first piece of the context architecture: the gate produces the
#   verdict that downstream retrievers consume.
#
# Decision inputs (evaluated in strict precedence order):
#   1. task type
#   2. referenced paths
#   3. referenced classes/symbols
#   4. skill metadata
#   5. repository metadata
#   6. changed files
#   7. issue labels
#   8. command arguments
#   9. keywords
#
# Classifier
#   "deterministic"  the inputs decided the verdict on their own.
#   "llm"            a referenced path, a changed file, or a keyword was supplied,
#                    but no deterministic rule maps it to a domain. The signals are
#                    insufficient, so the caller runs one LLM classification. That
#                    classification decides context_required and the sources, and
#                    stays inside the budget this verdict carries.
#   No input at all is not insufficient evidence: it is no evidence, and the
#   verdict is a deterministic NO.
#
# Output (stdout, machine-readable JSON, no prose)
#   {
#     "context_required": false,
#     "classifier": "deterministic",
#     "confidence": 1.0,
#     "domains": [],
#     "sources": {
#       "rules": false,
#       "architecture": false,
#       "learnings": false,
#       "memory": false
#     },
#     "budget": {
#       "max_items": 0,
#       "max_tokens": 0
#     },
#     "reason": [
#       "No evidence of relevance; skipping optional retrieval by default"
#     ]
#   }
#
#   `reason` is for a human reading the verdict. Nothing downstream parses it;
#   every decision a caller takes reads a typed field.
#
# Exit codes
#   0  verdict produced
#   1  usage error / invalid argument
#   2  required dependency missing (jq)
set -euo pipefail

PROG="${0##*/}"
DEFAULT_MAX_ITEMS=5
DEFAULT_MAX_TOKENS=1500

usage() {
  cat >&2 <<'EOF'
Usage: gate-context.sh [options]
       gate-context.sh --self-test

Options:
  --task-type <type>        Task type (e.g. bug, feature, refactor, docs, typo)
  --paths <path,...>        Referenced paths
  --symbols <symbol,...>    Referenced classes or symbols (e.g. OrderController)
  --skill <name>            Skill metadata name
  --repo-metadata <meta>    Repository metadata (e.g. framework=laravel)
  --files <path,...>        Changed files
  --labels <label,...>      Issue labels
  --args <args>             Command arguments
  --keywords <kw,...>       Keywords
  --assignment <path>       Path to assignment file
  --budget-items <n>        Item budget ceiling
  --budget-tokens <n>       Token budget ceiling

Prints a machine-readable JSON verdict on stdout.
EOF
}

safe_display() {
  printf '%s' "$1" | LC_ALL=C tr -cd '[:print:]' | cut -c1-120
}

is_count() {
  [[ "$1" =~ ^[0-9]{1,9}$ ]]
}

# emit_verdict <required> <classifier> <confidence> <rules> <architecture> <learnings> <memory>
#              <max_items> <max_tokens> <domains> <reasons>
# Booleans are `true` / `false`; domains and reasons are newline-separated lists.
# jq builds the JSON, so no input can break the output's syntax.
emit_verdict() {
  jq -n \
    --argjson required "$1" \
    --arg classifier "$2" \
    --argjson confidence "$3" \
    --argjson rules "$4" \
    --argjson architecture "$5" \
    --argjson learnings "$6" \
    --argjson memory "$7" \
    --argjson max_items "$((10#$8))" \
    --argjson max_tokens "$((10#$9))" \
    --arg domains "${10}" \
    --arg reasons "${11}" \
    '{
      context_required: $required,
      classifier: $classifier,
      confidence: $confidence,
      domains: ($domains | split("\n") | map(select(length > 0))
        | reduce .[] as $d ([]; if index([$d]) == null then . + [$d] else . end)),
      sources: { rules: $rules, architecture: $architecture, learnings: $learnings, memory: $memory },
      budget: { max_items: $max_items, max_tokens: $max_tokens },
      reason: ($reasons | split("\n") | map(select(length > 0)))
    }'
}

run_gate() {
  local task_type="" paths="" symbols="" skill="" repo_meta="" files=""
  local labels="" cmd_args="" keywords="" assignment=""
  local budget_items="" budget_tokens=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --task-type | --paths | --path | --symbols | --symbol | --skill | --repo-metadata | \
      --files | --file | --labels | --label | --args | --keywords | --keyword | --assignment | \
      --budget-items | --budget-tokens)
      [[ $# -ge 2 ]] || { usage; return 1; }
      case "$1" in
      --task-type) task_type="$2" ;;
      --paths | --path) paths="$2" ;;
      --symbols | --symbol) symbols="$2" ;;
      --skill) skill="$2" ;;
      --repo-metadata) repo_meta="$2" ;;
      --files | --file) files="$2" ;;
      --labels | --label) labels="$2" ;;
      --args) cmd_args="$2" ;;
      --keywords | --keyword) keywords="$2" ;;
      --assignment) assignment="$2" ;;
      --budget-items | --budget-tokens)
        if ! is_count "$2"; then
          echo "$PROG: $1 must be a non-negative integer" >&2
          return 1
        fi
        if [[ "$1" == "--budget-items" ]]; then budget_items="$2"; else budget_tokens="$2"; fi
        ;;
      esac
      shift 2
      ;;
    *)
      echo "$PROG: unknown argument: $(safe_display "$1")" >&2
      usage
      return 1
      ;;
    esac
  done

  local assignment_content=""
  if [[ -n "$assignment" && -f "$assignment" ]]; then
    assignment_content="$(cat "$assignment")"
  fi

  local context_required=false classifier="deterministic" confidence="1.0"
  local src_rules=false src_architecture=false src_learnings=false src_memory=false
  local domains="" reasons="" nl=$'\n'

  # 1. Task type
  local tt_lower
  tt_lower="$(printf '%s' "$task_type" | tr '[:upper:]' '[:lower:]')"
  case "$tt_lower" in
  docs | documentation | typo | formatting | format | metadata | chore)
    emit_verdict false deterministic 1.0 false false false false 0 0 "" \
      "Task type is $(safe_display "$tt_lower"); skipping optional retrieval"
    return 0
    ;;
  esac

  local lbl_lower
  lbl_lower="$(printf '%s' "$labels" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lbl_lower" =~ ^(docs|documentation)$ && -z "$symbols" && -z "$paths" ]]; then
    emit_verdict false deterministic 1.0 false false false false 0 0 "" \
      "Label indicates documentation-only; skipping optional retrieval"
    return 0
  fi

  # 2. Referenced paths (and 6. changed files, matched by the same path rules)
  local all_paths="${paths},${files}"
  if [[ "$all_paths" =~ (app/|src/|routes/) ]]; then
    context_required=true
    domains+="application${nl}"
    src_rules=true
    src_architecture=true
    reasons+="Referenced application paths: $(safe_display "$all_paths")${nl}"
  fi
  if [[ "$all_paths" =~ (database/|migrations/) ]]; then
    context_required=true
    domains+="database${nl}"
    src_rules=true
    src_learnings=true
    reasons+="Referenced database/migration paths: $(safe_display "$all_paths")${nl}"
  fi
  if [[ "$all_paths" =~ (auth/|security/) ]]; then
    context_required=true
    domains+="security${nl}"
    src_rules=true
    src_learnings=true
    src_memory=true
    reasons+="Referenced security boundary paths: $(safe_display "$all_paths")${nl}"
  fi

  # 3. Referenced classes/symbols
  if [[ -n "$symbols" ]]; then
    context_required=true
    confidence="0.95"
    reasons+="Concrete symbol match: $(safe_display "$symbols")${nl}"

    if [[ "$symbols" =~ (Controller|Action|Model|Policy|Service|Job|Event|Listener|Route) ]]; then
      domains+="laravel${nl}architecture${nl}"
      src_rules=true
      src_architecture=true
      src_learnings=true
    fi

    if [[ "$symbols" =~ (Migration|Schema|Table|Query) ]]; then
      domains+="database${nl}"
      src_rules=true
      src_learnings=true
    fi

    if [[ "$symbols" =~ (Lock|Mutex|Concurrency|Queue|Transaction) ]]; then
      domains+="concurrency${nl}"
      src_rules=true
      src_learnings=true
      src_memory=true
    fi
  fi

  # 4. Skill metadata
  local sk_lower
  sk_lower="$(printf '%s' "$skill" | tr '[:upper:]' '[:lower:]')"
  if [[ "$sk_lower" =~ (security-review|security-audit) ]]; then
    context_required=true
    domains+="security${nl}"
    src_rules=true
    src_learnings=true
    reasons+="Security skill metadata: $(safe_display "$skill")${nl}"
  elif [[ "$sk_lower" =~ (class-refactoring|refactor) ]]; then
    context_required=true
    domains+="architecture${nl}"
    src_architecture=true
    src_rules=true
    reasons+="Refactoring skill metadata: $(safe_display "$skill")${nl}"
  fi

  # 5. Repository metadata only refines a verdict other evidence already established.
  if [[ "$context_required" == true ]]; then
    local rm_lower
    rm_lower="$(printf '%s' "$repo_meta" | tr '[:upper:]' '[:lower:]')"
    if [[ "$rm_lower" =~ laravel ]]; then
      domains+="laravel${nl}"
    fi
  fi

  # 8-9. Command arguments, keywords, and the assignment text
  local combined_text="${keywords} ${cmd_args} ${assignment_content}"
  if [[ "$context_required" == false ]]; then
    if [[ "$combined_text" =~ (vulnerability|CVE-|injection|untrusted|auth|token) ]]; then
      context_required=true
      domains+="security${nl}"
      src_rules=true
      src_learnings=true
      reasons+="Security signals found in keywords/assignment${nl}"
    elif [[ "$combined_text" =~ (migration|schema|query|database|deadlock) ]]; then
      context_required=true
      domains+="database${nl}"
      src_rules=true
      src_learnings=true
      reasons+="Database signals found in keywords/assignment${nl}"
    fi
  fi

  local max_items=0 max_tokens=0
  if [[ "$context_required" == true ]]; then
    max_items="${budget_items:-$DEFAULT_MAX_ITEMS}"
    max_tokens="${budget_tokens:-$DEFAULT_MAX_TOKENS}"
  elif [[ -n "$paths" || -n "$files" || -n "$keywords" ]]; then
    # Evidence exists, but no deterministic rule maps it to a domain.
    classifier="llm"
    confidence="0.5"
    max_items="${budget_items:-$DEFAULT_MAX_ITEMS}"
    max_tokens="${budget_tokens:-$DEFAULT_MAX_TOKENS}"
    reasons+="Deterministic signals insufficient; escalated to LLM classification${nl}"
  else
    reasons+="No evidence of relevance; skipping optional retrieval by default${nl}"
  fi

  emit_verdict "$context_required" "$classifier" "$confidence" \
    "$src_rules" "$src_architecture" "$src_learnings" "$src_memory" \
    "$max_items" "$max_tokens" "$domains" "$reasons"
}

self_test() {
  local failures=0 script tmp
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$PROG"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  expect_field() {
    local label="$1" expected="$2" filter="$3"
    shift 3
    local out actual
    if ! out="$("$script" "$@" 2>&1)"; then
      printf 'FAIL  %-60s script exited non-zero: %s\n' "$label" "$out" >&2
      failures=$((failures + 1))
      return 0
    fi
    actual="$(printf '%s' "$out" | jq -r "$filter")"
    if [[ "$actual" != "$expected" ]]; then
      printf 'FAIL  %-60s expected %s, got %s\n' "$label" "$expected" "$actual" >&2
      failures=$((failures + 1))
      return 0
    fi
    printf 'ok    %-60s %s\n' "$label" "$actual"
  }

  expect_exit() {
    local label="$1" expected="$2"
    shift 2
    local actual
    set +e
    "$script" "$@" >/dev/null 2>&1
    actual=$?
    set -e
    if [[ "$actual" -eq "$expected" ]]; then
      printf 'ok    %-60s exit %s\n' "$label" "$actual"
    else
      printf 'FAIL  %-60s expected exit %s, got %s\n' "$label" "$expected" "$actual" >&2
      failures=$((failures + 1))
    fi
  }

  expect_field 'default outcome skips retrieval with context_required false' \
    'false:deterministic' '"\(.context_required):\(.classifier)"'

  expect_field 'default verdict turns every source off with an empty budget' \
    'false:false:false:false:0:0' \
    '"\(.sources.rules):\(.sources.architecture):\(.sources.learnings):\(.sources.memory):\(.budget.max_items):\(.budget.max_tokens)"'

  expect_field 'ambiguous task without paths, symbols, or labels skips retrieval' \
    'false:deterministic' '"\(.context_required):\(.classifier)"' --task-type bug --skill resolve-issue

  expect_field 'a concrete class in a known domain returns context_required true' \
    'true' '.context_required' --symbols OrderController --task-type bug

  expect_field 'symbol match enables relevant sources and sets domains' \
    'true:true:laravel' '"\(.sources.rules):\(.sources.architecture):\(.domains[0])"' --symbols OrderController --task-type bug

  expect_field 'each knowledge source can be enabled or disabled independently' \
    'true:false:true:false' '"\(.sources.rules):\(.sources.architecture):\(.sources.learnings):\(.sources.memory)"' \
    --symbols DatabaseMigration --task-type bug

  expect_field 'deterministic detection is preferred over LLM' \
    'deterministic' '.classifier' --symbols OrderController --paths lib/unmapped.txt

  expect_field 'insufficient deterministic signals escalate to LLM classification' \
    'llm:false:5:1500' '"\(.classifier):\(.context_required):\(.budget.max_items):\(.budget.max_tokens)"' \
    --paths lib/Billing/rounding.txt --keywords pricing

  expect_field 'budget smaller than available evidence still produces valid verdict' \
    'true:2:500' '"\(.context_required):\(.budget.max_items):\(.budget.max_tokens)"' \
    --symbols OrderControllerQueueMigration --paths app/Http,database/migrations,app/auth/ \
    --budget-items 2 --budget-tokens 500

  expect_field 'domains are reported once each' \
    'laravel,architecture' '.domains | join(",")' --symbols OrderController --repo-metadata framework=laravel

  expect_field 'task type docs or formatting skips retrieval' \
    'false' '.context_required' --task-type docs --symbols ReadmeUpdate

  expect_field 'label documentation skips retrieval' \
    'false' '.context_required' --labels documentation

  printf 'Fix the token refresh in the login flow\n' >"$tmp/assignment.md"
  expect_field 'assignment text is read as a keyword signal' \
    'true:security' '"\(.context_required):\(.domains[0])"' --assignment "$tmp/assignment.md"

  expect_exit 'unknown flag exits with usage error' 1 --unrecognized-flag
  expect_exit 'a non-numeric budget is refused' 1 --budget-items many

  local out
  out="$("$script" --symbols OrderController --paths "$(printf 'app/a"b\tc\\d')")"
  if printf '%s' "$out" | jq -e '.reason | length > 0' >/dev/null 2>&1; then
    printf 'ok    %-60s\n' 'machine-readable JSON output contains no prose'
  else
    printf 'FAIL  %-60s output is not valid JSON\n' 'machine-readable JSON output contains no prose' >&2
    failures=$((failures + 1))
  fi

  if [[ "$failures" -gt 0 ]]; then
    echo "gate-context self-test: $failures failure(s)" >&2
    return 4
  fi
  echo 'gate-context self-test: PASS'
  return 0
}

if ! command -v jq >/dev/null 2>&1; then
  echo "$PROG: required tool not found: jq" >&2
  exit 2
fi

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

run_gate "$@"
