  # --- CODEOWNERS gate ---
  if codeowners_path >/dev/null; then file_present=true; else file_present=false; fi
  branches_with_gate=$(jq -r '[.[] | select(.actual != null and .actual.require_code_owner_reviews) | .name]' <<<"$branches_arr")
  co_drift='[]'
  if $file_present && [[ "$require_code_owner_reviews" != "true" ]]; then
    # CODEOWNERS exists but profile doesn't require it — informational.
    co_drift=$(jq -n '[{kind:"file-present-but-not-required-by-profile", branch:"*", severity:"warn"}]')
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi
  if ! $file_present && [[ "$require_code_owner_reviews" == "true" ]]; then
    # Profile requires the gate but the file is missing — high-impact.
    co_drift=$(jq -n '[{kind:"file-missing-but-required", branch:"*", severity:"critical"}]')
    total_drift=$((total_drift + 1))
    total_critical=$((total_critical + 1))
  fi
  if $file_present && [[ "$require_code_owner_reviews" == "true" ]]; then
    # File exists, profile requires gate — drift if any branch has the gate off.
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      gate_on=$(jq --arg n "$b" '[.[] | select(.name == $n and .actual != null and .actual.require_code_owner_reviews)] | length > 0' <<<"$branches_arr")
      if [[ "$gate_on" == "false" ]]; then
        co_drift=$(jq --arg b "$b" '. + [{kind:"file-present-but-gate-off", branch:$b, severity:"warn"}]' <<<"$co_drift")
        total_drift=$((total_drift + 1))
        total_warn=$((total_warn + 1))
      fi
    done < <(branches_for_strategy)
  fi

  codeowners_section=$(jq -n \
    --argjson fp "$file_present" \
    --argjson req "$([[ "$require_code_owner_reviews" == "true" ]] && echo true || echo false)" \
    --argjson bwg "$branches_with_gate" \
    --argjson drift "$co_drift" \
    '{file_present:$fp, gate_required_in_profile:$req, branches_with_gate:$bwg, drift:$drift}')
