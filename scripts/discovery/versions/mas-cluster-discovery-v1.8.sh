#!/usr/bin/env bash
SCRIPT_START_EPOCH="$(date +%s)"
SCRIPT_START_ISO="$(date -Iseconds)"
# IBM MAS / OpenShift Cluster Discovery & Assessment v1.8
# READ-ONLY: no oc patch/apply/edit/delete/label/scale commands are used.
set -uo pipefail

OUT_DIR=""
REPORT_NAME="cluster-discovery-report"
INCLUDE_ALL_PODS=false
TIMEOUT="${TIMEOUT:-20}"

usage() {
cat <<'EOF'
Usage:
  ./mas-cluster-discovery-v1.8.sh [options]

Options:
  --output-dir DIR       Parent directory for generated report directory
                         Default: current directory
  --report-name NAME     Report directory prefix
                         Default: cluster-discovery-report
  --include-all-pods     Include full all-namespace pod inventory
  -h, --help             Show help

Purpose:
  Read-only discovery of an OpenShift cluster for IBM MAS workload-placement planning.
  Detects:
    - OpenShift nodes, roles, labels, taints and allocatable capacity
    - current node request allocation
    - MAS instance IDs and all MAS application namespaces
    - MAS Suite / ManageWorkspace / ManageApp / server bundles where available
    - MAS OLM Subscriptions and operator pods
    - SLS namespaces, LicenseService and LicenseClient resources
    - MongoDB namespaces, MongoDBCommunity resources, StatefulSets and member placement
    - Db2U presence, Db2uCluster resources, operators and placement
    - storage classes and PVC summaries
    - current MAS/SLS/MongoDB/Db2U workload distribution
    - optional AppConfig/Graphite configuration and placement
    - dynamic Manage runtime topology (ALL/UI/MEA/CRON/REPORT/JMS and non-default workspace patterns)
    - workload ownership and current affinity
    - application/database workloads separated from supporting operators/controllers
    - candidate inputs for the workload-isolation command

This script DOES NOT migrate or modify workloads.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --report-name) REPORT_NAME="$2"; shift 2 ;;
    --include-all-pods) INCLUDE_ALL_PODS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

OUT_DIR="${OUT_DIR:-$PWD}"
RUN_DIR="${OUT_DIR%/}/${REPORT_NAME}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR/raw"
REPORT="$RUN_DIR/REPORT.txt"
SUMMARY="$RUN_DIR/SUMMARY.txt"
COMMAND_INPUTS="$RUN_DIR/COMMAND-INPUTS.txt"
HTML_REPORT="$RUN_DIR/REPORT.html"

exec > >(tee "$REPORT") 2>&1

html_escape() { sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }

section(){ printf '\n============================================================\n %s\n============================================================\n' "$1"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }

command -v oc >/dev/null || { echo "[FAIL] oc command not found"; exit 1; }
command -v jq >/dev/null || { echo "[FAIL] jq command not found"; exit 1; }
command -v python3 >/dev/null || { echo "[FAIL] python3 command not found (required for dynamic architecture SVG)"; exit 1; }

section "OPENSHIFT / MAS CLUSTER DISCOVERY"
echo "Timestamp : $(date -Is 2>/dev/null || date)"
echo "User      : $(oc whoami 2>/dev/null || echo UNKNOWN)"
echo "API       : $(oc whoami --show-server 2>/dev/null || echo UNKNOWN)"
echo "Report dir: $RUN_DIR"

if ! oc whoami >/dev/null 2>&1; then
  echo "[FAIL] No authenticated OpenShift session."
  exit 1
fi

section "CLUSTER VERSION"
oc get clusterversion 2>/dev/null || true
oc get clusterversion -o yaml > "$RUN_DIR/raw/clusterversion.yaml" 2>/dev/null || true

section "NODE INVENTORY"
oc get nodes -o wide
oc get nodes -o json > "$RUN_DIR/raw/nodes.json"

echo
echo "Node labels relevant to placement:"
oc get nodes -L workload-group,node-role.kubernetes.io/worker,node-role.kubernetes.io/infra 2>/dev/null || true

