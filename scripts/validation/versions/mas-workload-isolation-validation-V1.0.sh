#!/usr/bin/env bash
set -uo pipefail

# MAS Workload Isolation - Post Migration Validator V1.0
# READ-ONLY: this script does not label, patch, delete, restart, or modify cluster resources.

INSTANCE=""
CORE_NS=""
MANAGE_NS=""
SLS_NS=""
MONGO_NS=""
LABEL_KEY="workload-group"
LABEL_VALUE=""
ALLOWED_NODES=""
OUT_DIR=""
OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-300s}"

usage() {
  cat <<'EOF'
Usage:
  mas-workload-isolation-validation-V1.0.sh \
    --instance <id> \
    --core-namespace <ns> \
    [--manage-namespace <ns>] \
    [--sls-namespace <ns>] \
    [--mongodb-namespace <ns>] \
    --label-value <value> \
    --allowed-nodes <node1,node2,...> \
    [--label-key workload-group]

Notes:
  * Completely read-only.
  * Optional components are reported N/A when their namespace/workload is absent.
  * Supporting/operator workloads are reported separately from application placement.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2;;
    --core-namespace) CORE_NS="$2"; shift 2;;
    --manage-namespace) MANAGE_NS="$2"; shift 2;;
    --sls-namespace) SLS_NS="$2"; shift 2;;
    --mongodb-namespace) MONGO_NS="$2"; shift 2;;
    --label-key) LABEL_KEY="$2"; shift 2;;
    --label-value) LABEL_VALUE="$2"; shift 2;;
    --allowed-nodes) ALLOWED_NODES="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "[ERROR] Unknown argument: $1"; usage; exit 2;;
  esac
done

[[ -n "$INSTANCE" && -n "$CORE_NS" && -n "$LABEL_VALUE" && -n "$ALLOWED_NODES" ]] || {
  usage; exit 2;
}

IFS=',' read -r -a NODES <<< "$ALLOWED_NODES"
ts="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${PWD}/mas-workload-validation-${INSTANCE}-${ts}"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/validation.log"
TXT="$OUT_DIR/VALIDATION-REPORT.txt"
exec > >(tee -a "$LOG") 2>&1

PASS=0; FAIL=0; WARN=0; INFO=0
declare -a SUMMARY=()

section(){ printf '\n============================================================\n %s\n============================================================\n' "$1"; }
result(){
  local component="$1" status="$2" detail="$3"
  SUMMARY+=("$component|$status|$detail")
  case "$status" in
    PASS) ((PASS+=1));;
    FAIL) ((FAIL+=1));;
    WARN) ((WARN+=1));;
    INFO|N/A) ((INFO+=1));;
  esac
  printf "%-28s %-6s %s\n" "$component" "$status" "$detail"
}
allowed(){
  local node="$1" n
  for n in "${NODES[@]}"; do [[ "$node" == "$n" ]] && return 0; done
  return 1
}
ns_exists(){ oc --request-timeout="$OC_REQUEST_TIMEOUT" get ns "$1" >/dev/null 2>&1; }

# Treat these as supporting/control-plane workloads, not application-placement failures.
is_supporting_pod(){
  local p="$1"
  [[ "$p" =~ ^ibm-truststore-mgr-controller-manager- ]] ||
  [[ "$p" =~ ^mongodb-kubernetes-operator- ]] ||
  [[ "$p" =~ ^ibm-sls-controller-manager- ]]
}

