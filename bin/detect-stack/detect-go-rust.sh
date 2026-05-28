detect_go() {
  local has_gomod=false
  [[ -f "$path/go.mod" ]] && has_gomod=true
  [[ -f "$path/go.sum" ]] && has_gomod=true

  if ! $has_gomod; then
    return 1
  fi

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="go"
    add_reason "Found go.mod → primary_language = go"
  else
    secondary_languages_json="$(jq '. + ["go"]' <<<"$secondary_languages_json")"
    add_reason "go.mod detected alongside $primary_language → secondary language"
  fi

  # Framework from go.mod require blocks.
  local modfile="$path/go.mod"
  if [[ -f "$modfile" && "$framework" == "null" ]]; then
    if grep -Eq 'github\.com/gin-gonic/gin' "$modfile"; then
      framework='"gin"'
      add_reason "go.mod references gin-gonic/gin → framework = gin"
    elif grep -Eq 'github\.com/labstack/echo' "$modfile"; then
      framework='"echo"'
      add_reason "go.mod references labstack/echo → framework = echo"
    fi
  fi

  # Package manager: always go (its own module system). Only claim when
  # nothing else has.
  if [[ "$package_manager" == "null" ]]; then
    package_manager='"go"'
    signal_lock=1  # go.sum is effectively our lock
    add_reason "Go project → package_manager = go"
  fi

  return 0
}

# --- Rust detection -----------------------------------------------------------
# Triggered when Cargo.toml exists. Framework via dep name. Workspace flag
# from [workspace] members.

detect_rust() {
  local cargo="$path/Cargo.toml"
  [[ -f "$cargo" ]] || return 1

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="rust"
    add_reason "Found Cargo.toml → primary_language = rust"
  else
    secondary_languages_json="$(jq '. + ["rust"]' <<<"$secondary_languages_json")"
    add_reason "Cargo.toml detected alongside $primary_language → secondary language"
  fi

  # Workspace: Cargo supports its own workspace concept. If present, flag
  # is_monorepo even though no JS/TS-style monorepo tool was detected.
  if grep -Eq '^\[workspace\]' "$cargo"; then
    is_monorepo=true
    monorepo_tool='"cargo-workspace"'
    add_reason "Cargo.toml contains [workspace] → is_monorepo = true"
  fi

  # Framework from dependencies.
  if [[ "$framework" == "null" ]]; then
    if grep -Eq '^actix-web\s*=' "$cargo" || grep -Eq '^actix\s*=' "$cargo"; then
      framework='"actix"'
      add_reason "Cargo.toml references actix → framework = actix"
    elif grep -Eq '^axum\s*=' "$cargo"; then
      framework='"axum"'
      add_reason "Cargo.toml references axum → framework = axum"
    elif grep -Eq '^rocket\s*=' "$cargo"; then
      framework='"rocket"'
      add_reason "Cargo.toml references rocket → framework = rocket"
    fi
  fi

  if [[ "$package_manager" == "null" ]]; then
    package_manager='"cargo"'
    [[ -f "$path/Cargo.lock" ]] && signal_lock=1
    add_reason "Rust project → package_manager = cargo"
  fi

  return 0
}
