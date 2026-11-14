#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
now() { date -u +%FT%TZ; }
number() {
  [[ $2 =~ ^(0|[1-9][0-9]{0,5})$ ]] && (( $2 >= $3 && $2 <= $4 )) ||
    fail "$1 debe estar entre $3 y $4"
}

mode=$1
shift
if [[ ${1:-} == --help ]]; then
  echo "Uso: $mode [--dry-run]; ver README.md para las variables de entorno"
  exit
fi
dry=false
if [[ ${1:-} == --dry-run ]]; then dry=true; shift; fi
(( $# == 0 )) || fail "argumentos desconocidos"
: "${CONTEXT:?indique CONTEXT}" "${NAMESPACE:?indique NAMESPACE}" \
  "${SELECTOR:?indique SELECTOR}" "${DEPLOYMENT:?indique DEPLOYMENT}" \
  "${PROBE_URL:?indique PROBE_URL}" "${HYPOTHESIS:?indique HYPOTHESIS}"
DURATION=${DURATION:-30}
BASELINE=${BASELINE:-15}
RECOVERY=${RECOVERY:-120}
OBSERVE_AFTER=${OBSERVE_AFTER:-15}
SLO_P95_MS=${SLO_P95_MS:-500}
SLO_SUCCESS_PCT=${SLO_SUCCESS_PCT:-99}
REQUESTS=${REQUESTS:-500}
CONCURRENCY=${CONCURRENCY:-10}
WORKERS=${WORKERS:-1}
MEMORY_MIB=${MEMORY_MIB:-16}
DELAY_MS=${DELAY_MS:-200}
LOSS_PCT=${LOSS_PCT:-5}
INTERFACE=${INTERFACE:-eth0}
LOAD_URL=${LOAD_URL:-http://127.0.0.1:5000/api/login}
number DURATION "$DURATION" 1 300
number BASELINE "$BASELINE" 5 120
number RECOVERY "$RECOVERY" 10 300
number OBSERVE_AFTER "$OBSERVE_AFTER" 0 300
number SLO_P95_MS "$SLO_P95_MS" 1 10000
number SLO_SUCCESS_PCT "$SLO_SUCCESS_PCT" 1 100
number REQUESTS "$REQUESTS" 1 2000
number CONCURRENCY "$CONCURRENCY" 1 32
number WORKERS "$WORKERS" 1 4
number MEMORY_MIB "$MEMORY_MIB" 1 256
number DELAY_MS "$DELAY_MS" 1 1000
number LOSS_PCT "$LOSS_PCT" 1 10
[[ $INTERFACE =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$ ]] || fail "interfaz inválida"
for name in "$NAMESPACE" "$DEPLOYMENT" ${POD:+"$POD"} ${CONTAINER:+"$CONTAINER"}; do
  [[ $name =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail "nombre Kubernetes inválido: $name"
done
local_url() {
  [[ $1 =~ ^http://(127\.0\.0\.1|localhost):([1-9][0-9]{0,4})/[^[:space:]]*$ ]] ||
    fail "use una URL HTTP de loopback con port-forward"
  number puerto "${BASH_REMATCH[2]}" 1 65535
}
local_url "$PROBE_URL"
case $mode in
  load-requests) local_url "$LOAD_URL"; intensity="$REQUESTS requests, concurrencia $CONCURRENCY" ;;
  pod-delete) intensity="1 réplica" ;;
  cpu-spike) intensity="$WORKERS procesos" ;;
  ram-spike) intensity="$MEMORY_MIB MiB" ;;
  network-latency) intensity="$DELAY_MS ms en $INTERFACE" ;;
  network-loss) intensity="$LOSS_PCT % en $INTERFACE" ;;
  *) fail "modo desconocido" ;;
esac
if [[ -n ${PROMETHEUS_URL:-} ]]; then local_url "${PROMETHEUS_URL%/}/"; fi

id="$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM"
printf '%s\n' "experiment_id: $id" "failure_mode: $mode" \
  "target_component: $DEPLOYMENT" "namespace: $NAMESPACE" "selector: $SELECTOR" \
  "context: $CONTEXT" "hypothesis: $HYPOTHESIS" "intensity: $intensity" \
  "duration_limit_s: $DURATION" "slo_p95_ms: $SLO_P95_MS" "slo_success_pct: $SLO_SUCCESS_PCT"
if $dry; then
  echo "Dry run local: parámetros válidos. Los prechecks del clúster se realizan al ejecutar."
  exit
fi

