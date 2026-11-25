#!/usr/bin/env bash
# Sourced by tests/run_tests.sh (uses ok/bad/eq/say, $tmp $W $BIN $ROOT).
# MODEL_API_ERROR: hermes-supervise's NEXT probes the endpoint the run used (lib/model_endpoint.sh),
# not a hardcoded Ollama :11434 (bead b80). The provider comes from the run log's RUN_PROVIDER: line
# (hermes-run writes it; tests/model_endpoint_run_tests.sh), else model.provider; the URL from
# model.base_url, else providers.<provider>.api.
ME="$tmp/model-endpoint"; mkdir -p "$ME/bin" "$ME/logs"
# hermes stub: `config get <key>` prints $STUB_CFG_<key with . -> _>, else Hermes' "not set" line
cat > "$ME/bin/hermes" <<'S'
#!/bin/sh
[ "$1 $2" = "config get" ] || exit 1
var="STUB_CFG_$(printf '%s' "$3" | tr '.-' '__')"
eval "val=\${$var:-}"
if [ -n "$val" ]; then echo "$val"; else echo "Config key not set: $3"; fi
S
chmod +x "$ME/bin/hermes"
. "$ROOT/lib/model_endpoint.sh"
me() { (PATH="$ME/bin:$PATH" "$@"); }
mtplx_cfg() { env STUB_CFG_model_provider=ollama-launch STUB_CFG_providers_mtplx_api=http://127.0.0.1:8000/v1 \
  STUB_CFG_providers_ollama_launch_api=http://127.0.0.1:11434/v1 "$@"; }

# --- provider from the run log's RUN_PROVIDER: line ---
printf 'CONTEXT: baseline x\nRUN_PROVIDER: mtplx\nbody\nRUN_PROVIDER: other\n' > "$ME/run.log"
eq "model endpoint: provider read from the run log's first RUN_PROVIDER: line" "$(hh_run_provider "$ME/run.log")" mtplx
printf 'RUN_PROVIDER: unknown\n' > "$ME/unk.log"
eq "model endpoint: RUN_PROVIDER: unknown counts as none" "$(hh_run_provider "$ME/unk.log")" ""
eq "model endpoint: no RUN_PROVIDER: line, no provider" "$(hh_run_provider "$ROOT/tests/fixtures/model_api_error.log")" ""

# --- probe command per provider ---
eq "model endpoint: custom OpenAI-compatible provider probes <base>/models" \
  "$(me mtplx_cfg bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe mtplx")" \
  "curl -sf --max-time 10 http://127.0.0.1:8000/v1/models >/dev/null"
eq "model endpoint: Ollama provider probes /api/tags on 11434" \
  "$(me mtplx_cfg bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe ollama-launch")" \
  "curl -sf --max-time 10 http://127.0.0.1:11434/api/tags >/dev/null"
eq "model endpoint: model.base_url wins for the configured provider" \
  "$(me env STUB_CFG_model_provider=custom STUB_CFG_model_base_url=http://gpu:8000/v1/ \
     bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe custom")" \
  "curl -sf --max-time 10 http://gpu:8000/v1/models >/dev/null"
eq "model endpoint: model.base_url is ignored for another provider (a --provider override)" \
  "$(me env STUB_CFG_model_provider=custom STUB_CFG_model_base_url=http://gpu:8000/v1 STUB_CFG_providers_mtplx_api=http://127.0.0.1:8000/v1 \
     bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe mtplx")" \
  "curl -sf --max-time 10 http://127.0.0.1:8000/v1/models >/dev/null"
eq "model endpoint: no provider at all falls back to model.provider" \
  "$(me mtplx_cfg env STUB_CFG_model_provider=mtplx bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe ''")" \
  "curl -sf --max-time 10 http://127.0.0.1:8000/v1/models >/dev/null"
eq "model endpoint: an Ollama provider with no URL configured uses the Ollama default" \
  "$(me bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe ollama")" \
  "curl -sf --max-time 10 http://127.0.0.1:11434/api/tags >/dev/null"
out=$(me bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe mtplx" 2>&1); rc=$?
[ $rc -ne 0 ] && [ -z "$out" ] && ok "model endpoint: an unresolvable non-Ollama endpoint fails, no guess" || bad "model endpoint: unresolvable" "$rc $out"
out=$(me env STUB_CFG_providers_evil_api='http://x/v1;touch /tmp/pwn' bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe evil" 2>&1); rc=$?
[ $rc -ne 0 ] && [ -z "$out" ] && ok "model endpoint: a URL with shell characters is refused" || bad "model endpoint: unsafe url" "$rc $out"
out=$(me bash -c ". '$ROOT/lib/model_endpoint.sh'; hh_model_probe 'a b;c'" 2>&1); rc=$?
[ $rc -ne 0 ] && [ -z "$out" ] && ok "model endpoint: an unsafe provider name is refused" || bad "model endpoint: unsafe provider" "$rc $out"

# --- hermes-supervise end to end ---
{ printf 'RUN_PROVIDER: mtplx\n'; cat "$ROOT/tests/fixtures/model_api_error.log"; } > "$ME/logs/run-1.log"
out=$(cd "$W" && me mtplx_cfg env HERMES_LOG_DIR="$ME/logs" "$BIN/hermes-supervise" "$ME/logs/run-1.log")
say "$out" | grep -qx 'NEXT=curl -sf --max-time 10 http://127.0.0.1:8000/v1/models >/dev/null && hermes-launch --reason MODEL_API_ERROR --issue unknown' \
  && ok "supervise MODEL_API_ERROR: a run on mtplx probes its endpoint although model.provider is ollama-launch" || bad "supervise custom endpoint" "$out"
say "$out" | grep -q '^WHY=.*http://127.0.0.1:8000/v1/models' && ok "supervise MODEL_API_ERROR: WHY names the probed URL" || bad "supervise custom WHY" "$out"
{ printf 'RUN_PROVIDER: ollama-launch\n'; cat "$ROOT/tests/fixtures/model_api_error.log"; } > "$ME/logs/run-2.log"
out=$(cd "$W" && me mtplx_cfg env HERMES_LOG_DIR="$ME/logs" "$BIN/hermes-supervise" "$ME/logs/run-2.log")
say "$out" | grep -q '^NEXT=curl -sf --max-time 10 http://127.0.0.1:11434/api/tags >/dev/null && hermes-launch ' \
  && ok "supervise MODEL_API_ERROR: Ollama run still probes /api/tags" || bad "supervise ollama endpoint" "$out"
out=$(cd "$W" && me env HERMES_LOG_DIR="$ME/logs" "$BIN/hermes-supervise" "$ME/logs/run-1.log")
say "$out" | grep -q '^ACTION=ASK_HUMAN$' && say "$out" | grep -q '^WHY=.*mtplx' && ! say "$out" | grep -q '^NEXT=' \
  && ok "supervise MODEL_API_ERROR: unresolvable endpoint asks the human" || bad "supervise unresolvable endpoint" "$out"
