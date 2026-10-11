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
# Exit codes
#   0  verdict produced
#   1  usage error / invalid argument
#   2  required dependency missing (jq)
set -euo pipefail

PROG="${0##*/}"

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
  --ambiguous               Signals are ambiguous; forces escalation to LLM

Prints a machine-readable JSON verdict on stdout.
EOF
}

safe_display() {
  printf '%s' "$1" | LC_ALL=C tr -cd '[:print:]' | cut -c1-120
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

json_quote() {
  printf '%s' "$1" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'
}

run_gate() {
  local task_type=""
  local paths=""
  local symbols=""
  local skill=""
  local repo_meta=""
  local files=""
  local labels=""
  local cmd_args=""
  local keywords=""
  local assignment=""
  local budget_items=""
  local budget_tokens=""
  local ambiguous=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --task-type)
      [[ $# -ge 2 ]] || { usage; return 1; }
      task_type="$2"
      shift 2
      ;;
    --paths | --path)
      [[ $# -ge 2 ]] || { usage; return 1; }
      paths="$2"
      shift 2
      ;;
    --symbols | --symbol)
      [[ $# -ge 2 ]] || { usage; return 1; }
      symbols="$2"
      shift 2
      ;;
    --skill)
      [[ $# -ge 2 ]] || { usage; return 1; }
      skill="$2"
      shift 2
      ;;
    --repo-metadata)
      [[ $# -ge 2 ]] || { usage; return 1; }
      repo_meta="$2"
      shift 2
      ;;
    --files | --file)
      [[ $# -ge 2 ]] || { usage; return 1; }
      files="$2"
      shift 2
      ;;
    --labels | --label)
      [[ $# -ge 2 ]] || { usage; return 1; }
      labels="$2"
      shift 2
      ;;
    --args)
      [[ $# -ge 2 ]] || { usage; return 1; }
      cmd_args="$2"
      shift 2
      ;;
    --keywords | --keyword)
      [[ $# -ge 2 ]] || { usage; return 1; }
      keywords="$2"
      shift 2
      ;;
    --assignment)
      [[ $# -ge 2 ]] || { usage; return 1; }
      assignment="$2"
      shift 2
      ;;
    --budget-items)
      [[ $# -ge 2 ]] || { usage; return 1; }
      if ! is_integer "$2"; then
        echo "$PROG: --budget-items must be an integer" >&2
        return 1
      fi
      budget_items="$2"
      shift 2
      ;;
    --budget-tokens)
      [[ $# -ge 2 ]] || { usage; return 1; }
      if ! is_integer "$2"; then
        echo "$PROG: --budget-tokens must be an integer" >&2
        return 1
      fi
      budget_tokens="$2"
      shift 2
      ;;
    --ambiguous | --force-escalate)
      ambiguous=1
      shift
      ;;
    *)
      echo "$PROG: unknown argument: $(safe_display "$1")" >&2
      usage
      return 1
      ;;
    esac
  done

  # Read assignment file if supplied
  local assignment_content=""
  if [[ -n "$assignment" && -f "$assignment" ]]; then
    assignment_content="$(cat "$assignment")"
  fi

  local context_required=0
  local classifier="deterministic"
  local confidence="1.0"
  local -a domains=()
  local src_rules=0
  local src_architecture=0
  local src_learnings=0
  local src_memory=0
  local max_items=0
  local max_tokens=0
  local -a reasons=()

  # Check for explicit ambiguity or insufficient signals
  if [[ "$ambiguous" -eq 1 ]]; then
    classifier="llm"
    confidence="0.5"
    reasons+=("Deterministic signals insufficient; escalated to LLM classification")
    emit_verdict "$context_required" "$classifier" "$confidence" "$src_rules" "$src_architecture" "$src_learnings" "$src_memory" "$max_items" "$max_tokens" domains reasons
    return 0
  fi

  # 1. Precedence 1: Task type
  local tt_lower
  tt_lower="$(printf '%s' "$task_type" | tr '[:upper:]' '[:lower:]')"
  case "$tt_lower" in
  docs | documentation | typo | formatting | format | metadata | chore)
    reasons+=("Task type is $tt_lower; skipping optional retrieval")
    emit_verdict 0 "deterministic" "1.0" 0 0 0 0 0 0 domains reasons
    return 0
    ;;
  esac

  # Check labels for docs/formatting only
  local lbl_lower
  lbl_lower="$(printf '%s' "$labels" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lbl_lower" =~ ^(docs|documentation)$ && -z "$symbols" && -z "$paths" ]]; then
    reasons+=("Label indicates documentation-only; skipping optional retrieval")
    emit_verdict 0 "deterministic" "1.0" 0 0 0 0 0 0 domains reasons
    return 0
  fi

  # 2. Precedence 2: Referenced paths
  local all_paths="${paths},${files}"
  if [[ "$all_paths" =~ (app/|src/|routes/) ]]; then
    context_required=1
    domains+=("application")
    src_rules=1
    src_architecture=1
    reasons+=("Referenced application paths: $paths")
  fi
  if [[ "$all_paths" =~ (database/|migrations/) ]]; then
    context_required=1
    domains+=("database")
    src_rules=1
    src_learnings=1
    reasons+=("Referenced database/migration paths: $paths")
  fi
  if [[ "$all_paths" =~ (auth/|security/) ]]; then
    context_required=1
    domains+=("security")
    src_rules=1
    src_learnings=1
    src_memory=1
    reasons+=("Referenced security boundary paths: $paths")
  fi

  # 3. Precedence 3: Referenced classes/symbols
  if [[ -n "$symbols" ]]; then
    context_required=1
    confidence="0.95"
    reasons+=("Concrete symbol match: $symbols")

    if [[ "$symbols" =~ (Controller|Action|Model|Policy|Service|Job|Event|Listener|Route) ]]; then
      domains+=("laravel")
      domains+=("architecture")
      src_rules=1
      src_architecture=1
      src_learnings=1
    fi

    if [[ "$symbols" =~ (Migration|Schema|Table|Query) ]]; then
      domains+=("database")
      src_rules=1
      src_learnings=1
    fi

    if [[ "$symbols" =~ (Lock|Mutex|Concurrency|Queue|Transaction) ]]; then
      domains+=("concurrency")
      src_rules=1
      src_learnings=1
      src_memory=1
    fi
  fi

  # 4. Precedence 4: Skill metadata
  local sk_lower
  sk_lower="$(printf '%s' "$skill" | tr '[:upper:]' '[:lower:]')"
  if [[ "$sk_lower" =~ (security-review|security-audit) ]]; then
    context_required=1
    domains+=("security")
    src_rules=1
    src_learnings=1
    reasons+=("Security skill metadata: $skill")
  elif [[ "$sk_lower" =~ (class-refactoring|refactor) ]]; then
    context_required=1
    domains+=("architecture")
    src_architecture=1
    src_rules=1
    reasons+=("Refactoring skill metadata: $skill")
  fi

  # 5. Precedence 5: Repository metadata
  if [[ "$context_required" -eq 1 ]]; then
    local rm_lower
    rm_lower="$(printf '%s' "$repo_meta" | tr '[:upper:]' '[:lower:]')"
    if [[ "$rm_lower" =~ laravel ]]; then
      domains+=("laravel")
    fi
  fi

  # 6. Precedence 6-9: Check keywords/assignment for security or database if not yet found
  local combined_text="${keywords} ${cmd_args} ${assignment_content}"
  if [[ "$context_required" -eq 0 && -n "$combined_text" ]]; then
    if [[ "$combined_text" =~ (vulnerability|CVE-|injection|untrusted|auth|token) ]]; then
      context_required=1
      domains+=("security")
      src_rules=1
      src_learnings=1
      reasons+=("Security signals found in keywords/assignment")
    elif [[ "$combined_text" =~ (migration|schema|query|database|deadlock) ]]; then
      context_required=1
      domains+=("database")
      src_rules=1
      src_learnings=1
      reasons+=("Database signals found in keywords/assignment")
    fi
  fi

  # Determine budgets
  if [[ "$context_required" -eq 1 ]]; then
    max_items=5
    max_tokens=1500
    if [[ -n "$budget_items" ]]; then
      max_items="$budget_items"
    fi
    if [[ -n "$budget_tokens" ]]; then
      max_tokens="$budget_tokens"
    fi
  else
    max_items=0
    max_tokens=0
    confidence="1.0"
    reasons+=("No evidence of relevance; skipping optional retrieval by default")
  fi

  # Deduplicate domains
  local -a unique_domains=()
  for d in ${domains[@]+"${domains[@]}"}; do
    local found=0
    for u in ${unique_domains[@]+"${unique_domains[@]}"}; do
      if [[ "$u" == "$d" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" -eq 0 ]]; then
      unique_domains+=("$d")
    fi
  done

  emit_verdict "$context_required" "$classifier" "$confidence" "$src_rules" "$src_architecture" "$src_learnings" "$src_memory" "$max_items" "$max_tokens" unique_domains reasons
  return 0
}

emit_verdict() {
  local req="$1"
  local cls="$2"
  local conf="$3"
  local r_rules="$4"
  local r_arch="$5"
  local r_learn="$6"
  local r_mem="$7"
  local items="$8"
  local tokens="$9"
  local -n dom_ref="${10}"
  local -n rsn_ref="${11}"

  printf '{\n'
  printf '  "context_required": %s,\n' "$([[ "$req" -eq 1 ]] && printf 'true' || printf 'false')"
  printf '  "classifier": "%s",\n' "$cls"
  printf '  "confidence": %s,\n' "$conf"

  printf '  "domains": ['
  local dfirst=1
  for d in ${dom_ref[@]+"${dom_ref[@]}"}; do
    [[ "$dfirst" -eq 1 ]] || printf ', '
    dfirst=0
    printf '"%s"' "$(json_quote "$d")"
  done
  printf '],\n'

  printf '  "sources": {\n'
  printf '    "rules": %s,\n' "$([[ "$r_rules" -eq 1 ]] && printf 'true' || printf 'false')"
  printf '    "architecture": %s,\n' "$([[ "$r_arch" -eq 1 ]] && printf 'true' || printf 'false')"
  printf '    "learnings": %s,\n' "$([[ "$r_learn" -eq 1 ]] && printf 'true' || printf 'false')"
  printf '    "memory": %s\n' "$([[ "$r_mem" -eq 1 ]] && printf 'true' || printf 'false')"
  printf '  },\n'

  printf '  "budget": {\n'
  printf '    "max_items": %d,\n' "$items"
  printf '    "max_tokens": %d\n' "$tokens"
  printf '  },\n'

  printf '  "reason": ['
  local rfirst=1
  for r in ${rsn_ref[@]+"${rsn_ref[@]}"}; do
    [[ "$rfirst" -eq 1 ]] || printf ','
    rfirst=0
    printf '\n    "%s"' "$(json_quote "$r")"
  done
  if [[ "$rfirst" -eq 0 ]]; then
    printf '\n  '
  fi
  printf ']\n'
  printf '}\n'
}

self_test() {
  local failures=0 script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$PROG"

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
    'false' '.context_required'

  expect_field 'default budget is 0 items and 0 tokens' \
    '0:0' '"\(.budget.max_items):\(.budget.max_tokens)"'

  expect_field 'a concrete class in a known domain returns context_required true' \
    'true' '.context_required' --symbols OrderController --task-type bug

  expect_field 'symbol match enables relevant sources and sets domains' \
    'true:true:laravel' '"\(.sources.rules):\(.sources.architecture):\(.domains[0])"' --symbols OrderController --task-type bug

  expect_field 'each knowledge source can be enabled or disabled independently' \
    'true:false:true:false' '"\(.sources.rules):\(.sources.architecture):\(.sources.learnings):\(.sources.memory)"' \
    --symbols DatabaseMigration --task-type bug

  expect_field 'deterministic detection is preferred over LLM' \
    'deterministic' '.classifier' --symbols OrderController

  expect_field 'ambiguous task with insufficient signals escalates to LLM classification' \
    'llm' '.classifier' --ambiguous

  expect_field 'budget smaller than available evidence still produces valid verdict' \
    '2:500' '"\(.budget.max_items):\(.budget.max_tokens)"' \
    --symbols OrderController --budget-items 2 --budget-tokens 500

  expect_field 'task type docs or formatting skips retrieval' \
    'false' '.context_required' --task-type docs --symbols ReadmeUpdate

  expect_field 'label documentation skips retrieval' \
    'false' '.context_required' --labels documentation

  expect_exit 'unknown flag exits with usage error' 1 --unrecognized-flag

  local out
  out="$("$script" --symbols OrderController)"
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
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

if [[ "${1:-}" == "--self-test" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "$PROG: required tool not found: jq" >&2
    exit 2
  fi
  self_test
  exit $?
fi

run_gate "$@"
