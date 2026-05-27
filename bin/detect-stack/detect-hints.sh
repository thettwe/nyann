detect_claudemd_hints() {
  local claudemd="$path/CLAUDE.md"
  [[ -f "$claudemd" ]] || return 1

  # Single awk pass replaces 14+ separate grep invocations. Outputs
  # space-separated flags: lang_hit framework_hit detected_lang detected_fw
  local awk_result
  awk_result=$(awk '
    BEGIN { lang=""; fw="" }
    { L = tolower($0) }
    L ~ /python|py3/      { if (!lang) lang="python" }
    L ~ /typescript|tsconfig/ { if (!lang) lang="typescript" }
    L ~ /javascript|node\.?js/ { if (!lang) lang="javascript" }
    L ~ /golang|go [0-9]/ { if (!lang) lang="go" }
    L ~ /rust|cargo/      { if (!lang) lang="rust" }
    L ~ /swift|swiftui|uikit|xcode/ { if (!lang) lang="swift" }
    L ~ /kotlin|android|jetpack|gradle/ { if (!lang) lang="kotlin" }
    L ~ /bash|shellcheck|shell script/ { if (!lang) lang="shell" }
    L ~ /java|spring.boot|maven|gradle/ { if (!lang) lang="java" }
    L ~ /c#|csharp|\.net|aspnet|dotnet/ { if (!lang) lang="csharp" }
    L ~ /php|laravel|symfony|composer/ { if (!lang) lang="php" }
    L ~ /dart|flutter|pubspec/ { if (!lang) lang="dart" }
    L ~ /ruby|rails|sinatra|bundler|gemfile/ { if (!lang) lang="ruby" }
    L ~ /next(\.js)?/   { if (!fw) fw="next" }
    L ~ /fastapi/       { if (!fw) fw="fastapi" }
    L ~ /django/        { if (!fw) fw="django" }
    L ~ /flask/         { if (!fw) fw="flask" }
    L ~ /spring.boot|quarkus|aspnet|blazor|laravel|symfony|flutter|rails|sinatra/ { fwcorr=1 }
    END { printf "%s\t%s\t%d", lang, fw, fwcorr+0 }
  ' "$claudemd")

  local detected_lang detected_fw fw_corroborate
  IFS=$'\t' read -r detected_lang detected_fw fw_corroborate <<<"$awk_result"

  local hit=0

  if [[ "$primary_language" == "unknown" && -n "$detected_lang" ]]; then
    primary_language="$detected_lang"
    hit=1
    case "$detected_lang" in
      python)     add_reason "CLAUDE.md references Python → primary_language = python" ;;
      typescript) add_reason "CLAUDE.md references TypeScript → primary_language = typescript" ;;
      javascript) add_reason "CLAUDE.md references Node/JavaScript → primary_language = javascript" ;;
      go)         add_reason "CLAUDE.md references Go → primary_language = go" ;;
      rust)       add_reason "CLAUDE.md references Rust → primary_language = rust" ;;
      swift)      add_reason "CLAUDE.md references Swift → primary_language = swift" ;;
      kotlin)     add_reason "CLAUDE.md references Kotlin → primary_language = kotlin" ;;
      shell)      add_reason "CLAUDE.md references shell/bash → primary_language = shell" ;;
      java)       add_reason "CLAUDE.md references Java → primary_language = java" ;;
      csharp)     add_reason "CLAUDE.md references C#/.NET → primary_language = csharp" ;;
      php)        add_reason "CLAUDE.md references PHP → primary_language = php" ;;
      dart)       add_reason "CLAUDE.md references Dart/Flutter → primary_language = dart" ;;
      ruby)       add_reason "CLAUDE.md references Ruby → primary_language = ruby" ;;
    esac
  fi

  if [[ "$framework" == "null" && -n "$detected_fw" ]]; then
    framework="\"$detected_fw\""
    hit=1
    case "$detected_fw" in
      next)    add_reason "CLAUDE.md references Next.js → framework = next" ;;
      fastapi) add_reason "CLAUDE.md references FastAPI → framework = fastapi" ;;
      django)  add_reason "CLAUDE.md references Django → framework = django" ;;
      flask)   add_reason "CLAUDE.md references Flask → framework = flask" ;;
    esac
  elif [[ "$framework" != "null" ]] && (( fw_corroborate == 1 )); then
    hit=1
    add_reason "CLAUDE.md framework reference corroborates manifest detection"
  fi

  [[ $hit -eq 1 ]] && signal_claudemd=1
  return 0
}

# --- Documentation hint parser ------------------------------------------------
# When no manifest matched (or to supplement), scan README.md, docs/prd.md,
# docs/PRD.md, docs/tech-stack.md, docs/architecture.md for stack mentions.
# Lower weight than CLAUDE.md (0.2) since these are informational, not
# prescriptive. Critically: this enables detection in repos that only have
# planning/spec documents and no code yet. Detects ALL languages mentioned,
# assigning the first hit as primary (if still unknown) and subsequent ones
# as secondary.