for tool in kubectl curl jq awk sort mktemp; do
  command -v "$tool" >/dev/null || fail "falta $tool"
done
[[ $(kubectl config current-context) == "$CONTEXT" ]] || fail "contexto activo distinto de $CONTEXT"
k() { MSYS_NO_PATHCONV=1 kubectl --context="$CONTEXT" --namespace="$NAMESPACE" --request-timeout=10s "$@"; }
deployment=$(k get deployment "$DEPLOYMENT" -o json)
deployment_uid=$(jq -er '.metadata.uid' <<<"$deployment")
desired=$(jq -er '.spec.replicas | select(. > 0)' <<<"$deployment")
jq -e '(.status.observedGeneration == .metadata.generation) and
  (.status.updatedReplicas == .spec.replicas) and (.status.availableReplicas == .spec.replicas)' \
  <<<"$deployment" >/dev/null || fail "Deployment sin estado estable"
sets=$(k get rs -o json | jq -c --arg uid "$deployment_uid" \
  '[.items[] | select(any(.metadata.ownerReferences[]?; .controller and .uid == $uid)) | .metadata.uid]')
pods() { k get pods -l "$SELECTOR" -o json; }
selected=$(pods)
jq -e --argjson sets "$sets" --argjson desired "$desired" '
  (.items | length == $desired) and all(.items[];
    .metadata.deletionTimestamp == null and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    any(.metadata.ownerReferences[]?; .controller and (.uid as $uid | $sets | index($uid) != null)))' \
  <<<"$selected" >/dev/null || fail "el selector debe coincidir con todas y solo las réplicas Ready del Deployment"
pod=
container=
target_uid=
if [[ $mode != load-requests ]]; then
  candidates=$(jq -r '.items[] | select(.metadata.deletionTimestamp == null and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name' <<<"$selected")
  [[ -n $candidates ]] || fail "no hay pods Ready"
  pod=${POD:-$candidates}
  [[ $pod != *$'\n'* ]] && [[ $'\n'$candidates$'\n' == *$'\n'"$pod"$'\n'* ]] ||
    fail "indique POD entre los candidatos: $candidates"
  target=$(jq -c --arg name "$pod" '.items[] | select(.metadata.name == $name)' <<<"$selected")
  target_uid=$(jq -er '.metadata.uid' <<<"$target")
  rs_uid=$(jq -er '.metadata.ownerReferences[] | select(.controller).uid' <<<"$target")
  if [[ $mode == pod-delete ]]; then
    (( desired >= 2 )) || fail "pod-delete exige al menos dos réplicas disponibles"
  else
    container=${CONTAINER:-$(jq -r '.spec.containers[].name' <<<"$target")}
    jq -e --arg name "$container" 'any(.spec.containers[]; .name == $name)' <<<"$target" >/dev/null ||
      fail "indique un CONTAINER válido"
    jq -e '.spec.hostNetwork != true' <<<"$target" >/dev/null || fail "pod con hostNetwork"
  fi
fi

out=${EVIDENCE_DIR:-./chaos-evidence}/$id
mkdir -p -- "${out%/*}"
mkdir -- "$out"
remote_pid=
sampler_pid=
snapshot_pid=
load_pids=()
marker="/tmp/aiops-$id"
phase="$out/phase"
printf 'baseline\n' >"$phase"
started=$(now)
printf '%s\n' "started_at: $started" "pod: $pod" "pod_uid: $target_uid" "container: $container" >"$out/timeline.txt"
printf '%s\n' "experiment_id: $id" "failure_mode: $mode" "target_component: $DEPLOYMENT" \
  "namespace: $NAMESPACE" "selector: $SELECTOR" "context: $CONTEXT" \
  "hypothesis: $HYPOTHESIS" "intensity: $intensity" "probe_url: $PROBE_URL" \
  "duration_limit_s: $DURATION" "baseline_s: $BASELINE" "recovery_limit_s: $RECOVERY" \
  "slo_p95_ms: $SLO_P95_MS" "slo_success_pct: $SLO_SUCCESS_PCT" >"$out/experiment.txt"
