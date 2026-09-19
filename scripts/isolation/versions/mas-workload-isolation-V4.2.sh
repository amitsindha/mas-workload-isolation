#!/usr/bin/env bash
# MAS Workload Isolation Orchestrator V4.2
# Validated pattern based on EAM1 MAS 9.1.22 POC.
# V4.2 improvements:
#   1. Zero cluster mutation before explicit YES confirmation.
#   2. Progress messages + 5-minute OpenShift API request timeout for slow operations.
#   3. Integrated migration progress monitor for MAS/SLS/MongoDB reconciliation.
#   4. Optional AppCfg/Graphite discovery, supported CR patching, rollout and validation.
#      Existing AppCfg podTemplates are merged/preserved; Graphite absence is N/A.
#   5. Transient OpenShift API failures during reconciliation are retried until the
#      overall operation timeout instead of aborting a healthy migration.
set -Eeuo pipefail
POLL_INTERVAL="${POLL_INTERVAL:-20}"; TIMEOUT="${TIMEOUT:-1800}"; OC_REQUEST_TIMEOUT="${OC_REQUEST_TIMEOUT:-300s}"
COMPONENTS=""; INSTANCE=""; CORE_NS=""; MANAGE_NS=""; WORKSPACE=""; LABEL_KEY="workload-group"; LABEL_VALUE=""; ALLOWED_NODES=""
PRECHECK_ONLY=false; DRY_RUN=false; AUTO_LABEL=true; RESUME_FROM=""
CAPACITY_PRECHECK=true; DB2_NS=""; MIN_CPU_HEADROOM_PCT=15; MIN_MEM_HEADROOM_PCT=15
MAS_INSTANCES="auto"; PLANS=(); ASSUME_YES=false; EXTERNAL_DB=false; FORCE_REAPPLY=false; SLS_NS=""; MONGO_NS=""; MONGO_NAME="mas-mongo-ce"; MONGO_STABLE_CHECKS=3; FACILITIES_NS=""
DB2_NS=""; DB2_LABEL_KEY="workload-group"; DB2_LABEL_VALUE=""; DB2_ALLOWED_NODES=""; DB2_STABLE_CHECKS=3

usage(){ cat <<'EOF'
Usage:
 ./mas-workload-isolation-V4.2.sh --components mas|sls|mongodb|db2|facilities|comma-separated combination --instance eam2 --core-namespace mas-eam2-core \
 --manage-namespace mas-eam2-manage --workspace maximo \
 --label-key workload-group --label-value eam2 \
 --allowed-nodes worker-3,worker-4 [--auto-label|--no-auto-label] [--precheck-only] [--dry-run]
 [--db2-namespace NAMESPACE | --external-db]
 [--mas-instances auto|mas1,mas2,...]
 [--placement-plan mas1=worker-1,worker-2,worker-3] (repeatable)
 [--yes] [--force-reapply] [--sls-namespace NS] [--mongodb-namespace NS] [--mongodb-name NAME] [--mongodb-stable-checks N]
 [--skip-capacity-precheck]
 [--min-cpu-headroom-pct 15] [--min-mem-headroom-pct 15]

Component rules:
 * MAS requires instance/core/manage parameters.
 * SLS requires only --sls-namespace plus common target parameters.
 * MongoDB requires only --mongodb-namespace plus common target parameters.
 * DB2 requires --db2-namespace, --db2-label-value, --db2-allowed-nodes.
 * DB2-only mode does NOT require MAS/SLS/MongoDB target parameters.
 * DB2 v3.1.3 scope is IBM MAS Manage DB2U only; Monitor/Predict excluded.
 * MongoDB v3.1.3 separately validates CR affinity, generated StatefulSet affinity, and actual pod placement.

Node-label behavior:
 * Missing target labels are added automatically.
 * An existing different value is NEVER overwritten; the script stops.
 * Use --no-auto-label to require labels to exist before execution.
Environment: POLL_INTERVAL=20 TIMEOUT=1800
EOF
}
while [[ $# -gt 0 ]]; do case "$1" in
 --components) COMPONENTS="$2";shift 2;;
 --instance) INSTANCE="$2";shift 2;; --core-namespace) CORE_NS="$2";shift 2;;
 --manage-namespace) MANAGE_NS="$2";shift 2;; --workspace) WORKSPACE="$2";shift 2;;
 --label-key) LABEL_KEY="$2";shift 2;; --label-value) LABEL_VALUE="$2";shift 2;;
 --allowed-nodes) ALLOWED_NODES="$2";shift 2;; --auto-label) AUTO_LABEL=true;shift;; --no-auto-label) AUTO_LABEL=false;shift;;
 --precheck-only) PRECHECK_ONLY=true;shift;; --dry-run) DRY_RUN=true;shift;;
 --resume-from) RESUME_FROM="$2";shift 2;;
 --db2-namespace) DB2_NS="$2";shift 2;;
 --db2-label-key) DB2_LABEL_KEY="$2";shift 2;;
 --db2-label-value) DB2_LABEL_VALUE="$2";shift 2;;
 --db2-allowed-nodes) DB2_ALLOWED_NODES="$2";shift 2;;
 --db2-stable-checks) DB2_STABLE_CHECKS="$2";shift 2;;
 --external-db) EXTERNAL_DB=true; DB2_NS=""; shift;;
 --placement-plan) PLANS+=("$2"); shift 2;;
 --yes) ASSUME_YES=true; shift;; --force-reapply) FORCE_REAPPLY=true; shift;; --sls-namespace) SLS_NS="$2";shift 2;; --mongodb-namespace) MONGO_NS="$2";shift 2;; --mongodb-name) MONGO_NAME="$2";shift 2;; --mongodb-stable-checks) MONGO_STABLE_CHECKS="$2";shift 2;; --facilities-namespace) FACILITIES_NS="$2";shift 2;;
 --mas-instances) MAS_INSTANCES="$2";shift 2;;
 --skip-capacity-precheck) CAPACITY_PRECHECK=false;shift;;
 --min-cpu-headroom-pct) MIN_CPU_HEADROOM_PCT="$2";shift 2;;
 --min-mem-headroom-pct) MIN_MEM_HEADROOM_PCT="$2";shift 2;;
 -h|--help) usage;exit 0;; *) echo "Unknown: $1";usage;exit 2;; esac; done