validate_namespace_apps(){
  local label="$1" ns="$2"
  if [[ -z "$ns" ]] || ! ns_exists "$ns"; then
    result "$label" "N/A" "namespace not present/configured"
    return
  fi

  local rows app_total=0 app_bad=0 app_unhealthy=0 supporting=0
  rows="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$ns" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.nodeName}{"|"}{range .status.containerStatuses[*]}{.ready}{","}{end}{"\n"}{end}' 2>/dev/null || true)"

  while IFS='|' read -r pod phase node ready; do
    [[ -n "$pod" ]] || continue
    [[ "$phase" == "Succeeded" ]] && continue

    if is_supporting_pod "$pod"; then
      ((supporting+=1))
      printf "  [INFO] supporting %-55s node=%s phase=%s\n" "$pod" "${node:-<none>}" "$phase"
      continue
    fi

    ((app_total+=1))
    if [[ "$phase" != "Running" ]]; then
      ((app_unhealthy+=1))
      printf "  [WARN] %-60s phase=%s node=%s\n" "$pod" "$phase" "${node:-<none>}"
    fi
    if ! allowed "$node"; then
      ((app_bad+=1))
      printf "  [FAIL] %-60s outside target pool: %s\n" "$pod" "${node:-<none>}"
    fi
  done <<< "$rows"

  if (( app_total == 0 )); then
    result "$label" "N/A" "no application runtime pods discovered; supporting=$supporting"
  elif (( app_bad > 0 )); then
    result "$label" "FAIL" "application pods=$app_total placement violations=$app_bad unhealthy=$app_unhealthy supporting=$supporting"
  elif (( app_unhealthy > 0 )); then
    result "$label" "WARN" "placement compliant; application pods=$app_total unhealthy=$app_unhealthy supporting=$supporting"
  else
    result "$label" "PASS" "application pods=$app_total all on target pool; supporting=$supporting"
  fi
}

section "MAS WORKLOAD ISOLATION - POST MIGRATION VALIDATION V1.0"
echo "Instance       : $INSTANCE"
echo "Target nodes   : $ALLOWED_NODES"
echo "Required label : $LABEL_KEY=$LABEL_VALUE"
echo "Mode           : READ ONLY"
echo "Started        : $(date)"

section "TARGET NODE LABELS"
label_bad=0
for n in "${NODES[@]}"; do
  if ! oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" >/dev/null 2>&1; then
    echo "[FAIL] target node not found: $n"; ((label_bad+=1)); continue
  fi
  v="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" -o "jsonpath={.metadata.labels.${LABEL_KEY}}" 2>/dev/null || true)"
  echo "$n : ${LABEL_KEY}=${v:-<missing>}"
  [[ "$v" == "$LABEL_VALUE" ]] || ((label_bad+=1))
done
if (( label_bad == 0 )); then
  result "Target node labels" "PASS" "all target nodes have $LABEL_KEY=$LABEL_VALUE"
else
  result "Target node labels" "FAIL" "$label_bad target node label issue(s)"
fi

section "MAS CORE"
validate_namespace_apps "MAS Core" "$CORE_NS"

section "APPCONFIG / GRAPHITE"
if ns_exists "$CORE_NS"; then
  graphite_rows="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$CORE_NS" \
    -l "app=${INSTANCE}-graphite-configuration" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "$graphite_rows" ]]; then
    result "AppConfig / Graphite" "N/A" "optional Graphite workload not installed/running"
  else
    g_bad=0; g_total=0; g_unhealthy=0
    while IFS='|' read -r pod phase node; do
      [[ -n "$pod" ]] || continue
      ((g_total+=1))
      [[ "$phase" == "Running" ]] || ((g_unhealthy+=1))
      allowed "$node" || ((g_bad+=1))
      printf "  %-60s phase=%s node=%s\n" "$pod" "$phase" "$node"
    done <<< "$graphite_rows"
    if (( g_bad > 0 )); then
      result "AppConfig / Graphite" "FAIL" "$g_bad/$g_total pod(s) outside target pool"
    elif (( g_unhealthy > 0 )); then
      result "AppConfig / Graphite" "WARN" "placement compliant but $g_unhealthy pod(s) not Running"
    else
      result "AppConfig / Graphite" "PASS" "$g_total pod(s) Running on target pool"
    fi
  fi
else
  result "AppConfig / Graphite" "N/A" "core namespace unavailable"
fi

section "MANAGE"
validate_namespace_apps "Manage" "$MANAGE_NS"

# Informational Manage runtime topology discovery.
if [[ -n "$MANAGE_NS" ]] && ns_exists "$MANAGE_NS"; then
  echo
  echo "Manage runtime topology (informational):"
  oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$MANAGE_NS" --no-headers 2>/dev/null |
    awk '{print $1}' |
    grep -E "^${INSTANCE}-maximo-" || echo "  No ${INSTANCE}-maximo-* runtime pods discovered (valid for non-runtime/MREF-style environments)."