printf 'hypothesis_verdict: inconcluso (ejecución incompleta)\n' >"$out/verdict.txt"
event() { printf '%s: %s\n' "$1" "$(now)" | tee -a "$out/timeline.txt"; }
same_pod() { [[ $(k get pod "$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$target_uid" ]]; }
remote() {
  MSYS_NO_PATHCONV=1 k exec "$pod" -c "$container" -- "$@"
}
cleanup() {
  local status=$?
  trap - EXIT
  trap '' INT TERM
  if [[ -n $sampler_pid ]]; then kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; fi
  if [[ -n $snapshot_pid ]]; then kill "$snapshot_pid" 2>/dev/null || true; wait "$snapshot_pid" 2>/dev/null || true; fi
  for pid in "${load_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  if [[ -n $remote_pid ]]; then
    if same_pod; then
      remote sh -c 'if [ -d "$1" ]; then touch "$1/stop"; fi' sh "$marker" ||
        echo "Cleanup remoto no confirmado; consultar el plazo remoto" >&2
    fi
    kill "$remote_pid" 2>/dev/null || true
    wait "$remote_pid" 2>/dev/null || true
  fi
  event ended_at
  printf 'exit_code: %s\n' "$status" >>"$out/timeline.txt"
  echo "Evidencia: $out"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot() {
  local stage=$1
  pods >"$out/$stage-pods.json" || true
  k get deployment "$DEPLOYMENT" -o json >"$out/$stage-deployment.json" || true
  k get events -o json >"$out/$stage-events.json" || true
  k logs -l "$SELECTOR" --all-containers --prefix --timestamps --tail=100 \
    >"$out/$stage-logs.txt" 2>"$out/$stage-logs.err" || true
  if [[ -n $container ]] && same_pod; then
    k logs "$pod" -c "$container" --previous --timestamps --tail=100 \
      >"$out/$stage-previous-logs.txt" 2>"$out/$stage-previous-logs.err" || true
  fi
}

metrics() {
  [[ -n ${PROMETHEUS_URL:-} ]] || return 0
  local query name
  local -a args
  local gateway='service_name="PharmaGo.ApiGateway"'
  local target="namespace=\"$NAMESPACE\",container!=\"\",container!=\"POD\""
  if [[ -n $pod ]]; then target+=",pod=\"$pod\""; fi
  while IFS='|' read -r name query; do
    args=(--data-urlencode "query=$query" --data-urlencode "start=$started"
          --data-urlencode "end=$observed_until" --data-urlencode "step=15s")
    curl -fsS --globoff --noproxy '*' --max-time 8 --get "${PROMETHEUS_URL%/}/api/v1/query_range" "${args[@]}" \
      >"$out/metric-$name.json" 2>>"$out/prometheus.err" || true
  done <<EOF
rps|sum by (status_code) (rate(pharmago_http_requests_total{$gateway}[1m]))
p50|histogram_quantile(0.50, sum by (le) (rate(pharmago_http_request_duration_milliseconds_bucket{$gateway}[1m])))
p95|histogram_quantile(0.95, sum by (le) (rate(pharmago_http_request_duration_milliseconds_bucket{$gateway}[1m])))
p99|histogram_quantile(0.99, sum by (le) (rate(pharmago_http_request_duration_milliseconds_bucket{$gateway}[1m])))
cpu|sum by (pod, container) (rate(container_cpu_usage_seconds_total{$target}[1m]))
throttling|sum by (pod, container) (rate(container_cpu_cfs_throttled_periods_total{$target}[1m]))
memory|container_memory_working_set_bytes{$target}
EOF
}

http() {
  curl --silent --show-error --globoff --noproxy '*' --max-time 3 --connect-timeout 2 \
    --output /dev/null --write-out '%{http_code},%{time_total}' "$@"
}
sample() {
  local stage stamp result rc alerts
  while :; do
    stage=$(<"$phase")
    stamp=$(now)
    rc=0
    result=$(http "$PROBE_URL" 2>>"$out/curl.err") || rc=$?
    printf '%s,%s,%s,%s\n' "$stamp" "$stage" "${result:-000,0}" "$rc" >>"$out/probe.csv"
    if [[ -n ${PROMETHEUS_URL:-} ]]; then
      alerts=$(curl -fsS --globoff --noproxy '*' --max-time 2 "${PROMETHEUS_URL%/}/api/v1/alerts") &&
        jq -c --arg time "$stamp" --arg phase "$stage" \
          '{time:$time,phase:$phase,alerts:.data.alerts}' <<<"$alerts" >>"$out/prometheus-alerts.jsonl" || true
    fi
    sleep 1
  done
}
printf 'utc,phase,status,seconds,curl_exit\n' >"$out/probe.csv"
snapshot before
sample &
sampler_pid=$!
sleep "$BASELINE"
awk -F, -v p95="$SLO_P95_MS" '
  $2=="baseline" {n++; if ($3 !~ /^2/ || $5 != 0 || $4*1000 > p95) bad++}
  END {exit !(n >= 3 && !bad)}
' "$out/probe.csv" || fail "línea base inestable o insuficiente"

change_phase() {
  printf '%s\n' "$1" >"$phase.next"
  mv -f -- "$phase.next" "$phase"
}
event injection_started_at
injection_epoch=$(date +%s)
change_phase during
case $mode in
  load-requests)
    snapshot during &
    snapshot_pid=$!
    deadline=$((SECONDS + DURATION))
    for ((worker=1; worker<=CONCURRENCY && worker<=REQUESTS; worker++)); do
      (
        for ((i=worker; i<=REQUESTS && SECONDS<deadline; i+=CONCURRENCY)); do
          rc=0
          stamp=$(now)
          result=$(http -X POST -H 'Content-Type: application/json' \
            --data-binary '{"userName":"chaos-probe","password":"invalid-test-password"}' \
            "$LOAD_URL" 2>>"$out/curl.err") || rc=$?
          printf '%s,%s,%s,%s\n' "$stamp" "$i" "${result:-000,0}" "$rc"
        done
      ) >"$out/load-$worker.csv" &
      load_pids+=("$!")
    done
    for pid in "${load_pids[@]}"; do wait "$pid"; done
    load_pids=()
    printf 'utc,request,status,seconds,curl_exit\n' >"$out/load.csv"
    cat "$out"/load-*.csv >>"$out/load.csv"
    rm -- "$out"/load-*.csv
    ;;
  pod-delete)
    same_pod || fail "el objetivo cambió durante la línea base"
    available=$(k get deploy "$DEPLOYMENT" -o jsonpath='{.status.availableReplicas}')
    [[ $available == "$desired" ]] || fail "cambió la disponibilidad"
    # La precondición UID protege contra reutilización del nombre.
    jq -nc --arg uid "$target_uid" \
      '{apiVersion:"policy/v1",kind:"Eviction",deleteOptions:{preconditions:{uid:$uid}}}' |
      k create --raw "/api/v1/namespaces/$NAMESPACE/pods/$pod/eviction" -f - >"$out/eviction.json"
    known=$(jq -c '[.items[].metadata.uid]' <<<"$selected")
    deadline=$((SECONDS + DURATION))
    replacement=
    while (( SECONDS < deadline )); do
      replacement=$(pods | jq -r --arg rs "$rs_uid" --argjson known "$known" '
        [.items[] | select(.metadata.deletionTimestamp == null and
          any(.metadata.ownerReferences[]?; .controller and .uid == $rs) and
          (.metadata.uid as $uid | $known | index($uid) == null)) | .metadata.name]
        | if length == 1 then .[0] else empty end')
      [[ -z $replacement ]] || break
      sleep 1
    done
    [[ -n $replacement ]] || fail "no apareció un reemplazo único en el plazo"
    printf 'replacement_pod: %s\n' "$replacement" >>"$out/timeline.txt"
    event replacement_seen_at
    pods >"$out/during-pods.json"
    k wait --for=condition=Ready "pod/$replacement" --timeout="${RECOVERY}s" --request-timeout=0
    event replacement_ready_at
    ;;
  *)
    same_pod || fail "el objetivo cambió durante la línea base"
    # La ejecución remota se limita por su propio reloj. El timeout del cliente
    # cubre conexión y transferencia, además del período de inyección.
    MSYS_NO_PATHCONV=1 kubectl --context="$CONTEXT" -n "$NAMESPACE" \
      --request-timeout="$((DURATION+25))s" exec -i "$pod" -c "$container" -- \
      sh -s -- "$mode" "$marker" "$DURATION" "$WORKERS" "$MEMORY_MIB" \
      "$INTERFACE" "$DELAY_MS" "$LOSS_PCT" <"$(dirname "$0")/remote-fault.sh" \
      >"$out/injection.log" 2>&1 &
    remote_pid=$!
    snapshot during
    if ! wait "$remote_pid"; then
      cat "$out/injection.log" >&2
      fail "falló la inyección o su limpieza"
    fi
    remote_pid=
    ;;
