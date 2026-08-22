  # --- signing audit ---
  # Reads branch protection's required_signatures.enabled per
  # strategy-declared branch (we already fetched protection above; the
  # `raw` variable is no longer in scope so we re-extract from the
  # branches_arr section by re-querying GitHub here for clarity).
  # Local config check covers commit.gpgsign + tag.gpgsign + presence
  # of user.signingkey. Drift severity:
  #   * profile requires signed commits + remote branch protection
  #     missing required_signatures → critical
  #   * profile requires signed commits + local commit.gpgsign=false
  #     → warn (the user's commits won't be signed, even though
  #     remote enforces it)
  #   * profile requires signed tags + local tag.gpgsign=false → warn
  #     (release.sh will produce unsigned tags despite the contract)
  #   * profile requires either + user.signingkey unset → warn
  #     (user can't actually sign anything)
  signing_branches='[]'
  signing_drift='[]'
  if [[ "$require_signed_commits" == "true" ]]; then
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      proto=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/branches/${b}/protection" 2>/dev/null || echo '{}')
      sig_enabled=$(jq -r '.required_signatures.enabled // false' <<<"$proto" 2>/dev/null || echo false)
      [[ -z "$sig_enabled" ]] && sig_enabled=false
      signing_branches=$(jq --arg n "$b" --argjson e "$sig_enabled" \
        '. + [{name:$n, required_signatures_enabled:$e}]' <<<"$signing_branches")
      if [[ "$sig_enabled" != "true" ]]; then
        signing_drift=$(jq --arg b "$b" \
          '. + [{field:"required_signatures_enabled", expected:true, actual:false, branch:$b, severity:"critical"}]' <<<"$signing_drift")
        total_drift=$((total_drift + 1))
        total_critical=$((total_critical + 1))
      fi
    done < <(branches_for_strategy)
  fi

  # Local config: read commit.gpgsign / tag.gpgsign / user.signingkey
  # from the target repo's git config. Failures (no .git dir, etc.)
  # leave them unset = false.
  commit_gpgsign=$(git -C "$target" config --get commit.gpgsign 2>/dev/null || echo "false")
  tag_gpgsign=$(git -C "$target" config --get tag.gpgsign 2>/dev/null || echo "false")
  user_signingkey=$(git -C "$target" config --get user.signingkey 2>/dev/null || echo "")
  [[ "$commit_gpgsign" == "true" ]] || commit_gpgsign=false
  [[ "$tag_gpgsign" == "true" ]] || tag_gpgsign=false
  [[ -n "$user_signingkey" ]] && user_signingkey_present=true || user_signingkey_present=false

  # Mode awareness (v1.15.0): gpg.format distinguishes ssh signing
  # (needs a signingkey path) from sigstore/gitsign x509 signing, which
  # is KEYLESS — a missing user.signingkey is correct there, not drift.
  # local_mode is what the repo is actually configured for; profile_mode
  # is what security.commit_signing.mode declares (off = no declaration).
  gpg_format=$(git -C "$target" config --get gpg.format 2>/dev/null || echo "")
  x509_program=$(git -C "$target" config --get gpg.x509.program 2>/dev/null || echo "")
  local_mode="gpg"
  [[ "$gpg_format" == "ssh" ]] && local_mode="ssh"
  if [[ "$gpg_format" == "x509" ]]; then
    local_mode="x509"
    [[ "$x509_program" == *gitsign* ]] && local_mode="gitsign"
  fi
  keyless=false
  [[ "$local_mode" == "gitsign" ]] && keyless=true
  # Extracted by the parent BEFORE it deletes tmp_profile (reading the
  # file here would race that deletion and silently read "off").
  profile_mode="${profile_signing_mode:-off}"

  if [[ "$require_signed_commits" == "true" && "$commit_gpgsign" != "true" ]]; then
    signing_drift=$(jq '. + [{field:"local commit.gpgsign", expected:true, actual:false, severity:"warn"}]' <<<"$signing_drift")
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi
  if [[ "$require_signed_tags" == "true" && "$tag_gpgsign" != "true" ]]; then
    signing_drift=$(jq '. + [{field:"local tag.gpgsign", expected:true, actual:false, severity:"warn"}]' <<<"$signing_drift")
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi
  if { [[ "$require_signed_commits" == "true" ]] || [[ "$require_signed_tags" == "true" ]]; } \
     && [[ "$user_signingkey_present" != "true" ]] && [[ "$keyless" != "true" ]]; then
    signing_drift=$(jq '. + [{field:"user.signingkey", expected:"present", actual:"unset", severity:"warn"}]' <<<"$signing_drift")
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi
  # Profile-declared signing mode vs. actual repo configuration. Only
  # meaningful when the profile declares one (off = no expectation); a
  # mismatch is warn-level drift (the fix is bin/setup-signing.sh).
  if [[ "$profile_mode" != "off" && "$profile_mode" != "$local_mode" ]]; then
    signing_drift=$(jq --arg exp "$profile_mode" --arg act "$local_mode" \
      '. + [{field:"security.commit_signing.mode", expected:$exp, actual:$act, severity:"warn"}]' <<<"$signing_drift")
    total_drift=$((total_drift + 1))
    total_warn=$((total_warn + 1))
  fi

  signing_section=$(jq -n \
    --argjson req_commits "$([[ "$require_signed_commits" == "true" ]] && echo true || echo false)" \
    --argjson req_tags "$([[ "$require_signed_tags" == "true" ]] && echo true || echo false)" \
    --argjson branches "$signing_branches" \
    --argjson cs "$commit_gpgsign" \
    --argjson ts "$tag_gpgsign" \
    --argjson sk "$user_signingkey_present" \
    --arg mode "$local_mode" \
    --argjson drift "$signing_drift" \
    '{
      commit_signing_required_in_profile: $req_commits,
      tag_signing_required_in_profile:    $req_tags,
      branches: $branches,
      local_config: {
        commit_gpgsign:          $cs,
        tag_gpgsign:             $ts,
        user_signingkey_present: $sk,
        mode:                    $mode
      },
      drift: $drift
    }')