detect_doc_hints() {
  # Skip when an earlier detector already identified the primary language —
  # doc hints are meant for repos that only have planning docs (no code yet).
  # This avoids false positives from docs that reference many languages
  # descriptively (like READMEs for polyglot detection tools).
  [[ "$primary_language" == "unknown" ]] || return 0

  local -a doc_files=()
  for candidate in \
    "$path/README.md" "$path/readme.md" \
    "$path/docs/prd.md" "$path/docs/PRD.md" \
    "$path/docs/tech-stack.md" "$path/docs/TECH-STACK.md" \
    "$path/docs/architecture.md" "$path/docs/ARCHITECTURE.md" \
    "$path/docs/stack.md" "$path/docs/techstack.md" \
    "$path/PRD.md" "$path/TECH_STACK.md"; do
    [[ -f "$candidate" ]] && doc_files+=("$candidate")
  done

  (( ${#doc_files[@]} > 0 )) || return 1

  # Single awk pass over all doc files. Uses tolower() for case-insensitive
  # matching (IGNORECASE is a gawk extension, not available on macOS awk).
  # Outputs tab-separated list of ALL languages and frameworks found.
  local awk_result
  awk_result=$(awk '
    { L=tolower($0) }
    L ~ /python|py3|fastapi|django|flask|pipenv|poetry/ {
      if (!seen["python"]) { langs=langs "python "; seen["python"]=1 }
    }
    L ~ /typescript|tsconfig/ {
      if (!seen["typescript"]) { langs=langs "typescript "; seen["typescript"]=1 }
    }
    L ~ /javascript|nodejs|node\.js/ {
      if (!seen["javascript"]) { langs=langs "javascript "; seen["javascript"]=1 }
    }
    L ~ /golang|go [0-9]\.[0-9]/ {
      if (!seen["go"]) { langs=langs "go "; seen["go"]=1 }
    }
    L ~ /\brust\b|cargo|actix|tokio|wasm-pack/ {
      if (!seen["rust"]) { langs=langs "rust "; seen["rust"]=1 }
    }
    L ~ /\bswift\b|swiftui|uikit|xcode/ {
      if (!seen["swift"]) { langs=langs "swift "; seen["swift"]=1 }
    }
    L ~ /\bkotlin\b|android|jetpack|compose/ {
      if (!seen["kotlin"]) { langs=langs "kotlin "; seen["kotlin"]=1 }
    }
    L ~ /\bbash\b|shellcheck|shell script/ {
      if (!seen["shell"]) { langs=langs "shell "; seen["shell"]=1 }
    }
    L ~ /\bjava\b|spring.boot|maven|quarkus|micronaut/ {
      if (!seen["java"]) { langs=langs "java "; seen["java"]=1 }
    }
    L ~ /c#|csharp|\.net|aspnet|dotnet|blazor/ {
      if (!seen["csharp"]) { langs=langs "csharp "; seen["csharp"]=1 }
    }
    L ~ /\bphp\b|laravel|symfony|composer/ {
      if (!seen["php"]) { langs=langs "php "; seen["php"]=1 }
    }
    L ~ /\bdart\b|flutter|pubspec/ {
      if (!seen["dart"]) { langs=langs "dart "; seen["dart"]=1 }
    }
    L ~ /\bruby\b|rails|sinatra|bundler|gemfile/ {
      if (!seen["ruby"]) { langs=langs "ruby "; seen["ruby"]=1 }
    }
    L ~ /next\.js|next js|nextjs/ { if (!fw) fw="next" }
    L ~ /\bfastapi\b/              { if (!fw) fw="fastapi" }
    L ~ /\bdjango\b/               { if (!fw) fw="django" }
    L ~ /\bflask\b/                { if (!fw) fw="flask" }
    L ~ /\bnuxt\b/                 { if (!fw) fw="nuxt" }
    L ~ /\bremix\b/                { if (!fw) fw="remix" }
    L ~ /sveltekit|svelte.?kit/    { if (!fw) fw="sveltekit" }
    L ~ /\breact\b/                { if (!fw) fw="react" }
    L ~ /\bvue\b/                  { if (!fw) fw="vue" }
    L ~ /\bexpress\b/              { if (!fw) fw="express" }
    L ~ /spring.boot/              { if (!fw) fw="spring-boot" }
    L ~ /\bgin\b/                  { if (!fw) fw="gin" }
    L ~ /\blaravel\b/              { if (!fw) fw="laravel" }
    L ~ /\brails\b/                { if (!fw) fw="rails" }
    L ~ /\bflutter\b/              { if (!fw) fw="flutter" }
    END { printf "%s\t%s", langs, fw }
  ' "${doc_files[@]}")

  local langs_str fw_str
  IFS=$'\t' read -r langs_str fw_str <<<"$awk_result"

  [[ -z "$langs_str" && -z "$fw_str" ]] && return 1

  local hit=0
  local first=true
  for lang in $langs_str; do
    if [[ "$primary_language" == "unknown" && "$first" == "true" ]]; then
      primary_language="$lang"
      hit=1
      first=false
      add_reason "Documentation references $lang → primary_language = $lang"
    elif [[ "$lang" != "$primary_language" ]]; then
      # Only add if not already in secondary_languages
      if ! jq -e --arg l "$lang" 'index($l)' <<<"$secondary_languages_json" >/dev/null 2>&1; then
        secondary_languages_json="$(jq --arg l "$lang" '. + [$l]' <<<"$secondary_languages_json")"
        hit=1
        add_reason "Documentation references $lang → secondary language"
      fi
    fi
  done

  if [[ "$framework" == "null" && -n "$fw_str" ]]; then
    framework="\"$fw_str\""
    hit=1
    add_reason "Documentation references $fw_str → framework = $fw_str"
  fi

  [[ $hit -eq 1 ]] && signal_docs=1
  return 0
}
