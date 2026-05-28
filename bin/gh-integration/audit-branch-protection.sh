  # --- per-branch protection drift ---
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    expected=$(jq -n \
      --argjson rr "$required_reviews" \
      --arg checks_csv "$required_checks_csv" \
      --argjson co "$([[ "$require_code_owner_reviews" == "true" ]] && echo true || echo false)" \
      '{
        required_reviews: $rr,
        required_checks: ($checks_csv | if . == "" then [] else split(",") end),
        require_code_owner_reviews: $co,
        enforce_admins: true,
        allow_force_pushes: false,
        allow_deletions: false
      }')

    raw=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/branches/${branch}/protection" 2>/dev/null || echo '{}')
    # 404 / missing protection → actual=null; otherwise normalise.
    if [[ -z "$raw" ]] || [[ "$(jq -r 'type' <<<"$raw")" != "object" ]] || \
       [[ "$(jq -r '. | length' <<<"$raw")" == "0" ]] || \
       [[ "$(jq -r '.message // empty' <<<"$raw")" == "Branch not protected" ]]; then
      actual='null'
    else
      actual=$(jq '{
        required_reviews:           (.required_pull_request_reviews.required_approving_review_count // 0),
        required_checks:            (.required_status_checks.contexts // []),
        require_code_owner_reviews: (.required_pull_request_reviews.require_code_owner_reviews // false),
        enforce_admins:             (.enforce_admins.enabled // false),
        allow_force_pushes:         (.allow_force_pushes.enabled // false),
        allow_deletions:            (.allow_deletions.enabled // false)
      }' <<<"$raw")
    fi

    # Build per-field drift array.
    drift='[]'
    if [[ "$actual" == "null" ]]; then
      drift=$(jq -n --argjson e "$expected" '[
        {field: "branch_protection_present", expected: true, actual: false, severity: "critical"}
      ]')
    else
      # Critical: missing review requirement, missing required checks,
      # admins not enforced, force-push allowed, deletions allowed.
      # Warn: review count below profile, status-check set narrower than profile,
      # codeowner gate off when profile says on.
      # jq quirk: `not` is a filter, not a prefix operator. Use
      # `($expr | not)` for negation. The earlier `(not $foo)` form
      # is a syntax error.
      drift=$(jq -n --argjson e "$expected" --argjson a "$actual" '
        [
          (if $a.required_reviews          < $e.required_reviews          then {field:"required_reviews",          expected:$e.required_reviews,          actual:$a.required_reviews,          severity:(if $e.required_reviews>0 and $a.required_reviews==0 then "critical" else "warn" end)} else empty end),
          (if (($e.required_checks - $a.required_checks) | length) > 0    then {field:"required_checks",           expected:$e.required_checks,           actual:$a.required_checks,           severity:"warn"}     else empty end),
          (if $e.require_code_owner_reviews and ($a.require_code_owner_reviews | not) then {field:"require_code_owner_reviews", expected:true, actual:$a.require_code_owner_reviews, severity:"warn"}     else empty end),
          (if $e.enforce_admins      and ($a.enforce_admins | not)        then {field:"enforce_admins",            expected:true,                          actual:$a.enforce_admins,            severity:"critical"} else empty end),
          (if $a.allow_force_pushes  and ($e.allow_force_pushes | not)    then {field:"allow_force_pushes",        expected:false,                         actual:true,                         severity:"critical"} else empty end),
          (if $a.allow_deletions     and ($e.allow_deletions | not)       then {field:"allow_deletions",           expected:false,                         actual:true,                         severity:"critical"} else empty end)
        ]
      ')
    fi
    branch_drift_count=$(jq 'length' <<<"$drift")
    crit=$(jq '[.[] | select(.severity == "critical")] | length' <<<"$drift")
    warn=$(jq '[.[] | select(.severity == "warn")] | length' <<<"$drift")
    total_drift=$((total_drift + branch_drift_count))
    total_critical=$((total_critical + crit))
    total_warn=$((total_warn + warn))

    branches_arr=$(jq --arg name "$branch" --argjson e "$expected" --argjson a "$actual" --argjson d "$drift" \
      '. + [{name:$name, expected:$e, actual:$a, drift:$d}]' <<<"$branches_arr")
  done < <(branches_for_strategy)