echo
echo "Node taints:"
oc get nodes -o json | jq -r '
 .items[] | [.metadata.name,
   ((.spec.taints // []) | map("\(.key)=\(.value // ""):\(.effect)") | join(","))]
 | @tsv' | column -t 2>/dev/null || true

section "NODE ALLOCATABLE / REQUEST CAPACITY"
printf "%-28s %-12s %-14s %-12s %-14s\n" NODE CPU_ALLOC CPU_REQ MEM_ALLOC MEM_REQ
for n in $(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  cpu_alloc="$(oc get node "$n" -o jsonpath='{.status.allocatable.cpu}')"
  mem_alloc="$(oc get node "$n" -o jsonpath='{.status.allocatable.memory}')"
  req="$(oc get pods -A --field-selector="spec.nodeName=$n,status.phase=Running" -o json | jq -r '
    def cpu_m:
      if . == null then 0
      elif test("m$") then sub("m$";"")|tonumber
      elif test("n$") then (sub("n$";"")|tonumber)/1000000
      elif test("u$") then (sub("u$";"")|tonumber)/1000
      else (tonumber*1000) end;
    def mem_ki:
      if . == null then 0
      elif test("Ki$") then sub("Ki$";"")|tonumber
      elif test("Mi$") then (sub("Mi$";"")|tonumber)*1024
      elif test("Gi$") then (sub("Gi$";"")|tonumber)*1024*1024
      elif test("Ti$") then (sub("Ti$";"")|tonumber)*1024*1024*1024
      else 0 end;
    ([ .items[].spec.containers[]?.resources.requests.cpu // "0" | cpu_m ] | add // 0 | floor) as $cpu |
    ([ .items[].spec.containers[]?.resources.requests.memory // "0" | mem_ki ] | add // 0 | floor) as $mem |
    "\($cpu)\t\($mem)"')"
  cpu_req="${req%%$'\t'*}"
  mem_req="${req#*$'\t'}"
  printf "%-28s %-12s %-14s %-12s %-14s\n" "$n" "$cpu_alloc" "${cpu_req}m" "$mem_alloc" "${mem_req}Ki"
done

section "MAS NAMESPACE DISCOVERY"
oc get ns -o custom-columns='NAME:.metadata.name' --no-headers | grep -E '^mas-' | sort || true

mapfile -t MAS_IDS < <(
  oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
  sed -nE 's/^mas-([^-]+)-core$/\1/p' | sort -u
)

echo
echo "Detected MAS instance IDs:"
if ((${#MAS_IDS[@]})); then printf '  %s\n' "${MAS_IDS[@]}"; else echo "  NONE"; fi

section "MAS INSTANCE SUMMARY"
printf "%-16s %-28s %-28s %-8s %-8s\n" INSTANCE CORE_NS MANAGE_NS CORE MANAGE
for id in "${MAS_IDS[@]}"; do
  c="mas-${id}-core"; m="mas-${id}-manage"
  cexists=NO; mexists=NO
  oc get ns "$c" >/dev/null 2>&1 && cexists=YES
  oc get ns "$m" >/dev/null 2>&1 && mexists=YES
  printf "%-16s %-28s %-28s %-8s %-8s\n" "$id" "$c" "$m" "$cexists" "$mexists"
done

for id in "${MAS_IDS[@]}"; do
  for ns in "mas-${id}-core" "mas-${id}-manage"; do
    oc get ns "$ns" >/dev/null 2>&1 || continue
    section "MAS $id - $ns"
    echo "Running pod placement:"
    oc get pods -n "$ns" --field-selector=status.phase=Running \
      -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[*].ready' \
      --sort-by=.metadata.name || true
    echo
    echo "Running distribution:"
    oc get pods -n "$ns" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
      sed '/^$/d' | sort | uniq -c || true

    echo
    echo "OLM Subscriptions:"
    oc get subscription -n "$ns" 2>/dev/null || true

    if [[ "$ns" == *-core ]]; then
      echo
      echo "Suite CR:"
      oc get suite -n "$ns" 2>/dev/null || true
      echo
      echo "Core configuration CRs:"
      oc get bascfg,coreidpcfg,slscfg -n "$ns" 2>/dev/null || true
    else
      echo
      echo "Manage CRs:"
      oc get manageapp,manageworkspace,managedeployment,manageserverbundle -n "$ns" 2>/dev/null || true
      echo
      echo "BuildConfigs:"
      oc get buildconfig -n "$ns" 2>/dev/null || true
      echo
      echo "Manage PVC / STORAGE:"
      oc get pvc -n "$ns" -o wide 2>/dev/null || true
      echo
      echo "Manage pod -> PVC mounts:"
      oc get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[] as $p | ($p.spec.volumes // [])[]? | select(.persistentVolumeClaim != null) | [$p.metadata.name,$p.status.phase,.persistentVolumeClaim.claimName,($p.spec.nodeName // "")] | @tsv' | column -t 2>/dev/null || true
    fi
  done
done


: >"$RUN_DIR/raw/manage-pvc.tsv"
printf "INSTANCE\tNAMESPACE\tPVC\tSTATUS\tACCESS\tSTORAGECLASS\tCAPACITY\tPV\tVOLUMEMODE\tMOUNTED_BY\tMOUNT_NODES\n" >>"$RUN_DIR/raw/manage-pvc.tsv"
for id in "${MAS_IDS[@]}"; do
 ns="mas-${id}-manage"; oc get ns "$ns" >/dev/null 2>&1 || continue
 while IFS=$'\t' read -r pvc status access sc capacity pv vmode; do
  [[ -z "$pvc" ]] && continue
  mounted="$(oc get pods -n "$ns" -o json | jq -r --arg p "$pvc" '[.items[]|select(any(.spec.volumes[]?;.persistentVolumeClaim.claimName==$p))|.metadata.name]|unique|join("<br>")')"
  nodes="$(oc get pods -n "$ns" -o json | jq -r --arg p "$pvc" '[.items[]|select(any(.spec.volumes[]?;.persistentVolumeClaim.claimName==$p))|.spec.nodeName//empty]|unique|join("<br>")')"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "$ns" "$pvc" "$status" "$access" "$sc" "$capacity" "$pv" "$vmode" "$mounted" "$nodes" >>"$RUN_DIR/raw/manage-pvc.tsv"
 done < <(oc get pvc -n "$ns" -o json | jq -r '.items[]|[.metadata.name,(.status.phase//""),((.spec.accessModes//[])|join(",")),(.spec.storageClassName//""),(.status.capacity.storage//""),(.spec.volumeName//""),(.spec.volumeMode//"Filesystem")]|@tsv')
done

section "SLS DISCOVERY"
mapfile -t SLS_NS < <(
  {
    oc get licenseservice -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null
    oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -Ei '(^|-)sls($|-)'
  } | sed '/^$/d' | sort -u
)
if ((${#SLS_NS[@]})); then
  printf 'Detected SLS namespaces:\n'; printf '  %s\n' "${SLS_NS[@]}"
else
  echo "No SLS namespace/resource detected."
fi
for ns in "${SLS_NS[@]}"; do
  section "SLS - $ns"
  oc get licenseservice -n "$ns" -o wide 2>/dev/null || true
  oc get licenseclient -n "$ns" 2>/dev/null || true
  echo
  oc get pods -n "$ns" \
    -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase,READY:.status.containerStatuses[*].ready' \
    --sort-by=.metadata.name 2>/dev/null || true
done

section "MONGODB DISCOVERY"
mapfile -t MONGO_NS < <(
  {
    oc get mongodbcommunity -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null
    oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -Ei 'mongo'
  } | sed '/^$/d' | sort -u
)
if ((${#MONGO_NS[@]})); then
  printf 'Detected MongoDB namespaces:\n'; printf '  %s\n' "${MONGO_NS[@]}"
else
  echo "No MongoDB Community namespace/resource detected."
fi
for ns in "${MONGO_NS[@]}"; do
  section "MONGODB - $ns"
  oc get mongodbcommunity -n "$ns" 2>/dev/null || true
  oc get statefulset -n "$ns" 2>/dev/null || true
  echo
  oc get pods -n "$ns" \
    -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase,READY:.status.containerStatuses[*].ready' \
    --sort-by=.metadata.name 2>/dev/null || true
  echo
  echo "PVC summary:"
  oc get pvc -n "$ns" 2>/dev/null || true
done

section "DB2U DISCOVERY"
DB2_PRESENT=NO
if oc api-resources --api-group=db2u.databases.ibm.com -o name 2>/dev/null | grep -q '^db2uclusters'; then
  DB2_PRESENT=YES
fi
echo "Db2U API detected: $DB2_PRESENT"
if [[ "$DB2_PRESENT" == YES ]]; then
  oc get db2ucluster -A -o wide 2>/dev/null || true
  mapfile -t DB2_NS < <(oc get db2ucluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)
  for ns in "${DB2_NS[@]}"; do
    [[ -z "$ns" ]] && continue
    section "DB2U - $ns"
    oc get db2ucluster -n "$ns" -o wide 2>/dev/null || true
    oc get subscription -n "$ns" 2>/dev/null | grep -E 'NAME|db2u' || true
    echo
    oc get pods -n "$ns" \
      -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase,READY:.status.containerStatuses[*].ready' \
      --sort-by=.metadata.name 2>/dev/null || true
    echo
    oc get pvc -n "$ns" 2>/dev/null || true
  done
fi

section "STORAGE"
oc get storageclass 2>/dev/null || true

section "CLUSTER-WIDE WORKLOAD COUNTS BY NODE"
oc get pods -A --field-selector=status.phase=Running -o json |
jq -r '.items[] | [.spec.nodeName,.metadata.namespace] | @tsv' |
awk '{a[$1]++; ns[$1 FS $2]++} END {for (n in a) print n,a[n]}' | sort || true

if $INCLUDE_ALL_PODS; then
  section "ALL PODS"
  oc get pods -A -o wide
fi

# Build compact summary files.
{
  echo "IBM MAS / OpenShift Cluster Discovery Summary"
  echo "Generated: $(date)"
  echo
  echo "MAS instances (${#MAS_IDS[@]}): ${MAS_IDS[*]:-NONE}"
  echo "SLS namespaces (${#SLS_NS[@]}): ${SLS_NS[*]:-NONE}"
  echo "MongoDB namespaces (${#MONGO_NS[@]}): ${MONGO_NS[*]:-NONE}"
  echo "Db2U present: $DB2_PRESENT"
  if [[ "$DB2_PRESENT" == YES ]]; then
    echo "Db2U namespaces: ${DB2_NS[*]:-UNKNOWN}"
  fi
  echo
  echo "Worker nodes:"
  oc get nodes -l node-role.kubernetes.io/worker \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory' \
    --no-headers 2>/dev/null || true
} > "$SUMMARY"

{
  echo "# Inputs for MAS Workload Isolation planning"
  echo "# This file is informational; review before constructing migration commands."
  echo
  for id in "${MAS_IDS[@]}"; do
    echo "INSTANCE=$id"
    echo "CORE_NAMESPACE=mas-${id}-core"
    echo "MANAGE_NAMESPACE=mas-${id}-manage"
    echo "TARGET_NODES=<to-be-decided>"
    echo
  done
  for ns in "${SLS_NS[@]}"; do echo "SLS_NAMESPACE=$ns"; done
  for ns in "${MONGO_NS[@]}"; do
    echo "MONGODB_NAMESPACE=$ns"
    oc get mongodbcommunity -n "$ns" \
      -o jsonpath='{range .items[*]}MONGODB_NAME={.metadata.name}{"\n"}{end}' 2>/dev/null || true
  done
  echo "DB2_PRESENT=$DB2_PRESENT"
  echo
  echo "# Next phase: map each MAS instance to its SLS/MongoDB namespace and desired target nodes."
} > "$COMMAND_INPUTS"



section "BUILDING STRUCTURED PLACEMENT DATA"

MAS_PLACEMENT="$RUN_DIR/raw/mas-placement.tsv"
SLS_PLACEMENT="$RUN_DIR/raw/sls-placement.tsv"
MONGO_PLACEMENT="$RUN_DIR/raw/mongodb-placement.tsv"
APPCFG_DISCOVERY="$RUN_DIR/raw/appconfig-graphite.tsv"
MANAGE_RUNTIME="$RUN_DIR/raw/manage-runtime.tsv"
OWNERSHIP="$RUN_DIR/raw/workload-ownership.tsv"
MAS_APP_NS="$RUN_DIR/raw/mas-application-namespaces.tsv"
MAS_APP_PLACEMENT="$RUN_DIR/raw/mas-application-placement.tsv"
ISOLATION_MAP="$RUN_DIR/raw/current-isolation-map.tsv"

# V1.7 - all MAS application namespaces and current isolation mapping.
printf "INSTANCE\tAPPLICATION\tNAMESPACE\tCLASSIFICATION\tISOLATION_SCOPE\tPOD_COUNT\tRUNNING_PODS\tCPU_REQUEST_M\tMEMORY_REQUEST_MI\tPVC_COUNT\tRUNNING_NODES\n" >"$MAS_APP_NS"
printf "INSTANCE\tAPPLICATION\tNAMESPACE\tPOD\tROLE\tOWNER_KIND\tOWNER_NAME\tNODE\tSTATUS\tREADY\tPVC\tAFFINITY\n" >"$MAS_APP_PLACEMENT"
printf "INSTANCE\tLABEL_KEY\tLABEL_VALUE\tWORKERS\tSTATUS\n" >"$ISOLATION_MAP"

for id in "${MAS_IDS[@]}"; do
  while read -r ns; do
    [[ -n "$ns" ]] || continue
    suffix="${ns#mas-${id}-}"
    [[ "$suffix" == "$ns" || "$suffix" == "pipelines" ]] && continue
    case "$suffix" in
      core) app="Core"; class="MAS Core"; scope="SUPPORTED" ;;
      manage) app="Manage"; class="MAS Application"; scope="SUPPORTED" ;;
      mref) app="MREF"; class="MAS Enterprise Application"; scope="DISCOVERY ONLY" ;;
      iot) app="IoT"; class="MAS Application"; scope="DISCOVERY ONLY" ;;
      monitor) app="Monitor"; class="MAS Application"; scope="DISCOVERY ONLY" ;;
      predict) app="Predict"; class="MAS Application"; scope="DISCOVERY ONLY" ;;
      facilities) app="Facilities"; class="MAS Enterprise Application"; scope="SUPPORTED" ;;
      arcgis) app="ArcGIS"; class="MAS Application"; scope="DISCOVERY ONLY" ;;
      *) app="$suffix"; class="Other / Future MAS Application"; scope="DISCOVERY ONLY" ;;
    esac
    pod_count="$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    running="$(oc get pods -n "$ns" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    pvc_count="$(oc get pvc -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    nodes="$(oc get pods -n "$ns" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u | paste -sd ',' -)"
    req="$(oc get pods -n "$ns" -o json 2>/dev/null | jq -r '
      def cpu_m: if .==null then 0 elif test("m$") then sub("m$";"")|tonumber elif test("n$") then (sub("n$";"")|tonumber)/1000000 elif test("u$") then (sub("u$";"")|tonumber)/1000 else (tonumber*1000) end;
      def mem_mi: if .==null then 0 elif test("Ki$") then (sub("Ki$";"")|tonumber)/1024 elif test("Mi$") then sub("Mi$";"")|tonumber elif test("Gi$") then (sub("Gi$";"")|tonumber)*1024 elif test("Ti$") then (sub("Ti$";"")|tonumber)*1024*1024 else 0 end;
      [([.items[].spec.containers[]?.resources.requests.cpu//"0"|cpu_m]|add//0|floor),([.items[].spec.containers[]?.resources.requests.memory//"0"|mem_mi]|add//0|floor)]|@tsv')"
    cpu_req="${req%%$'\t'*}"; mem_req="${req#*$'\t'}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "$app" "$ns" "$class" "$scope" "$pod_count" "$running" "$cpu_req" "$mem_req" "$pvc_count" "$nodes" >>"$MAS_APP_NS"
    oc get pods -n "$ns" -o json 2>/dev/null | jq -r --arg id "$id" --arg app "$app" '
      .items[]|select(.status.phase!="Succeeded")|(.metadata.ownerReferences[0]//{}) as $o |
      ([.spec.volumes[]?|.persistentVolumeClaim.claimName//empty]|unique|join(",")) as $p |
      (if (.metadata.name|test("^ibm-.*operator|controller-manager|operator-";"i")) then "SUPPORTING_OPERATOR" else "APPLICATION" end) as $role |
      [$id,$app,.metadata.namespace,.metadata.name,$role,($o.kind//""),($o.name//""),(.spec.nodeName//""),(.status.phase//""),(([.status.containerStatuses[]?.ready]|all)|tostring),$p,((.spec.affinity//{})|tojson)]|@tsv' >>"$MAS_APP_PLACEMENT"
  done < <(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E "^mas-${id}-" | sort)
  workers="$(oc get nodes -l "node-role.kubernetes.io/worker,workload-group=${id}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort | paste -sd ',' -)"
  [[ -n "$workers" ]] && printf "%s\tworkload-group\t%s\t%s\tConfigured\n" "$id" "$id" "$workers" >>"$ISOLATION_MAP" || printf "%s\tworkload-group\t%s\t\tNot Configured\n" "$id" "$id" >>"$ISOLATION_MAP"
done
echo; echo "===== MAS APPLICATION NAMESPACE INVENTORY ====="; column -t -s $'\t' "$MAS_APP_NS" 2>/dev/null || cat "$MAS_APP_NS"
echo; echo "===== ALL MAS APPLICATION PLACEMENT ====="; column -t -s $'\t' "$MAS_APP_PLACEMENT" 2>/dev/null || cat "$MAS_APP_PLACEMENT"
echo; echo "===== CURRENT ISOLATION MAP ====="; column -t -s $'\t' "$ISOLATION_MAP" 2>/dev/null || cat "$ISOLATION_MAP"

# V1.7 - optional Facilities application discovery.
FACILITIES_DISCOVERY="$RUN_DIR/raw/facilities-discovery.tsv"
printf "INSTANCE\tNAMESPACE\tFACILITIES_APP\tWORKSPACES\tAPP_READY\tWORKSPACE_READY\tPODTEMPLATES_VALID\tACTIVE_APP_PODS\tACTIVE_NODES\tREQUIRED_AFFINITY\n" >"$FACILITIES_DISCOVERY"
for id in "${MAS_IDS[@]}"; do
  fns="mas-${id}-facilities"; oc get ns "$fns" >/dev/null 2>&1 || continue
  fapp="$(oc get facilitiesapp -n "$fns" -l "mas.ibm.com/instanceId=$id" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  workspaces="$(oc get facilitiesworkspace -n "$fns" -l "mas.ibm.com/instanceId=$id" -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' 2>/dev/null | sed 's/,$//')"
  appready="N/A"; [[ -n "$fapp" ]] && appready="$(oc get facilitiesapp "$fapp" -n "$fns" -o json 2>/dev/null | jq -r '[.status.conditions[]?|select(.type=="Ready")][0].status // "Unknown"')"
  wsready="N/A"; ptvalid="N/A"
  if [[ -n "$workspaces" ]]; then
    IFS=',' read -ra _fw <<<"$workspaces"; wsready=""; ptvalid=""
    for ws in "${_fw[@]}"; do
      r="$(oc get facilitiesworkspace "$ws" -n "$fns" -o json 2>/dev/null | jq -r '[.status.conditions[]?|select(.type=="Ready")][0].status // "Unknown"')"
      pv="$(oc get facilitiesworkspace "$ws" -n "$fns" -o json 2>/dev/null | jq -r '[.status.conditions[]?|select(.type=="PodTemplatesValid")][0].status // "Unknown"')"
      wsready+="${ws}:${r},"; ptvalid+="${ws}:${pv},"
    done
    wsready="${wsready%,}"; ptvalid="${ptvalid%,}"
  fi
  fj="$(oc get pods -n "$fns" -o json 2>/dev/null || echo '{"items":[]}')"
  active="$(jq '[.items[]|select(.status.phase!="Succeeded")|select((.metadata.name|test("^ibm-mas-facilities-operator|^ibm-truststore-mgr-controller-manager"))|not)]|length' <<<"$fj")"
  nodes="$(jq -r '.items[]|select(.status.phase=="Running")|select((.metadata.name|test("^ibm-mas-facilities-operator|^ibm-truststore-mgr-controller-manager"))|not)|.spec.nodeName' <<<"$fj"|sort -u|paste -sd ',' -)"
  bad="$(jq --arg k workload-group --arg v "$id" '[.items[]|select(.status.phase=="Running")|select((.metadata.name|test("^ibm-mas-facilities-operator|^ibm-truststore-mgr-controller-manager"))|not)|select(([.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]?|select(.key==$k and .operator=="In" and (.values|index($v)!=null))]|length)==0)]|length' <<<"$fj")"
  [[ "$bad" == 0 ]] && affinity="COMPLIANT" || affinity="MISSING_ON_${bad}_RUNNING_PODS"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "$fns" "${fapp:-N/A}" "${workspaces:-N/A}" "$appready" "$wsready" "$ptvalid" "$active" "$nodes" "$affinity" >>"$FACILITIES_DISCOVERY"
done
echo; echo "===== FACILITIES DISCOVERY ====="; column -t -s $'\t' "$FACILITIES_DISCOVERY" 2>/dev/null || cat "$FACILITIES_DISCOVERY"

# V1.7 - optional AppConfig/Graphite
printf "INSTANCE\tAPPCFG\tENABLED\tREADY\tDEPLOYMENT\tPOD\tNODE\tSTATUS\tPVC\tAFFINITY\tOWNER\n" >"$APPCFG_DISCOVERY"
for id in "${MAS_IDS[@]}"; do
 ns="mas-${id}-core"; oc get ns "$ns" >/dev/null 2>&1 || continue
 appcfg="$(oc get appcfg -n "$ns" -l "mas.ibm.com/instanceId=$id" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
 [[ -n "$appcfg" ]] || continue
 enabled="$(oc get appcfg "$appcfg" -n "$ns" -o jsonpath='{.spec.config.enabled}' 2>/dev/null || true)"
 ready="$(oc get appcfg "$appcfg" -n "$ns" -o json 2>/dev/null|jq -r '[.status.conditions[]?|select(.type=="Ready")][0].status//"Unknown"')"
 dep="${id}-graphite-configuration"
 if oc get deployment "$dep" -n "$ns" >/dev/null 2>&1; then
  owner="$(oc get deployment "$dep" -n "$ns" -o json|jq -r '(.metadata.ownerReferences[0]//{})|((.kind//"")+"/"+(.name//""))')"
  affinity="$(oc get deployment "$dep" -n "$ns" -o json|jq -c '.spec.template.spec.affinity//{}')"
  pvc="$(oc get deployment "$dep" -n "$ns" -o json|jq -r '[.spec.template.spec.volumes[]?|.persistentVolumeClaim.claimName//empty]|unique|join(",")')"
  rows="$(oc get pods -n "$ns" -l "app=$dep" -o json|jq -r '.items[]|[.metadata.name,(.spec.nodeName//""),(.status.phase//"")]|@tsv')"
  if [[ -n "$rows" ]]; then
   while IFS=$'\t' read -r pod node status; do printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "$appcfg" "$enabled" "$ready" "$dep" "$pod" "$node" "$status" "${pvc:-None}" "$affinity" "$owner" >>"$APPCFG_DISCOVERY"; done <<<"$rows"
  else
   printf "%s\t%s\t%s\t%s\t%s\tN/A\t\tN/A\t%s\t%s\t%s\n" "$id" "$appcfg" "$enabled" "$ready" "$dep" "${pvc:-None}" "$affinity" "$owner" >>"$APPCFG_DISCOVERY"
  fi
 else
  printf "%s\t%s\t%s\t%s\tN/A\tN/A\t\tN/A\tN/A\t{}\tN/A\n" "$id" "$appcfg" "$enabled" "$ready" >>"$APPCFG_DISCOVERY"
 fi
done

# V1.5 - dynamic Manage topology; ALL/JMS/split bundles are optional.
printf "INSTANCE\tNAMESPACE\tWORKLOAD\tTYPE\tNODE\tSTATUS\tREADY\tPVC\tAFFINITY\n" >"$MANAGE_RUNTIME"
for id in "${MAS_IDS[@]}"; do
 ns="mas-${id}-manage"; oc get ns "$ns" >/dev/null 2>&1 || continue
 oc get pods -n "$ns" -o json 2>/dev/null|jq -r --arg id "$id" '
 .items[]|select(.status.phase!="Succeeded")|
 select((.metadata.name|startswith($id+"-")) and ((.metadata.name|test("entitymgr|operator|truststore";"i"))|not))|
 ([.spec.volumes[]?|.persistentVolumeClaim.claimName//empty]|unique|join(",")) as $p|
 [$id,.metadata.namespace,.metadata.name,
  (if (.metadata.name|test("-jmsserver-")) then "JMS"
   elif (.metadata.name|test("-maximo-all-")) then "ALL"
   elif (.metadata.name|test("-maximo-ui-")) then "UI"
   elif (.metadata.name|test("-maximo-mea-")) then "MEA"
   elif (.metadata.name|test("-maximo-cron-")) then "CRON"
   elif (.metadata.name|test("-maximo-report-")) then "REPORT"
   elif (.metadata.name|test("-maxinst-")) then "MAXINST"
   else "OTHER" end),
  (.spec.nodeName//""),(.status.phase//""),(([.status.containerStatuses[]?.ready]|all)|tostring),$p,
  ((.spec.affinity//{})|tojson)]|@tsv' >>"$MANAGE_RUNTIME"
done

# V1.5 - immediate owner + affinity for active MAS application pods.
printf "INSTANCE\tAREA\tNAMESPACE\tPOD\tOWNER_KIND\tOWNER_NAME\tNODE\tAFFINITY\n" >"$OWNERSHIP"
for id in "${MAS_IDS[@]}"; do
 for area in CORE MANAGE; do
  [[ "$area" == CORE ]] && ns="mas-${id}-core" || ns="mas-${id}-manage"
  oc get ns "$ns" >/dev/null 2>&1 || continue
  oc get pods -n "$ns" -o json 2>/dev/null|jq -r --arg id "$id" --arg area "$area" '
  .items[]|select(.status.phase=="Running")|
  select((.metadata.name|test("^ibm-.*operator|^ibm-truststore-mgr-controller-manager";"i"))|not)|
  (.metadata.ownerReferences[0]//{}) as $o|
  [$id,$area,.metadata.namespace,.metadata.name,($o.kind//""),($o.name//""),(.spec.nodeName//""),((.spec.affinity//{})|tojson)]|@tsv' >>"$OWNERSHIP"
 done
done

echo; echo "===== APPCONFIG / GRAPHITE ====="; column -t -s $'\t' "$APPCFG_DISCOVERY" 2>/dev/null||cat "$APPCFG_DISCOVERY"
echo; echo "===== MANAGE RUNTIME TOPOLOGY ====="; column -t -s $'\t' "$MANAGE_RUNTIME" 2>/dev/null||cat "$MANAGE_RUNTIME"

printf "INSTANCE\tCOMPONENT\tROLE\tNAMESPACE\tPOD\tNODE\tSTATUS\tREADY\n" >"$MAS_PLACEMENT"
for id in "${MAS_IDS[@]}"; do
  for comp in CORE MANAGE; do
    [[ "$comp" == CORE ]] && ns="mas-${id}-core" || ns="mas-${id}-manage"
    oc get ns "$ns" >/dev/null 2>&1 || continue
    oc get pods -n "$ns" -o json 2>/dev/null | jq -r --arg id "$id" --arg comp "$comp" '.items[] | (if (.metadata.name|test("^ibm-.*operator|^ibm-truststore-mgr-controller-manager";"i")) then "SUPPORTING_OPERATOR" else "APPLICATION" end) as $role | [$id,$comp,$role,.metadata.namespace,.metadata.name,(.spec.nodeName // ""),(.status.phase // ""),(([.status.containerStatuses[]?.ready]|all)|tostring)] | @tsv' >>"$MAS_PLACEMENT"
  done
done

printf "INSTANCE\tNAMESPACE\tROLE\tPOD\tNODE\tSTATUS\tREADY\n" >"$SLS_PLACEMENT"
for id in "${MAS_IDS[@]}"; do
  sns=""
  # Prefer exact conventional namespace; avoids eam matching dnxeam.
  exact_ns="ibm-sls-${id}"
  for candidate in "${SLS_NS[@]}"; do
    [[ "$candidate" == "$exact_ns" ]] && { sns="$candidate"; break; }
  done
  # Otherwise require LicenseClient name to START with the exact MAS ID plus '-'.
  if [[ -z "$sns" ]]; then
    for candidate in "${SLS_NS[@]}"; do
      if oc get licenseclient -n "$candidate" -o json 2>/dev/null | jq -e --arg id "$id" '.items[]? | select(.metadata.name | startswith($id + "-"))' >/dev/null 2>&1; then
        sns="$candidate"; break
      fi
    done
  fi
  # Final conservative fallback: exact namespace suffix.
  if [[ -z "$sns" ]]; then
    for candidate in "${SLS_NS[@]}"; do [[ "$candidate" == *-"$id" ]] && { sns="$candidate"; break; }; done
  fi
  [[ -n "$sns" ]] || { warn "Could not associate SLS with MAS instance $id"; continue; }
  oc get pods -n "$sns" -o json 2>/dev/null | jq -r --arg id "$id" '.items[] | (if (.metadata.name|test("^sls-api-licensing";"i")) then "SLS_API" elif (.metadata.name|test("^ibm-sls-controller-manager|^ibm-truststore-mgr-controller-manager";"i")) then "SUPPORTING_OPERATOR" else "SUPPORTING" end) as $role | [$id,.metadata.namespace,$role,.metadata.name,(.spec.nodeName // ""),(.status.phase // ""),(([.status.containerStatuses[]?.ready]|all)|tostring)] | @tsv' >>"$SLS_PLACEMENT"
done

printf "INSTANCE\tNAMESPACE\tROLE\tPOD\tNODE\tSTATUS\tREADY\n" >"$MONGO_PLACEMENT"
for id in "${MAS_IDS[@]}"; do
  mns=""; for x in "${MONGO_NS[@]}"; do [[ "$x" == *-"$id" ]] && mns="$x"; done; [[ -n "$mns" ]] || continue
  oc get pods -n "$mns" -o json 2>/dev/null | jq -r --arg id "$id" '.items[] | (if (.metadata.name|test("^mas-mongo-ce-[0-9]+$")) then "MEMBER" else "SUPPORTING_OPERATOR" end) as $role | [$id,.metadata.namespace,$role,.metadata.name,(.spec.nodeName // ""),(.status.phase // ""),(([.status.containerStatuses[]?.ready]|all)|tostring)] | @tsv' >>"$MONGO_PLACEMENT"
done

echo; echo "===== MAS APPLICATION PLACEMENT ====="; column -t -s $'\t' "$MAS_PLACEMENT" 2>/dev/null || cat "$MAS_PLACEMENT"
echo; echo "===== SLS PLACEMENT ====="; column -t -s $'\t' "$SLS_PLACEMENT" 2>/dev/null || cat "$SLS_PLACEMENT"
echo; echo "===== MONGODB PLACEMENT ====="; column -t -s $'\t' "$MONGO_PLACEMENT" 2>/dev/null || cat "$MONGO_PLACEMENT"


DB2_PLACEMENT="$RUN_DIR/raw/db2u-placement.tsv"
printf "NAMESPACE\tCLUSTER\tPOD\tNODE\tSTATUS\tREADY\n" >"$DB2_PLACEMENT"
if [[ "$DB2_PRESENT" == "YES" ]] || oc get db2ucluster -A --no-headers >/dev/null 2>&1; then
  while IFS=$'\t' read -r dns dname; do
    [[ -n "$dns" && -n "$dname" ]] || continue
    oc get pods -n "$dns" -o json 2>/dev/null | jq -r --arg ns "$dns" --arg cluster "$dname" '
      .items[] |
      select(.status.phase=="Running") |
      [$ns,$cluster,.metadata.name,(.spec.nodeName // ""),(.status.phase // ""),
       (([.status.containerStatuses[]?.ready]|all)|tostring)] | @tsv' >>"$DB2_PLACEMENT"
  done < <(oc get db2ucluster -A -o json 2>/dev/null | jq -r '.items[] | [.metadata.namespace,.metadata.name] | @tsv')
fi

if [[ "$(awk 'END{print NR}' "$DB2_PLACEMENT")" -gt 1 ]]; then
  DB2_PRESENT="YES"
fi

SCRIPT_END_EPOCH="$(date +%s)"
SCRIPT_END_ISO="$(date -Iseconds)"
SCRIPT_START_EPOCH="${SCRIPT_START_EPOCH:-$SCRIPT_END_EPOCH}"
SCRIPT_START_ISO="${SCRIPT_START_ISO:-$(date -Iseconds)}"
ELAPSED_SECONDS=$((SCRIPT_END_EPOCH-SCRIPT_START_EPOCH))
ELAPSED_FMT="$(printf '%02d:%02d:%02d' $((ELAPSED_SECONDS/3600)) $(((ELAPSED_SECONDS%3600)/60)) $((ELAPSED_SECONDS%60)))"
API_SERVER="${API_SERVER:-$(oc whoami --show-server 2>/dev/null || echo UNKNOWN)}"
CURRENT_USER="${CURRENT_USER:-$(oc whoami 2>/dev/null || echo UNKNOWN)}"

section "GENERATING CUSTOMER HTML REPORT"

# Customer-friendly HTML report. It summarizes discovery/current state only.
{
cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IBM MAS OpenShift Workload Placement Assessment</title>
<style>
body{font-family:Arial,Helvetica,sans-serif;margin:0;background:#f5f7fa;color:#1f2937}
header{background:#111827;color:white;padding:28px 36px}
main{max-width:1200px;margin:auto;padding:24px}
.card{background:white;border:1px solid #dbe2ea;border-radius:10px;padding:18px;margin:14px 0;box-shadow:0 1px 3px #0001}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px}
.metric{background:#eef4ff;border-radius:8px;padding:14px}.metric b{font-size:24px;display:block}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:13px}th,td{border:1px solid #d1d5db;padding:7px;text-align:left;vertical-align:top}th{background:#e5e7eb}
.ok{color:#166534;font-weight:bold}.warn{color:#92400e;font-weight:bold}.muted{color:#6b7280}
pre{white-space:pre-wrap;background:#111827;color:#e5e7eb;padding:14px;border-radius:8px;overflow:auto;font-size:12px}
.arch{font-family:monospace;background:#f8fafc;border:1px solid #dbe2ea;padding:14px;border-radius:8px}
footer{padding:24px;text-align:center;color:#6b7280;font-size:12px}
@media print{body{background:white}.card{box-shadow:none;break-inside:avoid}header{background:white;color:black;border-bottom:2px solid #111827}}
</style>
</head><body>
<header><h1>IBM MAS / OpenShift Workload Placement Assessment</h1>
<p>Discovery Report — Current State Before Migration</p></header><main>
HTML_HEAD

echo '<div class="card"><h2>Executive Summary</h2><div class="grid">'
echo "<div class=\"metric\"><b>${#MAS_IDS[@]}</b>MAS Instances</div>"
echo "<div class=\"metric\"><b>${#SLS_NS[@]}</b>SLS Instances</div>"
echo "<div class=\"metric\"><b>${#MONGO_NS[@]}</b>MongoDB Instances</div>"
echo "<div class=\"metric\"><b>$DB2_PRESENT</b>Db2U Detected</div>"
worker_count="$(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null | wc -l | tr -d ' ')"
echo "<div class=\"metric\"><b>$worker_count</b>Worker Nodes</div>"
echo '</div><p class="ok">No cluster changes were made by this discovery script.</p>'
echo '<p><b>Isolation mapping:</b> current workload-group labels are reported per MAS instance; absence is shown as Not Configured.</p></div>'

echo '<div class="card"><h2>OpenShift Cluster</h2>'
echo '<table><tr><th>Version</th><th>API</th><th>Workers</th><th>Db2U</th></tr>'
cv="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo UNKNOWN)"
api="$(oc whoami --show-server 2>/dev/null || echo UNKNOWN)"
printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr></table></div>\n' "$cv" "$api" "$worker_count" "$DB2_PRESENT"

echo '<div class="card"><h2>Worker Node Inventory</h2><table><tr><th>Worker</th><th>Status</th><th>CPU Allocatable</th><th>Memory Allocatable</th><th>workload-group</th></tr>'
for n in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  st="$(oc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  cpu="$(oc get node "$n" -o jsonpath='{.status.allocatable.cpu}')"
  mem="$(oc get node "$n" -o jsonpath='{.status.allocatable.memory}')"
  wg="$(oc get node "$n" -o jsonpath='{.metadata.labels.workload-group}' 2>/dev/null || true)"
  printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$n" "$st" "$cpu" "$mem" "${wg:-Not assigned}"
done
echo '</table></div>'

echo '<div class="card"><h2>Application Configuration / Graphite</h2>'
echo '<p>Optional MAS Application Configuration / Mobile customization workload.</p>'
python3 - "$APPCFG_DISCOVERY" <<'PYAPP'
import csv,html,sys
r=list(csv.DictReader(open(sys.argv[1],encoding="utf8",errors="replace"),delimiter="\t"))
print('<table><tr><th>MAS</th><th>AppCfg</th><th>Enabled</th><th>Ready</th><th>Deployment</th><th>Pod</th><th>Node</th><th>PVC</th><th>Owner</th><th>Affinity</th></tr>')
if not r: print('<tr><td colspan="10">No AppCfg / Graphite discovered</td></tr>')
for x in r:
 v=[x.get(k,'') for k in ['INSTANCE','APPCFG','ENABLED','READY','DEPLOYMENT','POD','NODE','PVC','OWNER','AFFINITY']]
 print('<tr>'+''.join('<td>'+html.escape(y or 'N/A')+'</td>' for y in v)+'</tr>')
print('</table>')
PYAPP
echo '</div>'

echo '<div class="card"><h2>Manage Runtime Topology</h2>'
echo '<p>Runtime is discovered dynamically. ALL, JMS and split UI/MEA/CRON/REPORT bundles are optional.</p>'
python3 - "$MANAGE_RUNTIME" "${MAS_IDS[@]}" <<'PYM'
import csv,html,sys
r=list(csv.DictReader(open(sys.argv[1],encoding="utf8",errors="replace"),delimiter="\t")); ids=sys.argv[2:]; seen=set()
print('<table><tr><th>MAS</th><th>Namespace</th><th>Type</th><th>Pod</th><th>Status</th><th>Node</th><th>PVC</th><th>Affinity</th></tr>')
for x in r:
 seen.add(x.get('INSTANCE','')); v=[x.get(k,'') for k in ['INSTANCE','NAMESPACE','TYPE','WORKLOAD','STATUS','NODE','PVC','AFFINITY']]
 print('<tr>'+''.join('<td>'+html.escape(y or 'N/A')+'</td>' for y in v)+'</tr>')
for i in ids:
 if i not in seen: print(f'<tr><td>{html.escape(i)}</td><td>mas-{html.escape(i)}-manage</td><td colspan="6">No Manage runtime workload discovered (not automatically an error; inspect other installed applications such as MREF).</td></tr>')
print('</table>')
PYM
echo '</div>'

echo '<div class="card"><h2>All MAS Application Placement</h2>'
echo '<p>Core, Manage, MREF, IoT, Monitor, Predict, ArcGIS and unknown/future MAS application namespaces are included. Pipelines is excluded.</p>'
python3 - "$MAS_APP_PLACEMENT" <<'PYAPP16'
import csv,html,sys
rows=list(csv.DictReader(open(sys.argv[1],encoding="utf8",errors="replace"),delimiter="\t"))
print('<table><tr><th>MAS</th><th>Application</th><th>Namespace</th><th>Pod</th><th>Role</th><th>Node</th><th>Status</th><th>Owner</th><th>Affinity</th></tr>')
for r in rows:
 owner=((r.get("OWNER_KIND") or "")+"/"+(r.get("OWNER_NAME") or "")).strip("/")
 vals=[r.get("INSTANCE",""),r.get("APPLICATION",""),r.get("NAMESPACE",""),r.get("POD",""),r.get("ROLE",""),r.get("NODE",""),r.get("STATUS",""),owner or "N/A",r.get("AFFINITY","{}")]
 print('<tr>'+''.join('<td>'+html.escape(v or "N/A")+'</td>' for v in vals)+'</tr>')
print('</table>')
PYAPP16
echo '</div>'

echo '<div class="card"><h2>MAS Application Placement</h2>'
echo '<p>Authoritative pod-to-worker placement collected directly during discovery.</p>'
echo '<table><tr><th>MAS Instance</th><th>Component</th><th>Namespace</th><th>Running Worker Nodes</th></tr>'
for id in "${MAS_IDS[@]}"; do
  for comp in CORE MANAGE; do
    [[ "$comp" == CORE ]] && ns="mas-${id}-core" || ns="mas-${id}-manage"
    nodes="$(awk -F '\t' -v i="$id" -v c="$comp" 'NR>1 && $1==i && $2==c && $3=="APPLICATION" && $7=="Running" && $6!="" {print $6}' "$MAS_PLACEMENT" | sort -u | paste -sd '|' - | sed 's/|/<br>/g')"
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$id" "$comp" "$ns" "${nodes:-No running placement found}"
  done
done
echo '</table></div>'

echo '<div class="card"><h2>Supporting Operator Placement</h2>'
echo '<p>Supporting operators are shown separately and are not counted as MAS application workload placement.</p>'
echo '<table><tr><th>MAS Instance</th><th>Area</th><th>Pod</th><th>Running Worker</th></tr>'
awk -F '\t' 'NR>1 && $3=="SUPPORTING_OPERATOR" && $7=="Running" {print $1"\t"$2"\t"$5"\t"$6}' "$MAS_PLACEMENT" | while IFS=$'\t' read -r iid area pod node; do printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$iid" "$area" "$pod" "$node"; done
awk -F '\t' 'NR>1 && $3=="SUPPORTING_OPERATOR" && $6=="Running" {print $1"\tSLS\t"$4"\t"$5}' "$SLS_PLACEMENT" | while IFS=$'\t' read -r iid area pod node; do printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$iid" "$area" "$pod" "$node"; done
echo '</table></div>'

echo '<div class="card"><h2>MAS Instances and Installed Applications</h2>'
echo '<p>Discovers all <code>mas-&lt;instance&gt;-&lt;application&gt;</code> namespaces. Pipelines is excluded. Other MAS applications are Discovery Only unless explicitly supported by the isolation script.</p>'
python3 - "$MAS_APP_NS" "$ISOLATION_MAP" <<'PYMAS16'
import csv,html,sys
apps=list(csv.DictReader(open(sys.argv[1],encoding="utf8",errors="replace"),delimiter="\t"))
iso={r["INSTANCE"]:r for r in csv.DictReader(open(sys.argv[2],encoding="utf8",errors="replace"),delimiter="\t")}
print('<table><tr><th>Instance</th><th>Application</th><th>Namespace</th><th>Classification</th><th>Isolation Capability</th><th>Running Pods</th><th>Current Placement</th><th>Current Isolation Workers</th></tr>')
for r in apps:
 i=iso.get(r["INSTANCE"],{})
 vals=[r["INSTANCE"],r["APPLICATION"],r["NAMESPACE"],r["CLASSIFICATION"],r["ISOLATION_SCOPE"],r["RUNNING_PODS"]]
 placement=html.escape(r.get("RUNNING_NODES") or "No running placement").replace(",", "<br>")
 workers=html.escape(i.get("WORKERS") or "Not Configured").replace(",", "<br>")
 print('<tr>'+''.join('<td>'+html.escape(v or "N/A")+'</td>' for v in vals)+'<td>'+placement+'</td><td>'+workers+'</td></tr>')
print('</table>')
PYMAS16
echo '</div>'

echo '<div class="card"><h2>Isolation Readiness</h2>'
echo '<p>Discovery guidance only. No target workers are assigned or modified.</p>'
echo '<table><tr><th>MAS</th><th>AppConfig / Graphite</th><th>Manage Runtime Types</th><th>JMS</th></tr>'
for id in "${MAS_IDS[@]}"; do
 ac="$(awk -F '\t' -v i="$id" 'NR>1&&$1==i{print ($5!="N/A"?"Present":"Not Present");exit}' "$APPCFG_DISCOVERY")"; [[ -n "$ac" ]]||ac="Not Present"
 rt="$(awk -F '\t' -v i="$id" 'NR>1&&$1==i{print $4}' "$MANAGE_RUNTIME"|sort -u|paste -sd ',' -)"; [[ -n "$rt" ]]||rt="No Manage runtime discovered"
 jms="$(awk -F '\t' -v i="$id" 'NR>1&&$1==i&&$4=="JMS"{x=1}END{print x?"Configured":"Not Configured"}' "$MANAGE_RUNTIME")"
 printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$id" "$ac" "$rt" "$jms"
done
echo '</table></div>'

echo '<div class="card"><h2>MAS → SLS → MongoDB Association</h2><table><tr><th>MAS</th><th>SLS</th><th>MongoDB</th><th>Association Basis</th></tr>'
for id in "${MAS_IDS[@]}"; do
  sls=""; mongo=""
  sls="$(awk -F '\t' -v i="$id" 'NR>1 && $1==i {print $2; exit}' "$SLS_PLACEMENT")"
  for x in "${MONGO_NS[@]}"; do [[ "$x" == *-"$id" ]] && mongo="$x"; done
  printf '<tr><td>%s</td><td>%s</td><td>%s / mas-mongo-ce</td><td>Exact namespace / LicenseClient association</td></tr>\n' "$id" "${sls:-Not inferred}" "${mongo:-Not inferred}"
done
echo '</table></div>'

echo '<div class="card"><h2>SLS Discovery</h2><table><tr><th>Namespace</th><th>LicenseService</th><th>SLS API Placement</th><th>Supporting Controllers</th></tr>'
for ns in "${SLS_NS[@]}"; do
  lsname="$(oc get licenseservice -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo N/A)"
  appnodes="$(oc get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[]|select(.status.phase=="Running" and (.metadata.name|test("^sls-api-")))|.spec.nodeName' | sort -u | paste -sd '|' - | sed 's/|/<br>/g')"
  ctrls="$(oc get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[]|select(.status.phase=="Running" and (.metadata.name|test("^ibm-sls-controller-manager|^ibm-truststore-mgr-controller-manager")))|(.metadata.name+" @ "+(.spec.nodeName//""))' | paste -sd '|' - | sed 's/|/<br>/g')"
  printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$ns" "$lsname" "${appnodes:-No SLS API runtime found}" "${ctrls:-None}"
done
echo '</table></div>'

echo '<div class="card"><h2>MongoDB Discovery</h2><table><tr><th>Namespace</th><th>Name</th><th>Phase</th><th>Members</th><th>Current Placement</th><th>PVC Status</th></tr>'
for ns in "${MONGO_NS[@]}"; do
  for mn in $(oc get mongodbcommunity -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    ph="$(oc get mongodbcommunity "$mn" -n "$ns" -o jsonpath='{.status.phase}')"
    members="$(oc get sts "$mn" -n "$ns" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
    nodes="$(oc get pods -n "$ns" -l "app=${mn}-svc" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u | paste -sd '|' - | sed 's/|/<br>/g')"
    bad="$(oc get pvc -n "$ns" -o json | jq '[.items[]|select(.status.phase!="Bound")]|length')"
    [[ "$bad" == 0 ]] && pvc="All Bound" || pvc="$bad not Bound"
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$ns" "$mn" "$ph" "$members" "$nodes" "$pvc"
  done
done
echo '</table></div>'

echo '<div class="card"><h2>Db2U Discovery</h2>'
if [[ "$DB2_PRESENT" == "YES" ]]; then
  echo '<p class="ok">Db2U is present inside the OpenShift cluster.</p>'
  echo '<table><tr><th>Namespace</th><th>Db2uCluster</th><th>State</th><th>Maintenance</th><th>Running Nodes</th></tr>'
  while IFS=$'\t' read -r dns dname state maintenance; do
    nodes="$(awk -F '\t' -v ns="$dns" -v cl="$dname" 'NR>1 && $1==ns && $2==cl && $5=="Running" && $4!="" {print $4}' "$DB2_PLACEMENT" | sort -u | paste -sd '|' - | sed 's/|/<br>/g')"
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "$dns" "$dname" "${state:-Unknown}" "${maintenance:-Unknown}" "${nodes:-No running placement found}"
  done < <(oc get db2ucluster -A -o json 2>/dev/null | jq -r '.items[] | [.metadata.namespace,.metadata.name,(.status.state // "Unknown"),(.status.maintenanceState // "Unknown")] | @tsv')
  echo '</table>'
else
  echo '<p><b>Db2U in OpenShift:</b> Not Present</p>'
  echo '<p>Manage database is external to this OpenShift cluster.</p>'
fi
echo '</div>'

echo '<div class="card"><h2>MAS Manage PVC / Storage Assessment</h2>'
echo '<p>PVC/PV objects are preserved during workload placement changes. The workload moves; storage must remain Bound and mountable from the target worker pool.</p>'
python3 - "$RUN_DIR/raw/manage-pvc.tsv" "${MAS_IDS[@]}" <<'PYHTMLPVC'
import csv,html,sys
path=sys.argv[1]; ids=sys.argv[2:]
with open(path,encoding="utf-8",errors="replace",newline="") as f:
    rows=list(csv.DictReader(f,delimiter="\t"))
print('<table><tr><th>MAS</th><th>Namespace</th><th>PVC</th><th>Status</th><th>Access</th><th>StorageClass</th><th>Capacity</th><th>Volume Mode</th><th>Mounted By</th><th>Current Mount Nodes</th></tr>')
def fmt(v):
    v=(v or '').strip()
    return html.escape(v).replace('&lt;br&gt;','<br>') if v else 'Not currently mounted'
seen=set()
for r in rows:
    iid=r.get('INSTANCE',''); seen.add(iid)
    vals=[iid,r.get('NAMESPACE',''),r.get('PVC',''),r.get('STATUS',''),r.get('ACCESS',''),r.get('STORAGECLASS',''),r.get('CAPACITY',''),r.get('VOLUMEMODE',''),r.get('MOUNTED_BY',''),r.get('MOUNT_NODES','')]
    print('<tr>'+''.join('<td>'+fmt(v)+'</td>' for v in vals)+'</tr>')
for iid in ids:
    if iid not in seen:
        print(f'<tr><td>{html.escape(iid)}</td><td>mas-{html.escape(iid)}-manage</td><td colspan="8">No Manage PVCs discovered</td></tr>')
print('</table>')
PYHTMLPVC
echo '<p><b>Storage note:</b> RWO volumes can require detach/reattach during pod relocation. RWX volumes can normally be mounted from multiple eligible workers, subject to the storage provider. PVC/PV objects should not be recreated by workload placement migration.</p></div>'

echo '<div class="card"><h2>Workload Ownership and Affinity</h2>'
echo '<p>Immediate Kubernetes ownership and current affinity for active MAS application pods.</p>'
python3 - "$OWNERSHIP" <<'PYO'
import csv,html,sys
r=list(csv.DictReader(open(sys.argv[1],encoding="utf8",errors="replace"),delimiter="\t"))
print('<table><tr><th>MAS</th><th>Area</th><th>Pod</th><th>Immediate Owner</th><th>Node</th><th>Affinity</th></tr>')
for x in r:
 o=((x.get('OWNER_KIND') or '')+'/'+(x.get('OWNER_NAME') or '')).strip('/')
 v=[x.get('INSTANCE',''),x.get('AREA',''),x.get('POD',''),o or 'N/A',x.get('NODE',''),x.get('AFFINITY','{}')]
 print('<tr>'+''.join('<td>'+html.escape(y or 'N/A')+'</td>' for y in v)+'</tr>')
print('</table>')
PYO
echo '</div>'

echo '<div class="card"><h2>MAS Application Technical Inventory</h2><pre>'; cat "$MAS_APP_NS" | html_escape; echo '</pre>'
echo '<h3>All MAS Application Placement</h3><pre>'; cat "$MAS_APP_PLACEMENT" | html_escape; echo '</pre>'
echo '<h3>Current Isolation Map</h3><pre>'; cat "$ISOLATION_MAP" | html_escape; echo '</pre></div>'

echo '<div class="card"><h2>Discovery Execution Summary</h2>'
echo '<table>'
printf '<tr><th>Script Version</th><td>%s</td></tr>\n' 'v1.8'
printf '<tr><th>Execution Date / Start</th><td>%s</td></tr>\n' "$SCRIPT_START_ISO"
printf '<tr><th>Execution End</th><td>%s</td></tr>\n' "$SCRIPT_END_ISO"
printf '<tr><th>Total Time Taken</th><td>%s (%s seconds)</td></tr>\n' "$ELAPSED_FMT" "$ELAPSED_SECONDS"
printf '<tr><th>Executed User</th><td>%s</td></tr>\n' "$CURRENT_USER"
printf '<tr><th>OpenShift API</th><td>%s</td></tr>\n' "$API_SERVER"
printf '<tr><th>Execution Type</th><td>Discovery / Read Only</td></tr>\n'
printf '<tr><th>Cluster Changes</th><td class="ok">NONE</td></tr>\n'
echo '</table></div>'

echo '<div class="card"><h2>Task Execution Details</h2>'
echo '<table><tr><th>Execution Task</th><th>Status</th></tr>'
python3 - "$REPORT" <<'PY'
import sys,re,html
text=open(sys.argv[1],encoding="utf-8",errors="replace").read()
lines=text.splitlines()
excluded={
 "GENERATING CUSTOMER HTML REPORT",
 "GENERATING DISCOVERY EXECUTION REPORT",
 "GENERATING APPLICATION ARCHITECTURE IMAGE",
 "DISCOVERY COMPLETE",
}
i=0
while i<len(lines):
    if lines[i].startswith("=") and i+2<len(lines) and lines[i+2].startswith("="):
        title=lines[i+1].strip(); j=i+3; body=[]
        while j<len(lines) and not (lines[j].startswith("=") and j+2<len(lines) and lines[j+2].startswith("=")):
            body.append(lines[j]); j+=1
        if title and title not in excluded:
            b="\n".join(body)
            status="Failed" if "[FAIL]" in b else ("Warning" if "[WARN]" in b or "WARNING" in b else "Completed")
            cls="warn" if status=="Warning" else ("bad" if status=="Failed" else "ok")
            print(f"<tr><td>{html.escape(title)}</td><td class='{cls}'>{status}</td></tr>")
        i=j
    else: i+=1
PY
echo '</table></div>'

echo '<div class="card"><h2>Detailed Discovery Output</h2>'
python3 - "$REPORT" <<'PY'
import sys,html
text=open(sys.argv[1],encoding="utf-8",errors="replace").read()
lines=text.splitlines()
excluded={
 "GENERATING CUSTOMER HTML REPORT",
 "GENERATING DISCOVERY EXECUTION REPORT",
 "GENERATING APPLICATION ARCHITECTURE IMAGE",
 "DISCOVERY COMPLETE",
}
i=0
while i<len(lines):
    if lines[i].startswith("=") and i+2<len(lines) and lines[i+2].startswith("="):
        title=lines[i+1].strip(); j=i+3; body=[]
        while j<len(lines) and not (lines[j].startswith("=") and j+2<len(lines) and lines[j+2].startswith("=")):
            body.append(lines[j]); j+=1
        if title and title not in excluded:
            print("<h3>"+html.escape(title)+"</h3><pre>"+html.escape("\n".join(body).strip())+"</pre>")
        i=j
    else: i+=1
PY
echo '</div>'

echo '</main><footer>IBM MAS / OpenShift Cluster Discovery v1.8 — Read-only assessment</footer></body></html>'
} >"$HTML_REPORT"

info "HTML report generated: $HTML_REPORT"




section "DISCOVERY COMPLETE"
echo "No cluster changes were made."
echo
echo "Full report    : $REPORT"
echo "HTML report    : $HTML_REPORT"
echo "Summary        : $SUMMARY"
echo "Command inputs : $COMMAND_INPUTS"
echo "Raw data       : $RUN_DIR/raw"

# V1.8 - automatically package the discovery output.
# Compression is packaging only; failure does not invalidate discovery results.
echo
section "CREATING COMPRESSED DISCOVERY REPORT"

REPORT_PARENT="$(dirname "$RUN_DIR")"
REPORT_DIR_NAME="$(basename "$RUN_DIR")"
ARCHIVE_FILE="${RUN_DIR}.tar.gz"

if command -v tar >/dev/null 2>&1; then
  if tar -C "$REPORT_PARENT" -czf "$ARCHIVE_FILE" "$REPORT_DIR_NAME"; then
    ARCHIVE_SIZE="$(du -h "$ARCHIVE_FILE" 2>/dev/null | awk '{print $1}')"
    echo "[PASS] Discovery report compressed successfully."
    echo "Compressed file: $ARCHIVE_FILE"
    [[ -n "$ARCHIVE_SIZE" ]] && echo "Archive size   : $ARCHIVE_SIZE"
  else
    warn "Unable to create compressed discovery report."
    echo "Discovery report directory remains available: $RUN_DIR"
  fi
else
  warn "tar command not found; compressed discovery report was not created."
  echo "Discovery report directory remains available: $RUN_DIR"
fi
