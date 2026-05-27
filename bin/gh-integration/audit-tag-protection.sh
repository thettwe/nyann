  # --- tag protection (Rulesets API) ---
  # Audit only when the profile declares an expected pattern. Reads
  # /repos/{o}/{r}/rulesets and finds the first one that targets tags
  # AND whose ref_name include patterns cover the expected pattern.
  # Drift kinds: pattern absent (no matching ruleset), deletion not
  # blocked, force-push not blocked. The legacy `tag_protection` API
  # is deprecated; the Rulesets API is the supported path.
  tag_skipped_section=""
  if [[ -z "$tag_protection_pattern" ]]; then
    tag_section=$(jq -n '{
      skipped: true,
      reason: "tag-protection-not-configured-in-profile"
    }')
    tag_skipped_section="tag_protection"
  else
    rulesets_raw=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/rulesets" 2>/dev/null || echo '[]')
    if [[ "$(jq -r 'type' <<<"$rulesets_raw")" != "array" ]]; then
      # 404 / permission error / list endpoint missing → soft skip.
      tag_section=$(jq -n '{
        skipped: true,
        reason: "rulesets-list-unreachable"
      }')
      tag_skipped_section="tag_protection"
    else
      # The list endpoint returns summaries; we need the per-ruleset
      # detail to see rules[]. Fetch each ruleset that targets tags.
      tag_pattern_glob="$tag_protection_pattern"
      ruleset_id="null"
      ruleset_name=""
      pattern_present=false
      blocks_deletion=false
      blocks_force_push=false
      while IFS= read -r rid; do
        [[ -z "$rid" || "$rid" == "null" ]] && continue
        detail=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/rulesets/${rid}" 2>/dev/null || echo '{}')
        target=$(jq -r '.target // ""' <<<"$detail")
        [[ "$target" != "tag" ]] && continue
        # Check that ref_name.include covers the expected pattern.
        # GitHub stores patterns with `refs/tags/` prefix; profile
        # declares the bare pattern (e.g. `v*`). Match either form.
        match_count=$(jq --arg p "$tag_pattern_glob" '
          (.conditions.ref_name.include // [])
          | map(select(. == ("refs/tags/" + $p) or . == $p or . == "~ALL"))
          | length
        ' <<<"$detail")
        [[ "$match_count" -eq 0 ]] && continue
        # Found a matching tag ruleset.
        pattern_present=true
        ruleset_id=$rid
        ruleset_name=$(jq -r '.name // ""' <<<"$detail")
        # Inspect rules[] for deletion + non_fast_forward (blocks force-push).
        deletion_count=$(jq '[.rules[]? | select(.type == "deletion")] | length' <<<"$detail")
        ff_count=$(jq '[.rules[]? | select(.type == "non_fast_forward")] | length' <<<"$detail")
        [[ "$deletion_count" -gt 0 ]] && blocks_deletion=true
        [[ "$ff_count" -gt 0 ]] && blocks_force_push=true
        # Don't break — the strictest match across rulesets wins. Two
        # rulesets each enabling one of the rules is still effective.
      done < <(jq -r '.[].id // empty' <<<"$rulesets_raw")

      tag_drift='[]'
      if ! $pattern_present; then
        tag_drift=$(jq -n --arg p "$tag_protection_pattern" '[
          {field:"pattern_present", expected:true, actual:false, severity:"critical"}
        ]')
        total_drift=$((total_drift + 1))
        total_critical=$((total_critical + 1))
      else
        if ! $blocks_deletion; then
          tag_drift=$(jq '. + [{field:"blocks_deletion", expected:true, actual:false, severity:"critical"}]' <<<"$tag_drift")
          total_drift=$((total_drift + 1))
          total_critical=$((total_critical + 1))
        fi
        if ! $blocks_force_push; then
          tag_drift=$(jq '. + [{field:"blocks_force_push", expected:true, actual:false, severity:"critical"}]' <<<"$tag_drift")
          total_drift=$((total_drift + 1))
          total_critical=$((total_critical + 1))
        fi
      fi

      tag_section=$(jq -n \
        --argjson pp "$pattern_present" \
        --argjson bd "$blocks_deletion" \
        --argjson bff "$blocks_force_push" \
        --argjson rid "$ruleset_id" \
        --arg name "$ruleset_name" \
        --argjson drift "$tag_drift" \
        '{pattern_present:$pp, blocks_deletion:$bd, blocks_force_push:$bff, ruleset_id:$rid, ruleset_name:$name, drift:$drift}')
    fi
  fi
