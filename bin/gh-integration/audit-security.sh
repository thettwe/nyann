  # --- repo security audit ---
  # Reads four signals from the GitHub API:
  #   * Dependabot alerts via `GET /repos/{o}/{r}/vulnerability-alerts`
  #     (returns 204 enabled / 404 disabled — gh exits 0 on 204 and
  #     non-zero on 404 when called via `--silent --include`).
  #   * Secret scanning via `.security_and_analysis.secret_scanning`
  #     on `GET /repos/{o}/{r}`.
  #   * Push protection via `.security_and_analysis.secret_scanning_push_protection`.
  #   * Code-scanning default setup via
  #     `GET /repos/{o}/{r}/code-scanning/default-setup` → `.state`
  #     (404 when the repo isn't eligible — treated as `not-applicable`).
  # Each signal resolves to enabled / disabled / unknown so consumers
  # can present a tri-state. Drift entries are `warn` severity — these
  # are good-practice gates, not preview-before-mutate invariants.
  security_skipped_section=""
  security_drift='[]'

  # Repo metadata for secret-scanning + push-protection.
  # gh api emits a 404/403 body that looks like {"message":"Not Found",
  # "documentation_url":"..."} — still a JSON object, but missing the
  # repo-shaped fields. Detect by absence of `id` (the canonical signal
  # for a successful repo response) plus the presence of `.message`
  # (the canonical error signal). Also handle the empty-body case.
  repo_meta=$("$gh_bin" api --method GET "/repos/${owner}/${repo}" 2>/dev/null || echo '')
  meta_has_id=$(jq -r '(.id // empty) != ""' <<<"$repo_meta" 2>/dev/null || echo false)
  meta_has_msg=$(jq -r '(.message // empty) != ""' <<<"$repo_meta" 2>/dev/null || echo false)
  if [[ -z "$repo_meta" ]] || \
     [[ "$(jq -r 'type' <<<"$repo_meta" 2>/dev/null || echo "")" != "object" ]] || \
     [[ "$meta_has_id" != "true" && "$meta_has_msg" == "true" ]]; then
    security_section=$(jq -n '{
      skipped: true,
      reason: "repo-metadata-unreachable"
    }')
    security_skipped_section="security"
  else
    secret_scanning_state=$(jq -r '.security_and_analysis.secret_scanning.status // "unknown"' <<<"$repo_meta")
    push_protection_state=$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "unknown"' <<<"$repo_meta")

    # Vulnerability alerts: 204 = enabled, 404 = disabled, anything
    # else (403 missing scope, 5xx, network, rate limit) = unknown.
    # Capture stderr so we can distinguish "endpoint says no" from
    # "couldn't reach endpoint" — the earlier `>/dev/null 2>&1`
    # collapsed every non-2xx into "disabled" which let auth +
    # transport errors masquerade as legitimate-but-disabled state.
    da_err=$(mktemp -t nyann-da.XXXXXX)
    if "$gh_bin" api --silent --method GET "/repos/${owner}/${repo}/vulnerability-alerts" >/dev/null 2>"$da_err"; then
      dependabot_alerts_state="enabled"
    elif grep -qF "Not Found" "$da_err" 2>/dev/null; then
      # Real 404 from gh — vulnerability alerts genuinely off.
      dependabot_alerts_state="disabled"
    else
      dependabot_alerts_state="unknown"
    fi
    rm -f "$da_err"

    # Code scanning default setup: 200 with .state, or 404 → not-applicable.
    cs_raw=$("$gh_bin" api --method GET "/repos/${owner}/${repo}/code-scanning/default-setup" 2>/dev/null || echo '')
    if [[ -z "$cs_raw" ]] || [[ "$(jq -r '.message // empty' <<<"$cs_raw")" == "Not Found" ]] || \
       [[ "$(jq -r 'type' <<<"$cs_raw")" != "object" ]]; then
      code_scanning_state="not-applicable"
    else
      code_scanning_state=$(jq -r '.state // "unknown"' <<<"$cs_raw")
      # Some responses use "configured" / "not-configured" — normalise to
      # the audit-level enum.
      case "$code_scanning_state" in
        configured)     code_scanning_state="enabled" ;;
        not-configured) code_scanning_state="disabled" ;;
      esac
    fi

    # Build drift entries (warn severity; not critical). Only flag
    # the explicit "disabled" state — `unknown` (transport failure,
    # missing scope, transient API issue) is informational; we don't
    # know the real state, so we shouldn't pretend the user has a
    # gap. The schema preserves the tri-state in the report so
    # consumers can still see the unknown count.
    if [[ "$dependabot_alerts_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$dependabot_alerts_state" \
        '. + [{field:"dependabot_alerts", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi
    if [[ "$secret_scanning_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$secret_scanning_state" \
        '. + [{field:"secret_scanning", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi
    if [[ "$push_protection_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$push_protection_state" \
        '. + [{field:"secret_scanning_push_protection", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi
    # Code scanning: not-applicable is a non-finding (private repo on
    # a plan without code scanning). Only flag when explicitly disabled.
    if [[ "$code_scanning_state" == "disabled" ]]; then
      security_drift=$(jq --arg actual "$code_scanning_state" \
        '. + [{field:"code_scanning_default_setup", expected:"enabled", actual:$actual, severity:"warn"}]' <<<"$security_drift")
    fi

    sec_drift_count=$(jq 'length' <<<"$security_drift")
    total_drift=$((total_drift + sec_drift_count))
    total_warn=$((total_warn + sec_drift_count))

    security_section=$(jq -n \
      --arg da "$dependabot_alerts_state" \
      --arg ss "$secret_scanning_state" \
      --arg pp "$push_protection_state" \
      --arg cs "$code_scanning_state" \
      --argjson drift "$security_drift" \
      '{
        dependabot_alerts: $da,
        secret_scanning: $ss,
        secret_scanning_push_protection: $pp,
        code_scanning_default_setup: $cs,
        drift: $drift
      }')
  fi
