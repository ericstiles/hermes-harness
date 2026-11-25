#!/usr/bin/env bash
# lib/model_endpoint.sh — sourced: which model endpoint a Hermes run used, and the command that
# checks it answers. hermes-supervise gates the MODEL_API_ERROR relaunch on it (bead b80).
# bash 3.2 compatible. Reads Hermes' config with `hermes config get`; never writes anything.

HH_OLLAMA_DEFAULT=http://127.0.0.1:11434
HH_PROBE_TIMEOUT=10 # seconds; a hung model server must not hang the supervisor's NEXT command
# Characters allowed in a provider name / URL that ends up in a shell command (NEXT=...).
HH_PROVIDER_ERE='^[A-Za-z0-9._-]+$'
HH_URL_ERE='^https?://[A-Za-z0-9._~:/@%+-]+$'

hh_cfg_get() { # <key> -> value; fails when unset (Hermes prints "Config key not set: <key>")
  local v
  v=$(hermes config get "$1" 2>/dev/null | tail -n 1) || return 1
  case $v in "" | "Config key not set"*) return 1 ;; esac
  printf '%s\n' "$v"
}

hh_run_provider() { # <logfile> -> the provider hermes-run printed in its "== repo:" header, or empty
  [ -r "$1" ] || return 0
  tr -d '\r' < "$1" | sed -n 's/^== repo: .* | provider: \([^ |]*\) |.*/\1/p' | head -n 1 \
    | grep -Ev '^unknown$' || true
}

hh_is_ollama() { # <provider> <url>: an Ollama server (by provider name or its default port)
  case "$1" in *ollama*) return 0 ;; esac
  case "$2" in *:11434 | *:11434/*) return 0 ;; esac
  return 1
}

hh_model_base_url() { # <provider> -> its base URL; fails when it cannot be resolved (no guessing)
  local provider=$1 configured url=""
  configured=$(hh_cfg_get model.provider) || configured=""
  [ -n "$provider" ] || provider=$configured
  # model.base_url belongs to model.provider; a --provider override uses its own providers.<p> entry
  [ "$provider" = "$configured" ] && url=$(hh_cfg_get model.base_url)
  if [ -z "$url" ] && [ -n "$provider" ]; then
    printf '%s' "$provider" | grep -Eq "$HH_PROVIDER_ERE" || return 1
    url=$(hh_cfg_get "providers.$provider.api") || url=$(hh_cfg_get "providers.$provider.base_url") || url=""
  fi
  # only an Ollama provider (or none at all: the harness default) may fall back to Ollama's default
  if [ -z "$url" ]; then
    { [ -z "$provider" ] || hh_is_ollama "$provider" ""; } || return 1
    url=$HH_OLLAMA_DEFAULT
  fi
  printf '%s' "$url" | grep -Eq "$HH_URL_ERE" || return 1
  printf '%s\n' "${url%/}"
}

hh_model_probe_url() { # <provider> -> the URL that answers when the endpoint is up
  local provider=$1 url
  [ -z "$provider" ] || printf '%s' "$provider" | grep -Eq "$HH_PROVIDER_ERE" || return 1
  url=$(hh_model_base_url "$provider") || return 1
  [ -n "$provider" ] || provider=$(hh_cfg_get model.provider) || provider=""
  if hh_is_ollama "$provider" "$url"; then
    printf '%s/api/tags\n' "${url%/v1}" # Ollama's native list; its OpenAI route lives under /v1
  else
    printf '%s/models\n' "$url" # OpenAI-compatible: GET <base>/models
  fi
}

hh_model_probe() { # <provider> -> shell command that succeeds when the endpoint answers
  local url
  url=$(hh_model_probe_url "$1") || return 1
  printf 'curl -sf --max-time %s %s >/dev/null\n' "$HH_PROBE_TIMEOUT" "$url"
}