fi

section "SLS"
if [[ -z "$SLS_NS" ]] || ! ns_exists "$SLS_NS"; then
  result "SLS application" "N/A" "SLS namespace not supplied/present"
else
  sls_rows="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$SLS_NS" --no-headers 2>/dev/null || true)"
  sls_app="$(printf '%s\n' "$sls_rows" | awk '$1 ~ /^sls-api-/ {print}')"
  if [[ -z "$sls_app" ]]; then
    result "SLS application" "N/A" "no sls-api-* runtime pod discovered"
  else
    s_bad=0; s_unhealthy=0; s_total=0
    while read -r pod ready status rest; do
      [[ -n "$pod" ]] || continue
      node="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pod "$pod" -n "$SLS_NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
      ((s_total+=1)); [[ "$status" == "Running" ]] || ((s_unhealthy+=1)); allowed "$node" || ((s_bad+=1))
      echo "  $pod status=$status node=$node"
    done <<< "$sls_app"
    if ((s_bad>0)); then result "SLS application" "FAIL" "$s_bad/$s_total runtime pod(s) outside target pool"
    elif ((s_unhealthy>0)); then result "SLS application" "WARN" "placement compliant but $s_unhealthy pod(s) unhealthy"
    else result "SLS application" "PASS" "$s_total runtime pod(s) Running on target pool"; fi
  fi
  echo "Supporting SLS controllers (informational):"
  printf '%s\n' "$sls_rows" | grep -E 'ibm-sls-controller-manager|ibm-truststore-mgr-controller-manager' || true
fi

section "MONGODB"
if [[ -z "$MONGO_NS" ]] || ! ns_exists "$MONGO_NS"; then
  result "MongoDB members" "N/A" "MongoDB namespace not supplied/present"
else
  mongo_rows="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$MONGO_NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.nodeName}{"|"}{range .status.containerStatuses[*]}{.ready}{","}{end}{"\n"}{end}' 2>/dev/null || true)"
  m_total=0; m_bad=0; m_unhealthy=0
  while IFS='|' read -r pod phase node ready; do
    [[ "$pod" =~ ^mas-mongo-ce-[0-9]+$ ]] || continue
    ((m_total+=1)); [[ "$phase" == "Running" ]] || ((m_unhealthy+=1)); allowed "$node" || ((m_bad+=1))
    echo "  $pod phase=$phase node=$node"
  done <<< "$mongo_rows"
  if ((m_total==0)); then result "MongoDB members" "N/A" "no mas-mongo-ce-N members discovered"
  elif ((m_bad>0)); then result "MongoDB members" "FAIL" "$m_bad/$m_total member(s) outside target pool"
  elif ((m_unhealthy>0)); then result "MongoDB members" "WARN" "placement compliant but $m_unhealthy member(s) unhealthy"
  else result "MongoDB members" "PASS" "$m_total/$m_total members Running on target pool"; fi

  echo "MongoDB operator placement (informational):"
  printf '%s\n' "$mongo_rows" | grep '^mongodb-kubernetes-operator-' || true
fi

section "FINAL RESULT"
{
  printf "%-28s %-6s %s\n" "COMPONENT" "STATUS" "DETAIL"
  printf "%-28s %-6s %s\n" "----------------------------" "------" "-----------------------------------------------"
  for row in "${SUMMARY[@]}"; do
    IFS='|' read -r c st d <<< "$row"
    printf "%-28s %-6s %s\n" "$c" "$st" "$d"
  done
  echo
  echo "PASS=$PASS  FAIL=$FAIL  WARN=$WARN  INFO/N-A=$INFO"
  if (( FAIL > 0 )); then
    echo "OVERALL RESULT: FAIL"
  elif (( WARN > 0 )); then
    echo "OVERALL RESULT: PASS WITH WARNING"
  else
    echo "OVERALL RESULT: PASS"
  fi
  echo "Completed: $(date)"
  echo "This validation was read-only."
} | tee "$TXT"

echo
echo "Validation artifacts:"
echo "  $TXT"
echo "  $LOG"

(( FAIL == 0 ))
