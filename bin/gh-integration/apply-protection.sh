# --- phase 4: per-strategy rule set ------------------------------------------

# Build the protection body as JSON. GitHub's contract requires the full body
# on PUT; partial updates aren't supported.
make_body() {
  local require_reviews="$1" require_checks="$2" strict="${3:-true}" co_required="${4:-false}"
  # require_checks is a CSV of check names; empty means "no status checks"
  # but the contract wants `null` for "no constraint" rather than empty.
  local checks_block
  if [[ -z "$require_checks" ]]; then
    checks_block='null'
  else
    checks_block=$(jq -n --arg checks "$require_checks" --argjson strict "$strict" '
      { strict: $strict, contexts: ($checks | split(",")) }
    ')
  fi
  jq -n --argjson rr "$require_reviews" --argjson checks "$checks_block" \
    --argjson co "$([[ "$co_required" == "true" ]] && echo true || echo false)" '
    {
      required_status_checks: $checks,
      enforce_admins: true,
      required_pull_request_reviews: (if $rr > 0 then {
        required_approving_review_count: $rr,
        dismiss_stale_reviews: true,
        require_code_owner_reviews: $co
      } else null end),
      restrictions: null,
      required_linear_history: false,
      allow_force_pushes: false,
      allow_deletions: false
    }
  '
}
# branches_for_strategy() defined earlier (shared between --check and --apply).

applied_json='[]'
noop_json='[]'
error_json='[]'

while IFS= read -r branch; do
  # Per-strategy body (trunk-based forces status checks "strict").
  case "$strategy" in
    trunk-based) body=$(make_body "$required_reviews" "$required_checks_csv" true  "$require_code_owner_reviews") ;;
    *)           body=$(make_body "$required_reviews" "$required_checks_csv" false "$require_code_owner_reviews") ;;
  esac

  # Read current protection. gh api returns a 404-shaped JSON body when the
  # branch has no protection; jq extraction is best-effort.
  current=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/branches/${branch}/protection" 2>/dev/null || echo '{}')

  # Don't weaken existing protection. Skip PUT when any monotone field
  # is already >= what we'd set, and raise-only when our body is a
  # strict superset.
  current_rr=$(jq -r '
    try .required_pull_request_reviews.required_approving_review_count catch 0
    | tonumber? // 0
  ' <<<"$current" 2>/dev/null || echo 0)
  [[ -z "$current_rr" ]] && current_rr=0

  # Existing required code-owner reviews?
  current_co=$(jq -r '.required_pull_request_reviews.require_code_owner_reviews // false' <<<"$current" 2>/dev/null || echo false)
  # Existing required status-check contexts (list).
  current_ctx_count=$(jq -r '[.required_status_checks.contexts // []] | flatten | length' <<<"$current" 2>/dev/null || echo 0)
  [[ -z "$current_ctx_count" ]] && current_ctx_count=0

  # The profile-derived body is "stricter-or-equal" only when every
  # monotone field is ≥ what's on remote. Downgrades → noop + warn.
  want_ctx_count=0
  if [[ -n "$required_checks_csv" ]]; then
    want_ctx_count=$(awk -F, '{ n = NF; for (i=1;i<=NF;i++) if ($i=="") n--; print n }' <<<"$required_checks_csv")
  fi

  would_downgrade=false
  reasons=()
  if (( current_rr > required_reviews )); then
    would_downgrade=true; reasons+=("reviews: remote=$current_rr > profile=$required_reviews")
  fi
  if [[ "$current_co" == "true" ]]; then
    would_downgrade=true; reasons+=("require_code_owner_reviews: remote=true (profile does not set)")
  fi
  if (( current_ctx_count > want_ctx_count )); then
    would_downgrade=true; reasons+=("required_status_checks.contexts: remote=$current_ctx_count > profile=$want_ctx_count")
  fi

  if $would_downgrade; then
    reason_str=$(printf '%s; ' "${reasons[@]}")
    reason_str="${reason_str%; }"
    noop_json=$(jq --arg b "$branch" --arg reason "$reason_str" --argjson cur "$current_rr" --argjson req "$required_reviews" '
      . + [{branch:$b, reason:"remote-stricter", detail:$reason, current_reviews:$cur, profile_reviews:$req}]
    ' <<<"$noop_json")
    continue
  fi

  # Apply via PUT only when our body is strictly-or-equally protective.
  : > "$apply_err"
  if "$gh_bin" api --method PUT \
      -H "Accept: application/vnd.github+json" \
      "/repos/${owner}/${repo}/branches/${branch}/protection" \
      --input - <<<"$body" >/dev/null 2>"$apply_err"; then
    applied_json=$(jq --arg b "$branch" --arg s "$strategy" '
      . + [{branch:$b, strategy:$s}]
    ' <<<"$applied_json")
  else
    # Cap stderr at 500 bytes so a multi-MB error page from a hostile
    # proxy / GH Enterprise doesn't bloat our output.
    err_msg=$(head -c 500 "$apply_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    error_json=$(jq --arg b "$branch" --arg msg "$err_msg" '
      . + [{branch:$b, error:$msg}]
    ' <<<"$error_json")
  fi
done < <(branches_for_strategy)

jq -n \
  --arg owner "$owner" \
  --arg repo "$repo" \
  --arg strategy "$strategy" \
  --argjson applied "$applied_json" \
  --argjson noop "$noop_json" \
  --argjson errors "$error_json" \
  '{owner:$owner, repo:$repo, strategy:$strategy, applied:$applied, noop:$noop, errors:$errors}'