esac
event injection_finished_at
finished_epoch=$(date +%s)
change_phase after
deadline=$((SECONDS + RECOVERY))
recovered=false
while (( SECONDS < deadline )); do
  state=$(k get deployment "$DEPLOYMENT" -o json)
  if jq -e --argjson desired "$desired" '
    .spec.replicas == $desired and .status.availableReplicas == $desired and
    .status.observedGeneration == .metadata.generation' <<<"$state" >/dev/null &&
    awk -F, -v p95="$SLO_P95_MS" '
      $2=="after" {if ($3 ~ /^2/ && $5==0 && $4*1000<=p95) good++; else good=0}
      END {exit !(good>=3)}
    ' "$out/probe.csv"; then
    event recovered_at
    printf 'recovery_from_injection_s: %s\n' "$(( $(date +%s) - injection_epoch ))" >>"$out/timeline.txt"
    recovered=true
    break
  fi
  sleep 1
done
if $recovered; then sleep "$OBSERVE_AFTER"; fi
observed_until=$(now)
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=
if [[ -n $snapshot_pid ]]; then wait "$snapshot_pid"; snapshot_pid=; fi
snapshot after
metrics

first_impact=$(awk -F, -v p95="$SLO_P95_MS" '
  $2=="during" && ($3 !~ /^2/ || $5 != 0 || $4*1000 > p95) {print $1; exit}
' "$out/probe.csv")
printf 'first_probe_impact_at: %s\n' "${first_impact:-no observado}" >>"$out/timeline.txt"
if [[ -n $first_impact ]]; then
  printf 'first_probe_impact_s: %s\n' "$(( $(date -d "$first_impact" +%s) - injection_epoch ))" >>"$out/timeline.txt"
fi
if [[ -s $out/prometheus-alerts.jsonl ]]; then
  jq -s '([.[] | select(.phase=="baseline") | .alerts[]? | select(.state=="firing") | .labels]) as $baseline
    | [.[] | select(.phase!="baseline") | .time as $time | .alerts[]?
      | select(.state=="firing" and (.labels as $labels | $baseline | index($labels) == null))
      | {time:$time, labels}] | first // null' "$out/prometheus-alerts.jsonl" >"$out/first-prometheus-alert.json"
  first_alert=$(jq -r '.time // empty' "$out/first-prometheus-alert.json")
  if [[ -n $first_alert ]]; then
    printf 'first_new_prometheus_alert_s: %s\n' "$(( $(date -d "$first_alert" +%s) - injection_epoch ))" >>"$out/timeline.txt"
  fi
fi

# Percentiles nearest-rank sobre todas las sondas, incluyendo timeouts.
percentiles() {
  sort -n | awk -v phase="$1" '
    {x[NR]=$1}
    END {if (NR) printf "%s samples=%d p50_ms=%g p95_ms=%g p99_ms=%g\n",
    phase, NR, x[int((50*NR+99)/100)], x[int((95*NR+99)/100)], x[int((99*NR+99)/100)];
    else print phase, "sin muestras"}
  '
}
for stage in baseline during after; do
  awk -F, -v stage="$stage" '$2==stage {print $4*1000}' "$out/probe.csv" | percentiles "$stage"
done | tee "$out/latency.txt"
awk -F, -v success="$SLO_SUCCESS_PCT" -v p95="$SLO_P95_MS" '
  $2=="during" {n++; ok+=($3~/^2/ && $5==0); slow+=($4*1000>p95);
    limited+=($3==429); errors+=($3~/^5/); timeouts+=($5==28)}
  END {
    if (!n) {print "slo: inconcluso"; exit}
    printf "samples=%d success=%d http_429=%d http_5xx=%d timeouts=%d\n", n, ok, limited, errors, timeouts;
    print "slo:", (100*ok>=success*n && n-slow>=int((95*n+99)/100)) ? "cumplido" : "incumplido"
  }
' "$out/probe.csv" | tee "$out/slo.txt"
if [[ -f $out/load.csv ]]; then
  awk -F, -v elapsed="$((finished_epoch-injection_epoch))" '
    NR>1 {status[$3]++; if ($5==28) timeouts++}
    END {for (code in status) print code, status[code]; print "timeouts", timeouts+0;
      if (elapsed>0) print "mean_requests_per_second", (NR-1)/elapsed}' \
    "$out/load.csv" | tee "$out/load-summary.txt"
  for group in accepted limited server_error timeout; do
    awk -F, -v group="$group" '
      NR==1 {next}
      group=="accepted" && $3!="429" && $3!~/^5/ && $5==0 {print $4*1000}
      group=="limited" && $3=="429" {print $4*1000}
      group=="server_error" && $3~/^5/ {print $4*1000}
      group=="timeout" && $5==28 {print $4*1000}
    ' "$out/load.csv" | percentiles "$group"
  done | tee "$out/load-latency.txt"
fi
echo 'hypothesis_verdict: pendiente de contraste con la telemetría' | tee "$out/verdict.txt"
$recovered || fail "no se confirmó la recuperación en el plazo"

