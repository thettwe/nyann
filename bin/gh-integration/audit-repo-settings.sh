  # --- repo-settings audit ---
  # Reuses repo_meta fetched in the security section. When that fetch
  # was unreachable we soft-skip this section too (same root cause).
  # Default-branch expectation is profile.branching.base_branches[0]
  # (always set since the field is required); merge-button + delete-on-
  # merge expectations are tri-state (null = profile silent, no drift).
  repo_settings_skipped_section=""
  if [[ -n "$security_skipped_section" ]]; then
    repo_settings_section=$(jq -n '{
      skipped: true,
      reason: "repo-metadata-unreachable"
    }')
    repo_settings_skipped_section="repo_settings"
  else
    actual_default_branch=$(jq -r '.default_branch // ""' <<<"$repo_meta")
    actual_squash=$(jq -r '.allow_squash_merge // false' <<<"$repo_meta")
    actual_rebase=$(jq -r '.allow_rebase_merge // false' <<<"$repo_meta")
    actual_commit=$(jq -r '.allow_merge_commit // false' <<<"$repo_meta")
    actual_delete=$(jq -r '.delete_branch_on_merge // false' <<<"$repo_meta")

    rs_drift='[]'
    # Default branch — profile always declares it; mismatch is critical
    # (PRs would target the wrong base, branch protection would fall
    # on the wrong branch).
    db_matches=true
    if [[ "$actual_default_branch" != "$default_branch_expected" ]]; then
      db_matches=false
      rs_drift=$(jq --arg e "$default_branch_expected" --arg a "$actual_default_branch" \
        '. + [{field:"default_branch", expected:$e, actual:$a, severity:"critical"}]' <<<"$rs_drift")
      total_drift=$((total_drift + 1))
      total_critical=$((total_critical + 1))
    fi

    # Merge buttons + delete-on-merge: tri-state. Drift only fires
    # when profile expressed an expectation AND it disagrees with
    # actual. Severity is warn — these don't break anything, they're
    # workflow hygiene.
    rs_drift_helper() {
      # $1=field name, $2=expected ("true"|"false"|"null"), $3=actual ("true"|"false")
      local field="$1" exp="$2" act="$3"
      [[ "$exp" == "null" ]] && return 0
      if [[ "$exp" != "$act" ]]; then
        rs_drift=$(jq --arg f "$field" --argjson e "$exp" --argjson a "$act" \
          '. + [{field:$f, expected:$e, actual:$a, severity:"warn"}]' <<<"$rs_drift")
        total_drift=$((total_drift + 1))
        total_warn=$((total_warn + 1))
      fi
    }
    rs_drift_helper allow_squash_merge "$allow_squash_merge_expected" "$actual_squash"
    rs_drift_helper allow_rebase_merge "$allow_rebase_merge_expected" "$actual_rebase"
    rs_drift_helper allow_merge_commit "$allow_merge_commit_expected" "$actual_commit"
    rs_drift_helper delete_branch_on_merge "$delete_branch_on_merge_expected" "$actual_delete"

    # Build the section JSON. expected-fields are tri-state JSON
    # (null when profile silent, true/false when set). The
    # `if X == "null" then null else X|fromjson end` guard keeps the
    # null case representable without an `--argnull` jq flag.
    repo_settings_section=$(jq -n \
      --arg eDB "$default_branch_expected" \
      --arg aDB "$actual_default_branch" \
      --argjson dbMatches "$([[ "$db_matches" == "true" ]] && echo true || echo false)" \
      --arg eSq "$allow_squash_merge_expected" --argjson aSq "$actual_squash" \
      --arg eRb "$allow_rebase_merge_expected" --argjson aRb "$actual_rebase" \
      --arg eMc "$allow_merge_commit_expected" --argjson aMc "$actual_commit" \
      --arg eDl "$delete_branch_on_merge_expected" --argjson aDl "$actual_delete" \
      --argjson drift "$rs_drift" \
      '{
        default_branch:    { expected: $eDB, actual: $aDB, matches: $dbMatches },
        merge_buttons: {
          squash: { expected: (if $eSq == "null" then null else ($eSq | fromjson) end), actual: $aSq },
          rebase: { expected: (if $eRb == "null" then null else ($eRb | fromjson) end), actual: $aRb },
          commit: { expected: (if $eMc == "null" then null else ($eMc | fromjson) end), actual: $aMc }
        },
        delete_branch_on_merge: {
          expected: (if $eDl == "null" then null else ($eDl | fromjson) end),
          actual:   $aDl
        },
        drift: $drift
      }')
  fi

  # Build skipped_sections array: include only sections we soft-skipped.
  skipped_arr=()
  [[ -n "$tag_skipped_section" ]] && skipped_arr+=("$tag_skipped_section")
  [[ -n "$security_skipped_section" ]] && skipped_arr+=("$security_skipped_section")
  [[ -n "$repo_settings_skipped_section" ]] && skipped_arr+=("$repo_settings_skipped_section")
  if [[ ${#skipped_arr[@]} -eq 0 ]]; then
    skipped_sections='[]'
  else
    skipped_sections=$(printf '%s\n' "${skipped_arr[@]}" | jq -R . | jq -sc .)
  fi

  jq -n \
    --arg target "$target" \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --argjson branches "$branches_arr" \
    --argjson tag "$tag_section" \
    --argjson codeowners "$codeowners_section" \
    --argjson security "$security_section" \
    --argjson signing "$signing_section" \
    --argjson repo_settings "$repo_settings_section" \
    --argjson total_drift "$total_drift" \
    --argjson critical "$total_critical" \
    --argjson warn "$total_warn" \
    --argjson skipped "$skipped_sections" \
    '{
      target: $target,
      owner: $owner,
      repo: $repo,
      branches: $branches,
      tag_protection: $tag,
      codeowners_gate: $codeowners,
      security: $security,
      signing: $signing,
      repo_settings: $repo_settings,
      summary: { total_drift: $total_drift, critical: $critical, warn: $warn, skipped_sections: $skipped }
    }'
