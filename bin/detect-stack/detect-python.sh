detect_python() {
  local has_pyproject=false has_setup_py=false has_requirements=false has_pipfile=false
  [[ -f "$path/pyproject.toml" ]] && has_pyproject=true
  [[ -f "$path/setup.py" ]] && has_setup_py=true
  [[ -f "$path/requirements.txt" ]] && has_requirements=true
  [[ -f "$path/Pipfile" ]] && has_pipfile=true

  if ! $has_pyproject && ! $has_setup_py && ! $has_requirements && ! $has_pipfile; then
    return 1
  fi

  signal_manifest=1
  if [[ "$primary_language" == "unknown" ]]; then
    primary_language="python"
    add_reason "Found Python project marker → primary_language = python"
  else
    # JS/TS already claimed primary; note Python as secondary.
    secondary_languages_json="$(jq '. + ["python"]' <<<"$secondary_languages_json")"
    add_reason "Python project marker detected alongside $primary_language → secondary language"
  fi

  # --- Framework detection ---------------------------------------------------
  # Grep-based across pyproject.toml + requirements.txt. Case-insensitive so
  # `FastAPI` / `fastapi` / `fastapi-users` all match. Precedence: django >
  # fastapi > flask.
  local dep_blob=""
  [[ -f "$path/pyproject.toml" ]] && dep_blob+="$(<"$path/pyproject.toml")"$'\n'
  [[ -f "$path/requirements.txt" ]] && dep_blob+="$(<"$path/requirements.txt")"$'\n'
  [[ -f "$path/setup.py" ]] && dep_blob+="$(<"$path/setup.py")"$'\n'
  [[ -f "$path/Pipfile" ]] && dep_blob+="$(<"$path/Pipfile")"$'\n'

  # Framework detection — use word-boundary-ish regex so we don't match
  # substrings like `django-rest-framework` → django (intentional match).
  # Only set framework if JS/TS didn't already claim it.
  if [[ "$framework" == "null" ]]; then
    if grep -Eiq '(^|[[:space:]"=<>~!])django([[:space:]"=<>~!-]|$)' <<<"$dep_blob"; then
      framework='"django"'
      add_reason "Python deps reference django → framework = django"
    elif grep -Eiq '(^|[[:space:]"=<>~!])fastapi([[:space:]"=<>~!-]|$)' <<<"$dep_blob"; then
      framework='"fastapi"'
      add_reason "Python deps reference fastapi → framework = fastapi"
    elif grep -Eiq '(^|[[:space:]"=<>~!])flask([[:space:]"=<>~!-]|$)' <<<"$dep_blob"; then
      framework='"flask"'
      add_reason "Python deps reference flask → framework = flask"
    fi
  fi

  # --- Package manager detection --------------------------------------------
  # Skip if JS/TS already set one; the primary-language path owns package_manager.
  if [[ "$package_manager" != "null" ]]; then
    return 0
  fi

  # Lock-file precedence for Python: uv.lock > poetry.lock > Pipfile.lock > pip.
  # setup.py / requirements.txt without lock → pip. pyproject.toml with
  # [tool.poetry] table but no lock → poetry (project declared).
  if [[ -f "$path/uv.lock" ]]; then
    package_manager='"uv"'
    signal_lock=1
    add_reason "Found uv.lock → package_manager = uv"
  elif [[ -f "$path/poetry.lock" ]]; then
    package_manager='"poetry"'
    signal_lock=1
    add_reason "Found poetry.lock → package_manager = poetry"
  elif [[ -f "$path/Pipfile.lock" ]]; then
    package_manager='"pipenv"'
    signal_lock=1
    add_reason "Found Pipfile.lock → package_manager = pipenv"
  elif $has_pyproject && grep -q '^\[tool\.poetry' "$path/pyproject.toml" 2>/dev/null; then
    package_manager='"poetry"'
    add_reason "pyproject.toml contains [tool.poetry] → package_manager = poetry"
  elif $has_pyproject && grep -q '^\[tool\.uv' "$path/pyproject.toml" 2>/dev/null; then
    package_manager='"uv"'
    add_reason "pyproject.toml contains [tool.uv] → package_manager = uv"
  elif $has_pipfile; then
    package_manager='"pipenv"'
    add_reason "Pipfile present → package_manager = pipenv"
  else
    package_manager='"pip"'
    add_reason "No Python lock file / manager metadata → package_manager = pip"
  fi

  return 0
}

# --- Go detection -------------------------------------------------------------
# Triggered when go.mod or go.sum exists. Framework inferred from imports in
# go.mod: gin-gonic/gin, labstack/echo, gofiber/fiber. Package manager always
# "go". When only loose .go files exist (no go.mod), fall through to the
# extension-count path with low confidence.