[[ -n "$COMPONENTS" ]] || { usage; exit 2; }
IFS=',' read -ra COMPS <<<"$COMPONENTS"
has_component(){ local c; for c in "${COMPS[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }
for c in "${COMPS[@]}"; do [[ "$c" =~ ^(mas|sls|mongodb|db2|facilities)$ ]] || { echo "Unsupported component: $c"; exit 2; }; done
if has_component mas; then [[ -n "$INSTANCE" && -n "$CORE_NS" && -n "$MANAGE_NS" ]] || { echo "MAS requires --instance --core-namespace --manage-namespace";exit 2; }; fi
if has_component sls; then [[ -n "$SLS_NS" ]] || { echo "SLS requires --sls-namespace";exit 2; }; fi
if has_component mongodb; then [[ -n "$MONGO_NS" ]] || { echo "MongoDB requires --mongodb-namespace";exit 2; }; fi
if has_component mas || has_component sls || has_component mongodb || has_component facilities; then
 [[ -n "$LABEL_VALUE" && -n "$ALLOWED_NODES" ]] || { echo "MAS/SLS/MongoDB/Facilities selections require --label-value and --allowed-nodes"; exit 2; }
fi
if has_component db2; then
 [[ -n "$DB2_NS" && -n "$DB2_LABEL_VALUE" && -n "$DB2_ALLOWED_NODES" ]] || { echo "DB2 requires --db2-namespace --db2-label-value --db2-allowed-nodes"; exit 2; }
 IFS=',' read -ra DB2_NODES <<<"$DB2_ALLOWED_NODES"
fi
if has_component facilities; then
 [[ -n "$INSTANCE" ]] || { echo "Facilities requires --instance"; exit 2; }
 [[ -n "$FACILITIES_NS" ]] || FACILITIES_NS="mas-${INSTANCE}-facilities"
fi
NODES=()
[[ -n "$ALLOWED_NODES" ]] && IFS=',' read -ra NODES <<<"$ALLOWED_NODES"
RUN_TAG="${INSTANCE:-${LABEL_VALUE:-${DB2_LABEL_VALUE:-run}}}"
RUN_DIR="$PWD/mas-workload-isolation-${RUN_TAG}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"/{backups,patches,reports}; LOG="$RUN_DIR/run.log"; exec > >(tee -a "$LOG") 2>&1
section(){ echo;echo "============================================================";echo " $*";echo "============================================================"; }
info(){ echo "[INFO] $*"; }; warn(){ echo "[WARN] $*"|tee -a "$RUN_DIR/reports/exceptions.txt"; }; die(){ echo "[FAIL] $*";exit 1; }
trap 'echo "[FAIL] line $LINENO; see $LOG"' ERR
regex(){ local x="" n;for n in "${NODES[@]}";do [[ -n "$x" ]]&&x+="|";x+="$n";done;echo "$x";}; ALLOWED_RE="$(regex)"

wait_for(){
 local d="$1"; shift
 local st now elapsed
 st=$(date +%s)
 info "Waiting: $d"
 while ! "$@" >/dev/null 2>&1; do
   now=$(date +%s); elapsed=$((now-st))
   (( elapsed < TIMEOUT )) || die "Timeout: $d"
   info "[PROGRESS] $d still reconciling; elapsed=${elapsed}s; next check in ${POLL_INTERVAL}s"
   sleep "$POLL_INTERVAL"
 done
 now=$(date +%s); elapsed=$((now-st))
 info "Completed: $d (elapsed=${elapsed}s)"
}
# Run a read-only OpenShift query with retry protection.  A transient API
# timeout/unavailability must not abort reconciliation; the caller's overall
# TIMEOUT remains the final failure boundary.
oc_query_retry(){
  local description="$1"; shift
  local start now elapsed attempt=0
  start="$(date +%s)"
  while true; do
    ((attempt+=1))
    if "$@"; then
      (( attempt > 1 )) && info "[RECOVERED] $description succeeded after $attempt attempts"
      return 0
    fi
    now="$(date +%s)"; elapsed=$((now-start))
    if (( elapsed >= TIMEOUT )); then
      warn "$description could not be completed before overall timeout (${TIMEOUT}s)"
      return 1
    fi
    warn "Temporary OpenShift API/query failure during $description; attempt=$attempt elapsed=${elapsed}s; retrying in ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
  done
}

status_has(){ oc get "$1" "$2" -n "$3" -o jsonpath='{.status.podTemplates[*].name}' 2>/dev/null|tr ' ' '\n'|grep -Fxq "$4"; }
affinity_ok(){ [[ "$(oc get "$1" "$2" -n "$3" -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key}' 2>/dev/null)" == "$LABEL_KEY" ]]; }
selector_ok(){ [[ "$(oc get buildconfig "$1" -n "$MANAGE_NS" -o "jsonpath={.spec.nodeSelector.${LABEL_KEY}}" 2>/dev/null)" == "$LABEL_VALUE" ]]; }
entry(){ jq -cn --arg n "$1" --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" '{name:$n,affinity:{nodeAffinity:{requiredDuringSchedulingIgnoredDuringExecution:{nodeSelectorTerms:[{matchExpressions:[{key:$k,operator:"In",values:[$v]}]}]}}}}'; }
nsentry(){ jq -cn --arg n "$1" --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" '{name:$n,nodeSelector:{($k):$v}}'; }
mkpatch(){ local f="$1";shift;printf '%s\n' "$@"|jq -s '{spec:{podTemplates:.}}'>"$f";jq . "$f">/dev/null; }
backup(){ oc get "$1" "$2" -n "$3" -o yaml>"$RUN_DIR/backups/$4"; }
patch(){ if $DRY_RUN;then info "DRY RUN $1/$2";cat "$4";else oc patch "$1" "$2" -n "$3" --type=merge --patch-file="$4";fi; }
cr_entry_compliant(){
 local kind="$1" name="$2" ns="$3" key="$4" mode="${5:-affinity}" json
 json="$(oc get "$kind" "$name" -n "$ns" -o json 2>/dev/null)" || return 1
 if [[ "$mode" == "nodeselector" ]];then jq -e --arg n "$key" --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" 'any(.spec.podTemplates[]?; .name==$n and (.nodeSelector[$k]//"")==$v)' <<<"$json" >/dev/null
 else jq -e --arg n "$key" --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" 'any(.spec.podTemplates[]?; .name==$n and any(.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?; .key==$k and .operator=="In" and (.values|index($v)!=null)))' <<<"$json" >/dev/null;fi
}
all_cr_keys_compliant(){ local kind="$1" name="$2" ns="$3";shift 3;local k;for k in "$@";do cr_entry_compliant "$kind" "$name" "$ns" "$k" affinity||return 1;done; }
compliance_log(){ printf "%-32s %-12s %s\n" "$1" "$2" "$3"|tee -a "$RUN_DIR/reports/compliance.txt"; }
patch_keys(){ local tag="$1" kind="$2" name="$3" ns="$4";shift 4;local keys=("$@") a=() k f="$RUN_DIR/patches/$tag.json";if ! $FORCE_REAPPLY && all_cr_keys_compliant "$kind" "$name" "$ns" "${keys[@]}";then compliance_log "$tag" COMPLIANT SKIPPED;info "$tag already compliant; skipping patch/reconciliation";return 0;fi;compliance_log "$tag" DRIFT/NEW APPLY;backup "$kind" "$name" "$ns" "$tag-before.yaml";for k in "${keys[@]}";do a+=("$(entry "$k")");done;mkpatch "$f" "${a[@]}";patch "$kind" "$name" "$ns" "$f";$DRY_RUN&&return;for k in "${keys[@]}";do wait_for "$kind/$name status $k" status_has "$kind" "$name" "$ns" "$k";done; }

snapshot(){
 local tag="$1"
 {
  section "${tag^^} WORKLOAD PLACEMENT"
  echo "Allowed=$ALLOWED_NODES Label=$LABEL_KEY=$LABEL_VALUE"
  echo "Running workloads are placement-relevant; Succeeded pods are historical/informational."
  for ns in "$CORE_NS" "$MANAGE_NS"; do
    echo; echo "Namespace: $ns"
    oc get pods -n "$ns" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' --sort-by=.metadata.name
  done
  echo
  echo "Active Running distribution:"
  {
    oc get pods -n "$CORE_NS" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'
    oc get pods -n "$MANAGE_NS" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'
  } | sed '/^$/d' | sort | uniq -c | sort -k2
  echo
  echo "Historical Succeeded distribution (informational only):"
  {
    oc get pods -n "$CORE_NS" --field-selector=status.phase=Succeeded -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'
    oc get pods -n "$MANAGE_NS" --field-selector=status.phase=Succeeded -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'
  } | sed '/^$/d' | sort | uniq -c | sort -k2
 } | tee "$RUN_DIR/reports/$tag-placement.txt"
}


discover_mas_instances(){
  local out="$RUN_DIR/reports/mas-instance-inventory.txt"
  section "MAS INSTANCE / NODE INVENTORY"
  mapfile -t WORKERS < <(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
  {
    echo "Requested inventory scope: $MAS_INSTANCES"
    printf "%-12s %-36s" INSTANCE NAMESPACES
    for w in "${WORKERS[@]}"; do printf " %-10s" "$w"; done
    printf " %-8s\n" OTHER

    local suites inst ns row nsp pnode
    if [[ "$MAS_INSTANCES" == "auto" ]]; then
      mapfile -t suites < <(oc get suite -A -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.namespace}{"\n"}{end}' 2>/dev/null)
    else
      suites=(); IFS=',' read -ra reqs <<<"$MAS_INSTANCES"
      for inst in "${reqs[@]}"; do
        ns="$(oc get suite -A -o jsonpath="{range .items[?(@.metadata.name=='$inst')]}{.metadata.namespace}{'\n'}{end}" 2>/dev/null | head -1)"
        [[ -n "$ns" ]] && suites+=("$inst|$ns") || warn "MAS instance '$inst' not discovered"
      done
    fi
    for row in "${suites[@]}"; do
      inst="${row%%|*}"
      mapfile -t ins_ns < <(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E "^mas-${inst}-(core|manage)$" || true)
      declare -A C=(); for w in "${WORKERS[@]}"; do C["$w"]=0; done; C[other]=0
      for nsp in "${ins_ns[@]}"; do
        while read -r pnode; do
          [[ -z "$pnode" ]] && continue
          [[ -n "${C[$pnode]+x}" ]] && ((C["$pnode"]+=1)) || ((C[other]+=1))
        done < <(oc get pods -n "$nsp" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
      done
      printf "%-12s %-36s" "$inst" "${ins_ns[*]:-not-found}"
      for w in "${WORKERS[@]}"; do printf " %-10s" "${C[$w]}"; done
      printf " %-8s\n" "${C[other]}"
    done
  } | tee "$out"
}

validate_placement_plans(){
  ((${#PLANS[@]}==0)) && return 0
  section "GLOBAL PLACEMENT PLAN VALIDATION"
  local report="$RUN_DIR/reports/placement-plan.txt" plan inst nodes n owner
  declare -A OWN=()
  : >"$report"
  for plan in "${PLANS[@]}"; do
    [[ "$plan" == *=* ]] || die "Invalid --placement-plan '$plan'; expected instance=node1,node2"
    inst="${plan%%=*}"; nodes="${plan#*=}"
    [[ -n "$inst" && -n "$nodes" ]] || die "Invalid placement plan: $plan"
    IFS=',' read -ra PN <<<"$nodes"
    echo "$inst -> $nodes" | tee -a "$report"
    ((${#PN[@]}==1)) && warn "$inst has a single eligible worker (${PN[0]}). Node drain/failure can make required-affinity workloads unschedulable."
    for n in "${PN[@]}"; do
      oc get node "$n" >/dev/null || die "Placement-plan node does not exist: $n"
      if [[ -n "${OWN[$n]+x}" && "${OWN[$n]}" != "$inst" ]]; then
        die "Worker $n is assigned to both ${OWN[$n]} and $inst"
      fi
      OWN["$n"]="$inst"
    done
  done
  info "Global placement plan validation PASS"
}

precheck_target_labels(){
  section "TARGET NODE LABEL PRECHECK - READ ONLY"
  local n cur
  for n in "${NODES[@]}"; do
    oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" >/dev/null || die "node $n missing"
    cur="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" -o "jsonpath={.metadata.labels.${LABEL_KEY}}" 2>/dev/null || true)"
    if [[ "$cur" == "$LABEL_VALUE" ]]; then
      info "$n already has $LABEL_KEY=$LABEL_VALUE"
    elif [[ -z "$cur" ]]; then
      $AUTO_LABEL || die "$n lacks $LABEL_KEY=$LABEL_VALUE and automatic labeling is disabled"
      info "[PLAN] $n requires $LABEL_KEY=$LABEL_VALUE; label will be applied only after confirmation"
    else
      die "$n already has $LABEL_KEY=$cur; refusing to overwrite with $LABEL_VALUE"
    fi
  done
}

apply_target_labels(){
  (has_component mas || has_component sls || has_component mongodb || has_component facilities) || return 0
  section "APPLYING TARGET NODE LABELS"
  local n cur
  for n in "${NODES[@]}"; do
    cur="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" -o "jsonpath={.metadata.labels.${LABEL_KEY}}" 2>/dev/null || true)"
    if [[ "$cur" == "$LABEL_VALUE" ]]; then
      info "$n already has $LABEL_KEY=$LABEL_VALUE"
    elif [[ -z "$cur" ]]; then
      $AUTO_LABEL || die "$n lacks $LABEL_KEY=$LABEL_VALUE and automatic labeling is disabled"
      if $DRY_RUN; then
        info "DRY RUN: would add $LABEL_KEY=$LABEL_VALUE to $n"
      else
        info "Applying $LABEL_KEY=$LABEL_VALUE to $n"
        oc --request-timeout="$OC_REQUEST_TIMEOUT" label node "$n" "$LABEL_KEY=$LABEL_VALUE"
      fi
    else
      die "$n has conflicting $LABEL_KEY=$cur; refusing overwrite"
    fi
  done
  oc --request-timeout="$OC_REQUEST_TIMEOUT" get nodes "${NODES[@]}" -L "$LABEL_KEY" | tee "$RUN_DIR/reports/node-labels.txt"
}

migration_progress(){
  local phase="${1:-migration}" ns total running pending terminating problem_lines
  section "MIGRATION PROGRESS - $phase"
  echo "Target instance : ${INSTANCE:-N/A}"
  echo "Target workers  : ${ALLOWED_NODES:-N/A}"
  echo "This monitor is read-only."
  for ns in "$CORE_NS" "$MANAGE_NS" "$SLS_NS" "$MONGO_NS"; do
    [[ -n "$ns" ]] || continue
    oc --request-timeout="$OC_REQUEST_TIMEOUT" get ns "$ns" >/dev/null 2>&1 || continue
    total="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    running="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$ns" --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')"
    pending="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$ns" --no-headers 2>/dev/null | awk '$3=="Pending"{c++} END{print c+0}')"
    terminating="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$ns" 2>/dev/null | grep -c Terminating || true)"
    echo
    echo "[CHECKING] $ns : total=$total running=$running pending=$pending terminating=$terminating"
    problem_lines="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$ns" --no-headers 2>/dev/null |
      grep -E 'Pending|Terminating|CrashLoopBackOff|Error|Failed|ImagePullBackOff|ErrImagePull|ContainerCreating|Init:|Unknown|Evicted' || true)"
    if [[ -n "$problem_lines" ]]; then
      echo "$problem_lines"
    else
      echo "Checking $ns - no pod issues currently detected"
    fi
  done
}


# ---------------- Optional Facilities support (V4.2) ----------------
facilities_precheck(){
  has_component facilities || return 0
  section "FACILITIES PRECHECK - READ ONLY"
  oc get ns "$FACILITIES_NS" >/dev/null || die "Facilities namespace not found: $FACILITIES_NS"
  local fapp
  fapp="$(oc get facilitiesapp -n "$FACILITIES_NS" -l "mas.ibm.com/instanceId=$INSTANCE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$fapp" ]] || die "FacilitiesApp not found in $FACILITIES_NS"
  oc get facilitiesworkspace -n "$FACILITIES_NS" -l "mas.ibm.com/instanceId=$INSTANCE" -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' || true
  oc get pods -n "$FACILITIES_NS" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' --sort-by=.metadata.name || true
}
facilities_phase(){
  has_component facilities || return 0
  section "FACILITIES APPLICATION"
  local fapp ws bad
  fapp="$(oc get facilitiesapp -n "$FACILITIES_NS" -l "mas.ibm.com/instanceId=$INSTANCE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$fapp" ]] || die "FacilitiesApp not found in $FACILITIES_NS"
  patch_keys "facilitiesapp-$fapp" facilitiesapp "$fapp" "$FACILITIES_NS" entitymgr-ws usersyncagent
  $DRY_RUN && return 0
  mapfile -t _fws < <(oc get facilitiesworkspace -n "$FACILITIES_NS" -l "mas.ibm.com/instanceId=$INSTANCE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  for ws in "${_fws[@]}"; do
    [[ -n "$ws" ]] || continue
    patch_keys "facilitiesworkspace-$ws" facilitiesworkspace "$ws" "$FACILITIES_NS" appserver multiagents datainit
    wait_for "FacilitiesWorkspace/$ws Ready" bash -c "test \"\$(oc get facilitiesworkspace '$ws' -n '$FACILITIES_NS' -o json | jq -r '[.status.conditions[]?|select(.type==\"Ready\")][0].status // \"False\"')\" = True"
    wait_for "FacilitiesWorkspace/$ws PodTemplatesValid" bash -c "test \"\$(oc get facilitiesworkspace '$ws' -n '$FACILITIES_NS' -o json | jq -r '[.status.conditions[]?|select(.type==\"PodTemplatesValid\")][0].status // \"False\"')\" = True"
  done
  bad="$(oc get pods -n "$FACILITIES_NS" -o json | jq --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" --arg nodes "$ALLOWED_NODES" '($nodes|split(",")) as $allowed | [.items[]|select(.status.phase=="Running")|select((.metadata.name|test("^ibm-mas-facilities-operator|^ibm-truststore-mgr-controller-manager"))|not)|select((.spec.nodeName as $n|($allowed|index($n))==null) or (([.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?|select(.key==$k and .operator=="In" and (.values|index($v)!=null))]|length)==0))]|length')"
  [[ "$bad" == 0 ]] || die "Facilities validation failed: $bad Running application workload(s) outside target pool or missing required affinity"
  info "Facilities application isolation PASS"
}

# ---------------- Optional AppCfg / Graphite support ----------------
# Graphite is owned by AppCfg and is not a Suite podTemplate.  When AppCfg
# exists, is enabled, and the generated graphite deployment exists, merge
# workload affinity into AppCfg.spec.podTemplates using the supported key
# "graphite-configuration".  Existing AppCfg podTemplates are preserved.
discover_appcfg_graphite(){
  APPCFG_NAME=""
  GRAPHITE_ENABLED=false
  has_component mas || return 0

  APPCFG_NAME="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get appcfg -n "$CORE_NS" \
    -l "mas.ibm.com/instanceId=$INSTANCE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -z "$APPCFG_NAME" ]]; then
    info "Optional AppConfig/Graphite: AppCfg not found; skipping"
    return 0
  fi

  local enabled dep
  enabled="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get appcfg "$APPCFG_NAME" -n "$CORE_NS" \
    -o jsonpath='{.spec.config.enabled}' 2>/dev/null || true)"
  dep="${INSTANCE}-graphite-configuration"

  if [[ "$enabled" == "true" ]] && oc --request-timeout="$OC_REQUEST_TIMEOUT" get deployment "$dep" -n "$CORE_NS" >/dev/null 2>&1; then
    GRAPHITE_ENABLED=true
    info "Optional AppConfig/Graphite discovered: AppCfg=$APPCFG_NAME Deployment=$dep"
  else
    info "Optional AppConfig/Graphite not active; skipping (AppCfg=$APPCFG_NAME enabled=${enabled:-unknown})"
  fi
}

backup_appcfg(){
  $GRAPHITE_ENABLED || return 0
  oc --request-timeout="$OC_REQUEST_TIMEOUT" get appcfg "$APPCFG_NAME" -n "$CORE_NS" -o yaml \
    > "$RUN_DIR/backups/appcfg-${APPCFG_NAME}.yaml"
}

patch_appcfg_graphite(){
  $GRAPHITE_ENABLED || return 0
  section "APPCONFIG / GRAPHITE ISOLATION"

  backup_appcfg

  local current merged patchfile
  current="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get appcfg "$APPCFG_NAME" -n "$CORE_NS" -o json)"

  # Merge by podTemplate name. Preserve every existing AppCfg podTemplate.
  # Preserve an existing graphite template's non-affinity fields, but replace
  # its affinity with the required workload-group affinity.
  merged="$(jq -c --arg key "$LABEL_KEY" --arg val "$LABEL_VALUE" '
    (.spec.podTemplates // []) as $pts |
    {
      spec: {
        podTemplates:
          (
            [ $pts[] | select(.name != "graphite-configuration") ] +
            [
              (
                ([ $pts[] | select(.name == "graphite-configuration") ][0] // {name:"graphite-configuration"})
                + {
                    affinity: {
                      nodeAffinity: {
                        requiredDuringSchedulingIgnoredDuringExecution: {
                          nodeSelectorTerms: [
                            {
                              matchExpressions: [
                                {key:$key, operator:"In", values:[$val]}
                              ]
                            }
                          ]
                        }
                      }
                    }
                  }
              )
            ]
          )
      }
    }' <<<"$current")"

  patchfile="$RUN_DIR/patches/appcfg-${APPCFG_NAME}-graphite-affinity.json"
  printf '%s\n' "$merged" | jq . > "$patchfile"

  if $DRY_RUN; then
    info "DRY RUN: would patch AppCfg $APPCFG_NAME for graphite-configuration"
    cat "$patchfile"
    return 0
  fi

  info "Patching supported AppCfg podTemplate: graphite-configuration"
  oc --request-timeout="$OC_REQUEST_TIMEOUT" patch appcfg "$APPCFG_NAME" -n "$CORE_NS" \
    --type=merge --patch-file "$patchfile"

  wait_for "AppCfg $APPCFG_NAME Ready" \
    bash -c "oc --request-timeout='$OC_REQUEST_TIMEOUT' get appcfg '$APPCFG_NAME' -n '$CORE_NS' -o json | jq -e '.status.conditions[]? | select(.type==\"Ready\" and .status==\"True\")'"

  info "Waiting for Graphite deployment rollout"
  oc --request-timeout="$OC_REQUEST_TIMEOUT" rollout status deployment/"${INSTANCE}-graphite-configuration" \
    -n "$CORE_NS" --timeout="${TIMEOUT}s"

  migration_progress "AppConfig / Graphite"
}

validate_appcfg_graphite(){
  $GRAPHITE_ENABLED || {
    info "AppConfig / Graphite validation: N/A (optional component not active)"
    return 0
  }

  local dep="${INSTANCE}-graphite-configuration"
  local bad=0 total=0 pod node phase
  while IFS='|' read -r pod phase node; do
    [[ -n "$pod" ]] || continue
    ((total+=1))
    if [[ "$phase" != "Running" ]] || ! node_allowed "$node"; then
      ((bad+=1))
      warn "Graphite violation: pod=$pod phase=$phase node=${node:-<none>}"
    fi
  done < <(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$CORE_NS" \
    -l "app=$dep" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)

  if (( total == 0 )); then
    warn "Graphite deployment exists but no Graphite pod was found"
    return 1
  fi
  if (( bad > 0 )); then
    warn "AppConfig / Graphite isolation FAIL: $bad/$total pod(s) not Running on target workers"
    return 1
  fi
  info "AppConfig / Graphite isolation PASS: $total pod(s) Running on target workers"
}

confirm_change(){
  $PRECHECK_ONLY && return 0
  $DRY_RUN && return 0
  section "CHANGE CONFIRMATION"
  echo "Target instance : $INSTANCE"
  echo "Core namespace  : $CORE_NS"
  echo "Manage namespace: $MANAGE_NS"
  echo "Target workers  : $ALLOWED_NODES"
  echo "Required label  : $LABEL_KEY=$LABEL_VALUE"
  if $EXTERNAL_DB; then echo "Database        : external (no in-cluster DB2 check)"; else echo "DB2 namespace   : ${DB2_NS:-not supplied}"; fi
  echo "SLS namespace   : ${SLS_NS:-not supplied}"; echo "MongoDB         : ${MONGO_NS:-not supplied}/${MONGO_NAME}"; echo "Backups/health gates/capacity gates: ENABLED"
  if $ASSUME_YES; then info "--yes supplied; proceeding"; return 0; fi
  read -r -p "Proceed with MAS application isolation? Type YES to continue: " ans
  [[ "$ans" == "YES" ]] || die "Change cancelled by user"
}

projected_migration_capacity(){
  section "PROJECTED TARGET CAPACITY"
  local report="$RUN_DIR/reports/projected-capacity.txt"
  local alloc_cpu=0 alloc_mem=0 current_cpu=0 current_mem=0 incoming_cpu=0 incoming_mem=0
  local node ns
  # Reuse kubectl/OpenShift resource-request accounting with Python for quantities.
  for node in "${NODES[@]}"; do
    read -r ca ma < <(oc get node "$node" -o json | python3 -c '
import json,sys,re
d=json.load(sys.stdin)
def cpu(v): return float(v[:-1])/1000 if str(v).endswith("m") else float(v)
def mem(v):
 v=str(v); q=re.match(r"^([0-9.]+)([KMGTE]i?|)$",v); n=float(q.group(1));u=q.group(2)
 f={"":1,"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4,"K":1000,"M":1000**2,"G":1000**3,"T":1000**4}.get(u,1)
 return n*f/1024**2
print(cpu(d["status"]["allocatable"]["cpu"]),mem(d["status"]["allocatable"]["memory"]))')
    alloc_cpu="$(python3 -c "print(float('$alloc_cpu')+float('$ca'))")"
    alloc_mem="$(python3 -c "print(float('$alloc_mem')+float('$ma'))")"
  done

  # Current requests already assigned to target nodes, cluster-wide.
  for node in "${NODES[@]}"; do
    read -r c m < <(oc get pods -A --field-selector "spec.nodeName=$node" -o json | python3 -c '
import json,sys,re
d=json.load(sys.stdin)
def cpu(v):
 v=str(v or "0"); return float(v[:-1])/1000 if v.endswith("m") else float(v)
def mem(v):
 v=str(v or "0"); q=re.match(r"^([0-9.]+)([KMGTE]i?|)$",v)
 if not q:return 0.0
 n=float(q.group(1));u=q.group(2);f={"":1,"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4,"K":1000,"M":1000**2,"G":1000**3,"T":1000**4}.get(u,1)
 return n*f/1024**2
c=m=0.0
for p in d.get("items",[]):
 if p.get("status",{}).get("phase") in ("Succeeded","Failed"):continue
 for x in p.get("spec",{}).get("containers",[]):
  r=x.get("resources",{}).get("requests",{});c+=cpu(r.get("cpu","0"));m+=mem(r.get("memory","0"))
print(c,m)')
    current_cpu="$(python3 -c "print(float('$current_cpu')+float('$c'))")"
    current_mem="$(python3 -c "print(float('$current_mem')+float('$m'))")"
  done

  # Incoming requests: running pods from the target MAS core/manage namespaces currently outside target nodes.
  for ns in "$CORE_NS" "$MANAGE_NS"; do
    read -r c m < <(oc get pods -n "$ns" -o json | ALLOWED="$ALLOWED_NODES" python3 -c '
import json,sys,re,os
d=json.load(sys.stdin); allowed=set(os.environ["ALLOWED"].split(","))
def cpu(v):
 v=str(v or "0"); return float(v[:-1])/1000 if v.endswith("m") else float(v)
def mem(v):
 v=str(v or "0"); q=re.match(r"^([0-9.]+)([KMGTE]i?|)$",v)
 if not q:return 0.0
 n=float(q.group(1));u=q.group(2);f={"":1,"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4,"K":1000,"M":1000**2,"G":1000**3,"T":1000**4}.get(u,1)
 return n*f/1024**2
c=m=0.0
for p in d.get("items",[]):
 if p.get("status",{}).get("phase")!="Running" or p.get("spec",{}).get("nodeName") in allowed:continue
 # Exclude OLM MAS operators from application-migration projection.
 name=p.get("metadata",{}).get("name","")
 if name.startswith("ibm-mas-operator-") or name.startswith("ibm-mas-manage-operator-"):continue
 for x in p.get("spec",{}).get("containers",[]):
  r=x.get("resources",{}).get("requests",{});c+=cpu(r.get("cpu","0"));m+=mem(r.get("memory","0"))
print(c,m)')
    incoming_cpu="$(python3 -c "print(float('$incoming_cpu')+float('$c'))")"
    incoming_mem="$(python3 -c "print(float('$incoming_mem')+float('$m'))")"
  done

  local projected_cpu projected_mem cpu_pct mem_pct fail=0
  projected_cpu="$(python3 -c "print(float('$current_cpu')+float('$incoming_cpu'))")"
  projected_mem="$(python3 -c "print(float('$current_mem')+float('$incoming_mem'))")"
  cpu_pct="$(python3 -c "print(round((float('$alloc_cpu')-float('$projected_cpu'))/float('$alloc_cpu')*100,1))")"
  mem_pct="$(python3 -c "print(round((float('$alloc_mem')-float('$projected_mem'))/float('$alloc_mem')*100,1))")"
  {
    echo "Target MAS instance                : $INSTANCE"
    echo "Target nodes                       : $ALLOWED_NODES"
    printf "Combined allocatable CPU           : %.2f cores\n" "$alloc_cpu"
    printf "Current target-node CPU requests   : %.2f cores\n" "$current_cpu"
    printf "Incoming EAM CPU requests          : %.2f cores\n" "$incoming_cpu"
    printf "Projected CPU headroom             : %.1f%%\n" "$cpu_pct"
    printf "Combined allocatable memory        : %.0f MiB\n" "$alloc_mem"
    printf "Current target-node memory requests: %.0f MiB\n" "$current_mem"
    printf "Incoming EAM memory requests       : %.0f MiB\n" "$incoming_mem"
    printf "Projected memory headroom          : %.1f%%\n" "$mem_pct"
    echo "Note: projection excludes OLM MAS operators and completed pods."
    echo "Note: rolling updates can temporarily require old + new replicas."
  } | tee "$report"
  python3 -c "import sys;sys.exit(0 if float('$cpu_pct') >= float('$MIN_CPU_HEADROOM_PCT') else 1)" || fail=1
  python3 -c "import sys;sys.exit(0 if float('$mem_pct') >= float('$MIN_MEM_HEADROOM_PCT') else 1)" || fail=1
  ((fail==0)) || die "Projected migration capacity gate FAILED. Review $report"
  info "Projected migration capacity gate PASS"
}

capacity_precheck(){
  section "CAPACITY / SCHEDULING PRECHECK"
  info "[PROGRESS] Starting read-only capacity and scheduling checks"
  local report="$RUN_DIR/reports/capacity-precheck.txt"
  local tmp="$RUN_DIR/reports/.capacity.tsv"
  : >"$tmp"
  {
    echo "Target nodes: $ALLOWED_NODES"
    echo "Thresholds: CPU headroom >= ${MIN_CPU_HEADROOM_PCT}% ; Memory headroom >= ${MIN_MEM_HEADROOM_PCT}%"
    if $EXTERNAL_DB; then
      echo "Database: external (DB2 check skipped)"
    else
      echo "DB2 namespace: ${DB2_NS:-not supplied (optional)}"
    fi
    echo
    printf "%-18s %12s %12s %10s %14s %14s %10s\n" NODE CPU_ALLOC CPU_REQ CPU_FREE% MEM_ALLOC_Mi MEM_REQ_Mi MEM_FREE%
  } | tee "$report"

  local fail=0 node cpuA cpuR memA memR cpuFree memFree
  for node in "${NODES[@]}"; do
    info "[PROGRESS] Reading allocatable capacity and current pod requests for $node"
    # Kubernetes quantities are normalized by jq: CPU to cores, memory to bytes.
    cpuA="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$node" -o json | jq -r '.status.allocatable.cpu')"
    memA="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$node" -o json | jq -r '.status.allocatable.memory')"
    # Sum scheduler requests for all non-terminal pods already assigned to the node.
    read -r cpuR memR < <(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -A --field-selector "spec.nodeName=$node" -o json | python3 -c '
import json,sys,re
d=json.load(sys.stdin)
def cpu(v):
 v=str(v or "0")
 if v.endswith("m"): return float(v[:-1])/1000
 return float(v)
def mem(v):
 v=str(v or "0"); m=re.match(r"^([0-9.]+)([KMGTE]i?|)$",v)
 if not m: return 0.0
 n=float(m.group(1)); u=m.group(2)
 f={"":1,"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4,"K":1000,"M":1000**2,"G":1000**3,"T":1000**4}.get(u,1)
 return n*f/1024**2
c=mm=0.0
for p in d.get("items",[]):
 if p.get("status",{}).get("phase") in ("Succeeded","Failed"): continue
 cs=p.get("spec",{}).get("containers",[])
 # scheduler semantics: sum regular containers; init-container nuance is intentionally not modeled here.
 c+=sum(cpu(x.get("resources",{}).get("requests",{}).get("cpu","0")) for x in cs)
 mm+=sum(mem(x.get("resources",{}).get("requests",{}).get("memory","0")) for x in cs)
print(c,mm)')
    # Convert allocatable values using a tiny Python quantity parser.
    read -r cpuAC memAM < <(python3 - "$cpuA" "$memA" <<'PY'
import sys,re
c,m=sys.argv[1:]
def cpu(v): return float(v[:-1])/1000 if v.endswith("m") else float(v)
def mem(v):
 q=re.match(r"^([0-9.]+)([KMGTE]i?|)$",v); n=float(q.group(1));u=q.group(2)
 f={"":1,"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4,"K":1000,"M":1000**2,"G":1000**3,"T":1000**4}.get(u,1)
 return n*f/1024**2
print(cpu(c),mem(m))
PY
)
    cpuFree="$(python3 -c "print(round(max(0,(float('$cpuAC')-float('$cpuR'))/float('$cpuAC')*100),1))")"
    memFree="$(python3 -c "print(round(max(0,(float('$memAM')-float('$memR'))/float('$memAM')*100),1))")"
    printf "%-18s %12.2f %12.2f %9s%% %14.0f %14.0f %9s%%\n" "$node" "$cpuAC" "$cpuR" "$cpuFree" "$memAM" "$memR" "$memFree" | tee -a "$report"
    info "[PROGRESS] Capacity calculation completed for $node"
    python3 -c "import sys;sys.exit(0 if float('$cpuFree') >= float('$MIN_CPU_HEADROOM_PCT') else 1)" || fail=1
    python3 -c "import sys;sys.exit(0 if float('$memFree') >= float('$MIN_MEM_HEADROOM_PCT') else 1)" || fail=1
  done

  info "[PROGRESS] Reading current MAS Core/Manage workload placement"
  echo | tee -a "$report"
  echo "Current EAM workload requests (informational; some are already on target nodes):" | tee -a "$report"
  for ns in "$CORE_NS" "$MANAGE_NS"; do
    oc get pods -n "$ns" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' --no-headers | tee -a "$report"
  done

  if [[ -n "$DB2_NS" ]]; then
    if oc get ns "$DB2_NS" >/dev/null 2>&1; then
      echo | tee -a "$report"; echo "Optional DB2 placement ($DB2_NS):" | tee -a "$report"
      oc get pods -n "$DB2_NS" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' --sort-by=.metadata.name | tee -a "$report"
      oc get db2ucluster -n "$DB2_NS" 2>/dev/null | tee -a "$report" || true
    else
      warn "Optional DB2 namespace '$DB2_NS' does not exist; continuing because DB2 is optional."
    fi
  fi

  info "[PROGRESS] Checking recent FailedScheduling events"
  echo | tee -a "$report"; echo "Recent FailedScheduling events:" | tee -a "$report"
  oc get events -A --field-selector reason=FailedScheduling --sort-by=.lastTimestamp 2>/dev/null | tail -20 | tee -a "$report" || true

  info "[PROGRESS] Checking current node metrics (informational)"
  if command -v oc >/dev/null && oc --request-timeout="$OC_REQUEST_TIMEOUT" adm top nodes >/dev/null 2>&1; then
    echo | tee -a "$report"; echo "Current metrics (informational, not scheduler capacity):" | tee -a "$report"
    oc --request-timeout="$OC_REQUEST_TIMEOUT" adm top nodes "${NODES[@]}" 2>/dev/null | tee -a "$report" || true
  fi

  if ((fail)); then
    die "Capacity gate failed: one or more target nodes are below configured request-headroom thresholds. Review $report"
  fi
  info "Capacity gate PASS (request-headroom check). Rolling updates may temporarily need additional capacity."
  info "[PROGRESS] Capacity / scheduling precheck completed"
}


mas_health_gate(){
  local phase="$1"
  local report="$RUN_DIR/reports/health-${phase}.txt"
  local start now bad=0

  info "MAS application health gate: $phase"
  start=$(date +%s)

  while true; do
    bad=0
    : >"$report"

    for ns in "$CORE_NS" "$MANAGE_NS"; do
      echo "Namespace: $ns" >>"$report"

      # Scope deliberately to MAS application pods only. Exclude completed jobs,
      # truststore workers, LTPA jobs, and OLM-managed MAS operators.
      while IFS='|' read -r pod phasev waiting ready node; do
        [[ -z "$pod" ]] && continue
        [[ "$pod" == "${INSTANCE}-"* ]] || continue
        [[ "$pod" =~ truststore-worker|ltpakeygenerator ]] && continue
        [[ "$phasev" == "Succeeded" || "$phasev" == "Failed" ]] && continue

        issue=""
        [[ "$phasev" == "Pending" ]] && issue="Pending"
        [[ "$waiting" =~ CrashLoopBackOff ]] && issue="CrashLoopBackOff"
        [[ "$waiting" =~ ImagePullBackOff|ErrImagePull ]] && issue="ImagePullBackOff"
        [[ "$waiting" =~ ContainerCreating ]] && issue="ContainerCreating"
        [[ "$ready" =~ ^0/ ]] && issue="${issue:-NotReady}"

        if [[ -n "$issue" ]]; then
          printf "%-65s %-18s %-12s %s\n" "$pod" "$issue" "$node" "$ready" >>"$report"
          bad=1
        fi
      done < <(oc get pods -n "$ns" -o json | jq -r '
        .items[] |
        (.status.containerStatuses // []) as $cs |
        [
          .metadata.name,
          (.status.phase // ""),
          ([$cs[]?.state.waiting.reason // empty] | join(",")),
          (([$cs[]? | select(.ready==true)] | length | tostring) + "/" + ([$cs[]?] | length | tostring)),
          (.spec.nodeName // "")
        ] | @tsv' | tr '\t' '|')

      # MAS-owned Deployments/StatefulSets with unavailable replicas.
      while IFS='|' read -r kind name unavailable; do
        [[ -z "$name" ]] && continue
        [[ "$name" == "${INSTANCE}-"* ]] || continue
        [[ "${unavailable:-0}" =~ ^[0-9]+$ ]] || unavailable=0
        if (( unavailable > 0 )); then
          echo "$kind/$name unavailableReplicas=$unavailable" >>"$report"
          bad=1
        fi
      done < <({
        oc get deployment -n "$ns" -o json | jq -r '.items[] | ["Deployment",.metadata.name,(.status.unavailableReplicas // 0)] | @tsv'
        oc get statefulset -n "$ns" -o json | jq -r '.items[] | ["StatefulSet",.metadata.name,((.spec.replicas // 0)-(.status.readyReplicas // 0))] | @tsv'
      } | tr '\t' '|')

      # FailedScheduling only for pods belonging to this MAS instance.
      while IFS='|' read -r obj msg; do
        [[ "$obj" == "${INSTANCE}-"* ]] || continue
        echo "FailedScheduling $obj : $msg" >>"$report"
        bad=1
      done < <(oc get events -n "$ns" --field-selector reason=FailedScheduling -o json 2>/dev/null |
        jq -r '.items[] | [(.involvedObject.name // ""),(.message // "")] | @tsv' | tr '\t' '|')
    done

    if (( bad == 0 )); then
      echo "PASS: No unhealthy MAS application workloads detected for phase $phase" >"$report"
      info "MAS application health gate PASS: $phase"
      return 0
    fi

    now=$(date +%s)
    if (( now - start >= TIMEOUT )); then
      echo "[FAIL] MAS application health gate timed out for phase $phase"
      cat "$report"
      return 1
    fi

    info "MAS workloads are still converging for phase $phase; retrying in ${POLL_INTERVAL}s"
    migration_progress "MAS $phase"
    sleep "$POLL_INTERVAL"
  done
}

sls_phase(){
 [[ -z "$SLS_NS" ]]&&{ info "SLS namespace not supplied; SKIPPED";return;}; section "SLS LICENSESERVICE"; local ls; ls="$(oc get licenseservice -n "$SLS_NS" -o jsonpath='{.items[0].metadata.name}')"; [[ -n "$ls" ]]||die "No LicenseService in $SLS_NS"; if ! $FORCE_REAPPLY && cr_entry_compliant licenseservice "$ls" "$SLS_NS" api-licensing affinity;then compliance_log sls-licenseservice COMPLIANT SKIPPED;else compliance_log sls-licenseservice DRIFT/NEW APPLY;backup licenseservice "$ls" "$SLS_NS" sls-before.yaml;mkpatch "$RUN_DIR/patches/sls.json" "$(entry api-licensing)";patch licenseservice "$ls" "$SLS_NS" "$RUN_DIR/patches/sls.json";fi; $DRY_RUN&&return; wait_for "SLS status" status_has licenseservice "$ls" "$SLS_NS" api-licensing;wait_for "SLS affinity" affinity_ok deployment sls-api-licensing "$SLS_NS";oc rollout status deployment/sls-api-licensing -n "$SLS_NS" --timeout="${TIMEOUT}s"||die "SLS rollout failed"; info "SLS isolation PASS";
}
mongodb_precheck(){
 [[ -z "$MONGO_NS" ]]&&{ info "MongoDB namespace not supplied; SKIPPED";return;}; local ph rd rp ub; ph="$(oc get mongodbcommunity "$MONGO_NAME" -n "$MONGO_NS" -o jsonpath='{.status.phase}')";rd="$(oc get sts "$MONGO_NAME" -n "$MONGO_NS" -o jsonpath='{.status.readyReplicas}')";rd="${rd:-0}";rp="$(oc get sts "$MONGO_NAME" -n "$MONGO_NS" -o jsonpath='{.spec.replicas}')";[[ "$ph" == Running && "$rd" == "$rp" ]]||die "MongoDB precheck failed: $ph $rd/$rp";ub="$(oc get pvc -n "$MONGO_NS" -o json|jq -r '.items[]|select(.status.phase!="Bound")|.metadata.name')";[[ -z "$ub" ]]||die "MongoDB unbound PVC: $ub";info "MongoDB precheck PASS: Running $rd/$rp, PVCs Bound";
}
mongodb_cr_affinity_compliant(){
  oc --request-timeout="$OC_REQUEST_TIMEOUT" get mongodbcommunity "$MONGO_NAME" -n "$MONGO_NS" -o json 2>/dev/null | jq -e \
    --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" '
    any(.spec.statefulSet.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?;
      .key==$k and .operator=="In" and (.values|index($v)!=null))' >/dev/null
}
mongodb_sts_affinity_compliant(){
  oc --request-timeout="$OC_REQUEST_TIMEOUT" get statefulset "$MONGO_NAME" -n "$MONGO_NS" -o json 2>/dev/null | jq -e \
    --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" '
    any(.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?;
      .key==$k and .operator=="In" and (.values|index($v)!=null))' >/dev/null
}
mongodb_placement_compliant(){
  local bad
  bad="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get pods -n "$MONGO_NS" -l "app=${MONGO_NAME}-svc" \
    --field-selector=status.phase=Running \
    -o custom-columns=N:.spec.nodeName --no-headers |
    grep -vE "^($(IFS='|'; echo "${NODES[*]}"))$" || true)"
  [[ -z "$bad" ]]
}
mongodb_configuration_compliant(){
  mongodb_cr_affinity_compliant && mongodb_sts_affinity_compliant
}
mongodb_print_compliance(){
  local cr=NO sts=NO place=NO
  mongodb_cr_affinity_compliant && cr=YES
  mongodb_sts_affinity_compliant && sts=YES
  mongodb_placement_compliant && place=YES
  info "MongoDB desired affinity                 : $LABEL_KEY In [$LABEL_VALUE]"
  info "MongoDB CR affinity compliant           : $cr"
  info "MongoDB StatefulSet affinity compliant  : $sts"
  info "MongoDB pod placement compliant         : $place"
}
mongodb_phase(){
  [[ -z "$MONGO_NS" ]] && return
  section "MONGODB COMMUNITY"
  mongodb_precheck
  mongodb_print_compliance

  if ! $FORCE_REAPPLY && mongodb_configuration_compliant; then
    compliance_log mongodbcommunity COMPLIANT SKIPPED
    info "MongoDB CR + StatefulSet configuration already compliant; skipping patch"
    if mongodb_placement_compliant; then
      info "MongoDB placement already compliant; validation only"
    else
      compliance_log mongodb-placement PLACEMENT_DRIFT VALIDATE
      warn "MongoDB configuration is compliant but pods are outside desired nodes."
      warn "Identical MongoDB CR will NOT be patched. Waiting for placement convergence."
    fi
  else
    compliance_log mongodbcommunity DRIFT/NEW APPLY
    backup mongodbcommunity "$MONGO_NAME" "$MONGO_NS" mongodb-before.yaml
    jq -n --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" \
      '{spec:{statefulSet:{spec:{template:{spec:{affinity:{nodeAffinity:{requiredDuringSchedulingIgnoredDuringExecution:{nodeSelectorTerms:[{matchExpressions:[{key:$k,operator:"In",values:[$v]}]}]}}}}}}}}}' \
      >"$RUN_DIR/patches/mongo.json"
    jq empty "$RUN_DIR/patches/mongo.json" || die "Generated MongoDB patch is invalid JSON"
    info "Generated MongoDB patch:"
    jq . "$RUN_DIR/patches/mongo.json"
    info "Validating MongoDB patch with server-side dry run"
    oc patch mongodbcommunity "$MONGO_NAME" -n "$MONGO_NS" --type=merge \
      --patch-file="$RUN_DIR/patches/mongo.json" --dry-run=server -o name >/dev/null \
      || die "MongoDB server-side dry-run validation failed"
    info "MongoDB server-side dry run PASS"
    if $DRY_RUN; then return; fi
    patch mongodbcommunity "$MONGO_NAME" "$MONGO_NS" "$RUN_DIR/patches/mongo.json"
  fi

  $DRY_RUN && return
  wait_for "MongoDB StatefulSet affinity" mongodb_sts_affinity_compliant

  local good=0 start ph rd rp
  start="$(date +%s)"
  while ((good<MONGO_STABLE_CHECKS)); do
    local mongo_json sts_json
    mongo_json=""
    sts_json=""
    oc_query_retry "MongoDBCommunity/$MONGO_NAME status query"       bash -c "oc --request-timeout='$OC_REQUEST_TIMEOUT' get mongodbcommunity '$MONGO_NAME' -n '$MONGO_NS' -o json > '$RUN_DIR/reports/.mongodbcommunity-status.json'"       || die "MongoDBCommunity status query failed after retry timeout"
    oc_query_retry "StatefulSet/$MONGO_NAME status query"       bash -c "oc --request-timeout='$OC_REQUEST_TIMEOUT' get statefulset '$MONGO_NAME' -n '$MONGO_NS' -o json > '$RUN_DIR/reports/.mongodb-statefulset-status.json'"       || die "MongoDB StatefulSet status query failed after retry timeout"
    mongo_json="$(cat "$RUN_DIR/reports/.mongodbcommunity-status.json")"
    sts_json="$(cat "$RUN_DIR/reports/.mongodb-statefulset-status.json")"
    ph="$(jq -r '.status.phase // ""' <<<"$mongo_json")"
    rd="$(jq -r '.status.readyReplicas // 0' <<<"$sts_json")"
    rp="$(jq -r '.spec.replicas // 0' <<<"$sts_json")"
    if [[ "$ph" == Running && "$rd" == "$rp" ]] && mongodb_sts_affinity_compliant && mongodb_placement_compliant; then
      ((good+=1)); info "MongoDB stable $good/$MONGO_STABLE_CHECKS"
    else
      good=0
      info "MongoDB reconciling: phase=$ph ready=$rd/$rp placement=$(mongodb_placement_compliant && echo OK || echo DRIFT)"
      migration_progress "MongoDB"
    fi
    ((good>=MONGO_STABLE_CHECKS)) && break
    (( $(date +%s)-start < TIMEOUT )) || die "MongoDB stabilization/placement timeout"
    sleep "$POLL_INTERVAL"
  done
  info "MongoDB isolation PASS"
}
associated_report(){ section "ASSOCIATED SLS / MONGODB";[[ -n "$SLS_NS" ]]&&oc get pods -n "$SLS_NS" -o wide||echo "SLS: not supplied";[[ -n "$MONGO_NS" ]]&&oc get pods -n "$MONGO_NS" -o wide||echo "MongoDB: not supplied"; }

# ---------- v3.1.2 global component helpers ----------
db2_allowed_json(){ printf '%s\n' "${DB2_NODES[@]}" | jq -R . | jq -s .; }

ensure_db2_labels(){
  has_component db2 || return 0
  section "DB2 TARGET NODE LABEL PRECHECK - READ ONLY"
  local n cur
  for n in "${DB2_NODES[@]}"; do
    oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" >/dev/null || die "DB2 target node not found: $n"
    cur="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" -o jsonpath="{.metadata.labels.${DB2_LABEL_KEY}}" 2>/dev/null || true)"
    if [[ "$cur" == "$DB2_LABEL_VALUE" ]]; then
      info "$n already has $DB2_LABEL_KEY=$DB2_LABEL_VALUE"
    elif [[ -z "$cur" ]]; then
      $AUTO_LABEL || die "$n lacks $DB2_LABEL_KEY=$DB2_LABEL_VALUE"
      info "[PLAN] $n requires $DB2_LABEL_KEY=$DB2_LABEL_VALUE; label will be applied only after confirmation"
    else
      die "$n has conflicting $DB2_LABEL_KEY=$cur; refusing overwrite"
    fi
  done
}
apply_db2_labels(){
  has_component db2 || return 0
  section "APPLYING DB2 TARGET NODE LABELS"
  local n cur
  for n in "${DB2_NODES[@]}"; do
    cur="$(oc --request-timeout="$OC_REQUEST_TIMEOUT" get node "$n" -o jsonpath="{.metadata.labels.${DB2_LABEL_KEY}}" 2>/dev/null || true)"
    if [[ "$cur" == "$DB2_LABEL_VALUE" ]]; then
      info "$n already has $DB2_LABEL_KEY=$DB2_LABEL_VALUE"
    elif [[ -z "$cur" ]]; then
      $AUTO_LABEL || die "$n lacks $DB2_LABEL_KEY=$DB2_LABEL_VALUE"
      if $DRY_RUN; then
        info "DRY RUN: would add $DB2_LABEL_KEY=$DB2_LABEL_VALUE to $n"
      else
        oc --request-timeout="$OC_REQUEST_TIMEOUT" label node "$n" "$DB2_LABEL_KEY=$DB2_LABEL_VALUE"
      fi
    else
      die "$n has conflicting $DB2_LABEL_KEY=$cur; refusing overwrite"
    fi
  done
  oc --request-timeout="$OC_REQUEST_TIMEOUT" get nodes "${DB2_NODES[@]}" -L "$DB2_LABEL_KEY"
}

db2_cluster_healthy(){
  local db="$1" st mt
  st="$(oc get db2ucluster "$db" -n "$DB2_NS" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  mt="$(oc get db2ucluster "$db" -n "$DB2_NS" -o jsonpath='{.status.maintenanceState}' 2>/dev/null || true)"
  [[ "$st" == "Ready" && "$mt" == "None" ]]
}

db2_cluster_compliant(){
  oc get db2ucluster "$1" -n "$DB2_NS" -o json | jq -e \
    --arg k "$DB2_LABEL_KEY" --arg v "$DB2_LABEL_VALUE" '
    any(.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?;
      .key==$k and .operator=="In" and (.values|index($v)!=null))' >/dev/null
}

db2_cluster_placement_ok(){
  local db="$1" bad
  bad="$(oc get pods -n "$DB2_NS" --field-selector=status.phase=Running -o json |
    jq -r --arg p "c-${db}-" --argjson allowed "$(db2_allowed_json)" '
      .items[]
      | select(.metadata.name|startswith($p))
      | select((.metadata.name|contains("-db2u-")) or
               (.metadata.name|contains("-etcd-")) or
               (.metadata.name|contains("-ldap-")))
      | select((.spec.nodeName as $n | $allowed | index($n)) == null)
      | "\(.metadata.name) \(.spec.nodeName)"')"
  [[ -z "$bad" ]]
}

db2_stable(){
  local db="$1" good=0 start now
  start="$(date +%s)"
  while (( good < DB2_STABLE_CHECKS )); do
    if db2_cluster_healthy "$db" && db2_cluster_placement_ok "$db"; then
      ((good+=1))
      info "$db stable check $good/$DB2_STABLE_CHECKS PASS"
    else
      good=0
      info "$db reconciling"
    fi
    (( good >= DB2_STABLE_CHECKS )) && return 0
    now="$(date +%s)"
    (( now-start < TIMEOUT )) || return 1
    sleep "$POLL_INTERVAL"
  done
}

db2_precheck(){
  has_component db2 || return 0
  section "DB2U PRECHECK - IBM MAS MANAGE ONLY"
  oc get ns "$DB2_NS" >/dev/null || die "DB2 namespace not found: $DB2_NS"
  mapfile -t DB2_CLUSTERS < <(
    oc get db2ucluster -n "$DB2_NS" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )
  ((${#DB2_CLUSTERS[@]})) || die "No Db2uCluster found in $DB2_NS"
  info "V4.2 DB2 scope: IBM MAS Manage DB2U only; Monitor/Predict excluded."
  printf 'Discovered Db2uClusters:\n'
  printf '  %s\n' "${DB2_CLUSTERS[@]}"
  local db bad
  for db in "${DB2_CLUSTERS[@]}"; do
    db2_cluster_healthy "$db" || die "Db2uCluster/$db is not Ready with Maintenance=None"
  done
  bad="$(oc get pvc -n "$DB2_NS" -o json |
    jq -r '.items[] | select(.status.phase!="Bound") | .metadata.name')"
  [[ -z "$bad" ]] || die "DB2U namespace has unbound PVC(s): $bad"
  oc get subscription db2u-operator -n "$DB2_NS" >/dev/null \
    || die "Subscription/db2u-operator not found in $DB2_NS"
  info "DB2U precheck PASS"
}

db2_subscription_compliant(){
  oc get subscription db2u-operator -n "$DB2_NS" -o json | jq -e \
    --arg k "$DB2_LABEL_KEY" --arg v "$DB2_LABEL_VALUE" '
    any(.spec.config.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?;
      .key==$k and .operator=="In" and (.values|index($v)!=null))' >/dev/null
}

db2_deployment_affinity_ok(){
  local dep="$1"
  oc get deployment "$dep" -n "$DB2_NS" -o json | jq -e \
    --arg k "$DB2_LABEL_KEY" --arg v "$DB2_LABEL_VALUE" '
    any(.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?;
      .key==$k and .operator=="In" and (.values|index($v)!=null))' >/dev/null
}

db2_operator_placement_ok(){
  local bad
  bad="$(oc get pods -n "$DB2_NS" --field-selector=status.phase=Running -o json |
    jq -r --argjson allowed "$(db2_allowed_json)" '
      .items[]
      | select((.metadata.name|startswith("db2u-operator-manager-")) or
               (.metadata.name|startswith("db2u-day2-ops-controller-manager-")))
      | select((.spec.nodeName as $n | $allowed | index($n)) == null)
      | "\(.metadata.name) \(.spec.nodeName)"')"
  [[ -z "$bad" ]]
}

db2_phase(){
  has_component db2 || return 0
  section "DB2U NAMESPACE ISOLATION - IBM MAS MANAGE ONLY"
  db2_precheck

  local db
  local p="$RUN_DIR/patches/db2-cluster-affinity.json"
  local sp="$RUN_DIR/patches/db2-subscription-affinity.json"

  jq -n --arg k "$DB2_LABEL_KEY" --arg v "$DB2_LABEL_VALUE" '
    {spec:{affinity:{nodeAffinity:{requiredDuringSchedulingIgnoredDuringExecution:{
      nodeSelectorTerms:[{matchExpressions:[{key:$k,operator:"In",values:[$v]}]}]
    }}}}}' >"$p"
  jq empty "$p" || die "Generated Db2uCluster affinity patch is invalid JSON"

  for db in "${DB2_CLUSTERS[@]}"; do
    section "DB2UCLUSTER $db"
    if db2_cluster_compliant "$db" && ! $FORCE_REAPPLY; then
      info "Db2uCluster/$db COMPLIANT / SKIPPED"
    else
      backup db2ucluster "$db" "$DB2_NS" "db2ucluster-${db}-before.yaml"
      oc patch db2ucluster "$db" -n "$DB2_NS" --type=merge \
        --patch-file="$p" --dry-run=server -o name >/dev/null \
        || die "Db2uCluster/$db server-side dry run failed"
      info "Db2uCluster/$db server-side dry run PASS"
      $DRY_RUN || oc patch db2ucluster "$db" -n "$DB2_NS" \
        --type=merge --patch-file="$p"
    fi
    $DRY_RUN || db2_stable "$db" \
      || die "Db2uCluster/$db failed to stabilize before timeout"
  done

  section "DB2U OPERATOR SUBSCRIPTION"
  jq -n --arg k "$DB2_LABEL_KEY" --arg v "$DB2_LABEL_VALUE" '
    {spec:{config:{affinity:{nodeAffinity:{requiredDuringSchedulingIgnoredDuringExecution:{
      nodeSelectorTerms:[{matchExpressions:[{key:$k,operator:"In",values:[$v]}]}]
    }}}}}}' >"$sp"
  jq empty "$sp" || die "Generated DB2U Subscription affinity patch is invalid JSON"

  if db2_subscription_compliant && ! $FORCE_REAPPLY; then
    info "Subscription/db2u-operator COMPLIANT / SKIPPED"
  else
    backup subscription db2u-operator "$DB2_NS" db2u-subscription-before.yaml
    oc patch subscription db2u-operator -n "$DB2_NS" --type=merge \
      --patch-file="$sp" --dry-run=server -o name >/dev/null \
      || die "Subscription/db2u-operator server-side dry run failed"
    info "Subscription/db2u-operator server-side dry run PASS"
    $DRY_RUN || oc patch subscription db2u-operator -n "$DB2_NS" \
      --type=merge --patch-file="$sp"
  fi

  if ! $DRY_RUN; then
    wait_for "DB2U operator affinity" \
      db2_deployment_affinity_ok db2u-operator-manager
    wait_for "DB2U day2 operator affinity" \
      db2_deployment_affinity_ok db2u-day2-ops-controller-manager
    oc rollout status deployment/db2u-operator-manager -n "$DB2_NS" \
      --timeout="${TIMEOUT}s" || die "DB2U operator rollout failed"
    oc rollout status deployment/db2u-day2-ops-controller-manager -n "$DB2_NS" \
      --timeout="${TIMEOUT}s" || die "DB2U day2 operator rollout failed"
    wait_for "DB2U operator placement" db2_operator_placement_ok
  fi
  info "DB2U namespace isolation PASS"
}

olm_subscription_affinity(){
  local sub="$1" ns="$2" dep="$3" tag="$4"
  local p="$RUN_DIR/patches/${tag}-subscription-affinity.json"
  oc get subscription "$sub" -n "$ns" >/dev/null \
    || { warn "Subscription/$sub not found in $ns; skipping"; return 0; }

  if oc get subscription "$sub" -n "$ns" -o json | jq -e \
      --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" '
      any(.spec.config.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?;
        .key==$k and .operator=="In" and (.values|index($v)!=null))' >/dev/null \
      && ! $FORCE_REAPPLY; then
    info "Subscription/$sub COMPLIANT / SKIPPED"
  else
    backup subscription "$sub" "$ns" "${tag}-subscription-before.yaml"
    jq -n --arg k "$LABEL_KEY" --arg v "$LABEL_VALUE" '
      {spec:{config:{affinity:{nodeAffinity:{requiredDuringSchedulingIgnoredDuringExecution:{
        nodeSelectorTerms:[{matchExpressions:[{key:$k,operator:"In",values:[$v]}]}]
      }}}}}}' >"$p"
    jq empty "$p" || die "Generated Subscription/$sub patch is invalid JSON"
    oc patch subscription "$sub" -n "$ns" --type=merge \
      --patch-file="$p" --dry-run=server -o name >/dev/null \
      || die "Subscription/$sub server-side dry run failed"
    info "Subscription/$sub server-side dry run PASS"
    $DRY_RUN || oc patch subscription "$sub" -n "$ns" \
      --type=merge --patch-file="$p"
  fi

  if ! $DRY_RUN; then
    wait_for "$dep affinity" affinity_ok deployment "$dep" "$ns"
    oc rollout status deployment/"$dep" -n "$ns" --timeout="${TIMEOUT}s" \
      || die "$dep rollout failed"
  fi
}
# ---------- end v3.1.2 global component helpers ----------

section PRECHECK
command -v oc>/dev/null||die "oc missing";command -v jq>/dev/null||die "jq missing";oc whoami>/dev/null||die "oc login required"

# Component-independent path when MAS is not selected.
if ! has_component mas; then
  # Common target is needed only for SLS/MongoDB.
  if has_component sls || has_component mongodb || has_component facilities; then
    precheck_target_labels
  fi

  has_component db2 && ensure_db2_labels
  has_component sls && oc get ns "$SLS_NS" >/dev/null
  has_component mongodb && { oc get ns "$MONGO_NS" >/dev/null; mongodb_precheck; }
  has_component facilities && facilities_precheck
  has_component db2 && db2_precheck

  section "SELECTED COMPONENT INVENTORY"
  has_component sls && oc get pods -n "$SLS_NS" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' || true
  has_component mongodb && oc get pods -n "$MONGO_NS" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' || true
  has_component facilities && oc get pods -n "$FACILITIES_NS" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' || true
  has_component db2 && oc get pods -n "$DB2_NS" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' || true

  if $PRECHECK_ONLY; then section "PRECHECK ONLY COMPLETE"; echo "No changes made. $RUN_DIR"; exit 0; fi

  if ! $ASSUME_YES && ! $DRY_RUN; then
    section "CHANGE CONFIRMATION"
    echo "Components: $COMPONENTS"
    (has_component sls || has_component mongodb) && { echo "Application target: $ALLOWED_NODES"; echo "Application label: $LABEL_KEY=$LABEL_VALUE"; }
    has_component db2 && { echo "DB2U namespace: $DB2_NS"; echo "DB2 target: $DB2_ALLOWED_NODES"; echo "DB2 label: $DB2_LABEL_KEY=$DB2_LABEL_VALUE"; echo "DB2 scope: IBM MAS Manage only (Monitor/Predict excluded)"; }
    read -r -p "Proceed? Type YES to continue: " ans; [[ "$ans" == YES ]] || die "Cancelled"
  fi

  : >"$RUN_DIR/reports/compliance.txt"
  has_component sls && sls_phase
  has_component mongodb && mongodb_phase
  has_component facilities && facilities_phase
  has_component db2 && db2_phase

  section "COMPONENT RESULTS"
  has_component mas && echo "MAS       : PASS" || echo "MAS       : NOT SELECTED"
  has_component sls && echo "SLS       : PASS" || echo "SLS       : NOT SELECTED"
  has_component mongodb && echo "MongoDB   : PASS" || echo "MongoDB   : NOT SELECTED"
  has_component db2 && echo "DB2U      : PASS" || echo "DB2U      : NOT SELECTED"
  echo "OVERALL   : PASS"
  echo
  echo "PASS = selected component(s) reached desired placement and health gates."
  echo "WARNING = isolation succeeded but non-blocking supporting/operator exceptions need review."
  echo "FAIL = a selected component failed health, scheduling, placement, or timeout validation."
  echo "Run artifacts: $RUN_DIR"
  exit 0
fi

oc get ns "$CORE_NS">/dev/null;oc get ns "$MANAGE_NS">/dev/null
if [[ -z "$WORKSPACE" ]]; then
  mapfile -t _mws < <(oc get manageworkspace -n "$MANAGE_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  if ((${#_mws[@]}==1)); then WORKSPACE="${_mws[0]#${INSTANCE}-}"; info "Auto-discovered Manage workspace: ${_mws[0]} (workspace id=$WORKSPACE)"
  elif ((${#_mws[@]}>1)); then die "Multiple ManageWorkspace CRs found; specify --workspace"
  else die "No ManageWorkspace CR found in $MANAGE_NS"; fi
fi
precheck_target_labels
has_component facilities && facilities_precheck
has_component db2 && ensure_db2_labels
discover_mas_instances
discover_appcfg_graphite
validate_placement_plans
$CAPACITY_PRECHECK && capacity_precheck
$CAPACITY_PRECHECK && projected_migration_capacity
SUITE="$(oc get suite -n "$CORE_NS" -o jsonpath='{.items[0].metadata.name}')"
BAS="$(oc get bascfg -n "$CORE_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null||true)"
CIDP="$(oc get coreidp -n "$CORE_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null||true)"
SLS="$(oc get slscfg -n "$CORE_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null||true)"
MAPP="$(oc get manageapp -n "$MANAGE_NS" -o jsonpath='{.items[0].metadata.name}')"; MWS="${INSTANCE}-${WORKSPACE}"
oc get manageworkspace "$MWS" -n "$MANAGE_NS">/dev/null;oc get managedeployment manage-maxinst -n "$MANAGE_NS">/dev/null
associated_report
has_component mongodb && mongodb_precheck
has_component db2 && db2_precheck
snapshot before
: >"$RUN_DIR/reports/compliance.txt"
confirm_change
$PRECHECK_ONLY&&{ section "PRECHECK ONLY COMPLETE";echo "No changes made. $RUN_DIR";exit 0; }
# V4.1: first cluster mutation happens only after explicit YES.
apply_target_labels
has_component db2 && apply_db2_labels

SUITE_KEYS=(admin-dashboard catalogapi catalogmgr coreapi entitymgr-addons entitymgr-appcfg entitymgr-bascfg entitymgr-coreidp entitymgr-idpcfg entitymgr-jdbccfg entitymgr-kafkacfg entitymgr-mongocfg entitymgr-objectstorage entitymgr-pushnotificationcfg entitymgr-scimcfg entitymgr-slscfg entitymgr-smtpcfg entitymgr-suite entitymgr-watsonstudiocfg entitymgr-ws groupsync-coordinator homepage internalapi ltpakeygenerator mobileapi monagent-mas navigator usersync-coordinator workspace-coordinator)
BAS_KEYS=(accapppoints usage-daily usage-historical adoptionusage-reporter adoptionusageapi milestonesapi)
CIDP_KEYS=(coreidp coreidp-login oidcclientreg); SLS_KEYS=(licensing-mediator licensing-sync)
MAPP_KEYS=(entitymgr-primary-entity entitymgr-appstatus entitymgr-bdi entitymgr-ws entitymgr-acc usersyncagent groupsyncagent ibm-mas-imagestitching-operator healthext-entitymgr-ws ibm-mas-slackproxy-operator aipoptimizationext-entitymgr)

section SUITE;patch_keys suite suite "$SUITE" "$CORE_NS" "${SUITE_KEYS[@]}"; $DRY_RUN || mas_health_gate suite
[[ -n "$BAS" ]]&&{ section BASCFG;patch_keys bascfg bascfg "$BAS" "$CORE_NS" "${BAS_KEYS[@]}"; $DRY_RUN || mas_health_gate bascfg; }
[[ -n "$CIDP" ]]&&{ section COREIDP;patch_keys coreidp coreidp "$CIDP" "$CORE_NS" "${CIDP_KEYS[@]}"; $DRY_RUN || mas_health_gate coreidp; }
if [[ -n "$SLS" ]];then section SLSCFG;patch_keys slscfg slscfg "$SLS" "$CORE_NS" "${SLS_KEYS[@]}"
 if ! $DRY_RUN && oc get cronjob "${INSTANCE}-licensingsync" -n "$CORE_NS">/dev/null 2>&1;then
  k="$(oc get cronjob "${INSTANCE}-licensingsync" -n "$CORE_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key}' 2>/dev/null||true)"
  [[ "$k" == "$LABEL_KEY" ]]||warn "SLS licensing-sync lacks requested affinity; verify version-specific template mapping."
 fi
 $DRY_RUN || mas_health_gate slscfg
fi
section MANAGEAPP;patch_keys manageapp manageapp "$MAPP" "$MANAGE_NS" "${MAPP_KEYS[@]}"; $DRY_RUN || mas_health_gate manageapp

if has_component mas; then
  patch_appcfg_graphite
  validate_appcfg_graphite || true
fi

section "MANAGEWORKSPACE: MONITOR + BUILDS"
WS_CHANGED=true
if ! $FORCE_REAPPLY && cr_entry_compliant manageworkspace "$MWS" "$MANAGE_NS" monitoragent affinity && cr_entry_compliant manageworkspace "$MWS" "$MANAGE_NS" build-config nodeselector;then WS_CHANGED=false;compliance_log manageworkspace COMPLIANT SKIPPED;info "ManageWorkspace already compliant; skipping patch";else compliance_log manageworkspace DRIFT/NEW APPLY;backup manageworkspace "$MWS" "$MANAGE_NS" manageworkspace-before.yaml;mkpatch "$RUN_DIR/patches/manageworkspace.json" "$(entry monitoragent)" "$(nsentry build-config)";patch manageworkspace "$MWS" "$MANAGE_NS" "$RUN_DIR/patches/manageworkspace.json";fi
if ! $DRY_RUN && $WS_CHANGED;then wait_for "workspace monitoragent" status_has manageworkspace "$MWS" "$MANAGE_NS" monitoragent;wait_for "workspace build-config" status_has manageworkspace "$MWS" "$MANAGE_NS" build-config
 oc get deployment "${INSTANCE}-monitoragent" -n "$MANAGE_NS">/dev/null 2>&1&&wait_for "monitoragent affinity" affinity_ok deployment "${INSTANCE}-monitoragent" "$MANAGE_NS"
 for bc in admin-build-config all-build-config;do oc get buildconfig "$bc" -n "$MANAGE_NS">/dev/null 2>&1&&wait_for "$bc selector" selector_ok "$bc";done;fi
if $WS_CHANGED && ! $DRY_RUN;then mas_health_gate manageworkspace;fi

section "MANAGEDEPLOYMENT: MAXINST";patch_keys maxinst managedeployment manage-maxinst "$MANAGE_NS" manage-maxinst
if ! $DRY_RUN;then D="${INSTANCE}-${WORKSPACE}-manage-maxinst";oc get deployment "$D" -n "$MANAGE_NS">/dev/null 2>&1&&wait_for "MAXINST affinity" affinity_ok deployment "$D" "$MANAGE_NS";fi
$DRY_RUN || mas_health_gate maxinst

section MANAGESERVERBUNDLES
mapfile -t BUNDLES < <(oc get manageserverbundle -n "$MANAGE_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
for b in "${BUNDLES[@]}";do [[ -z "$b" ]]&&continue;patch_keys "bundle-$b" manageserverbundle "$b" "$MANAGE_NS" "$b"
 if ! $DRY_RUN;then
  if oc get statefulset "${INSTANCE}-${WORKSPACE}-${b}" -n "$MANAGE_NS">/dev/null 2>&1;then wait_for "$b StatefulSet affinity" affinity_ok statefulset "${INSTANCE}-${WORKSPACE}-${b}" "$MANAGE_NS"
  elif oc get deployment "${INSTANCE}-${WORKSPACE}-${b}" -n "$MANAGE_NS">/dev/null 2>&1;then wait_for "$b Deployment affinity" affinity_ok deployment "${INSTANCE}-${WORKSPACE}-${b}" "$MANAGE_NS";fi
 fi
 $DRY_RUN || mas_health_gate "bundle-$b"
done

section "MAS OLM OPERATORS"
olm_subscription_affinity ibm-mas "$CORE_NS" ibm-mas-operator mas-core-operator
olm_subscription_affinity ibm-mas-manage "$MANAGE_NS" ibm-mas-manage-operator mas-manage-operator

has_component facilities && facilities_phase

$DRY_RUN&&{ section "DRY RUN COMPLETE";echo "$RUN_DIR";exit 0; }
has_component sls && sls_phase
has_component mongodb && mongodb_phase
has_component db2 && db2_phase
snapshot after

section "CONFIGURATION COMPLIANCE SUMMARY"
cat "$RUN_DIR/reports/compliance.txt" || true

section "APPCONFIG / GRAPHITE FINAL VALIDATION"
if has_component mas; then
  if ! validate_appcfg_graphite; then
    echo "AppConfig/Graphite placement violation" >> "$RUN_DIR/reports/exceptions.txt"
  fi
fi

section "FINAL VALIDATION"
FINAL_REPORT="$RUN_DIR/reports/final-validation.txt"
: >"$FINAL_REPORT"
{
 echo "Instance: $INSTANCE"
 echo "Required label: $LABEL_KEY=$LABEL_VALUE"
 echo "Allowed nodes: $ALLOWED_NODES"
 echo
 echo "Build selectors:"
 for bc in admin-build-config all-build-config; do
  if oc get buildconfig "$bc" -n "$MANAGE_NS" >/dev/null 2>&1; then
   printf "%-25s " "$bc"
   oc get buildconfig "$bc" -n "$MANAGE_NS" -o jsonpath='{.spec.nodeSelector}'
   echo
  fi
 done
} | tee -a "$FINAL_REPORT"

app_violations=0
support_warnings=0

for ns in "$CORE_NS" "$MANAGE_NS"; do
 echo | tee -a "$FINAL_REPORT"
 echo "Namespace: $ns" | tee -a "$FINAL_REPORT"
 echo "Target MAS application workloads outside desired nodes:" | tee -a "$FINAL_REPORT"
 app_found=0
 while read -r pod node; do
  [[ -z "${pod:-}" ]] && continue
  [[ "$pod" == "${INSTANCE}-"* ]] || continue
  if [[ ! "$node" =~ ^(${ALLOWED_RE})$ ]]; then
   echo "  [FAIL] $pod  $node" | tee -a "$FINAL_REPORT"
   ((app_violations+=1)); app_found=1
  fi
 done < <(oc get pods -n "$ns" --field-selector=status.phase=Running -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' --no-headers)
 ((app_found==0)) && echo "  NONE" | tee -a "$FINAL_REPORT"

 echo "Non-application/supporting Running workloads outside desired nodes:" | tee -a "$FINAL_REPORT"
 support_found=0
 while read -r pod node; do
  [[ -z "${pod:-}" ]] && continue
  [[ "$pod" == "${INSTANCE}-"* ]] && continue
  if [[ ! "$node" =~ ^(${ALLOWED_RE})$ ]]; then
   echo "  [WARNING] $pod  $node" | tee -a "$FINAL_REPORT"
   ((support_warnings+=1)); support_found=1
  fi
 done < <(oc get pods -n "$ns" --field-selector=status.phase=Running -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' --no-headers)
 ((support_found==0)) && echo "  NONE" | tee -a "$FINAL_REPORT"
done

section "RESULT"
if ((app_violations>0)); then
 OVERALL="FAIL"
 APP_RESULT="FAIL"
elif ((support_warnings>0)); then
 OVERALL="WARNING"
 APP_RESULT="PASS"
else
 OVERALL="PASS"
 APP_RESULT="PASS"
fi

{
 echo "MAS APPLICATION ISOLATION : $APP_RESULT"
 echo "SUPPORTING WORKLOAD CHECK  : $([[ $support_warnings -gt 0 ]] && echo WARNING || echo PASS)"
 echo "OVERALL RESULT             : $OVERALL"
 echo "Application violations     : $app_violations"
 echo "Supporting warnings        : $support_warnings"
 echo
 echo "============================================================"
 echo " RESULT INTERPRETATION"
 echo "============================================================"
 echo "PASS"
 echo "  All targeted MAS application workloads are running on the"
 echo "  desired worker nodes and no relevant supporting exceptions"
 echo "  were detected."
 echo
 echo "WARNING"
 echo "  MAS application workload isolation succeeded, but one or"
 echo "  more non-application/supporting/operator workloads remain"
 echo "  outside the desired worker nodes, or another non-blocking"
 echo "  exception was detected. Review warnings separately."
 echo "  WARNING does not mean the MAS application migration failed."
 echo
 echo "FAIL"
 echo "  One or more targeted MAS application workloads are running"
 echo "  outside the desired nodes, failed scheduling/readiness, or"
 echo "  another blocking validation failed. Stop and investigate."
 echo "============================================================"
 echo "Run artifacts: $RUN_DIR"
} | tee -a "$FINAL_REPORT"

# WARNING is a successful script completion; FAIL returns non-zero.
if [[ "$OVERALL" == "FAIL" ]]; then exit 1; fi
exit 0
