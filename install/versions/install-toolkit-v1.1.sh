#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${MAS_TOOLKIT_NAMESPACE:-mas-toolkit}"
DEPLOYMENT="${MAS_TOOLKIT_DEPLOYMENT:-mas-toolkit}"
CONTAINER="${MAS_TOOLKIT_CONTAINER:-mas-cli}"
REMOTE_ROOT="${MAS_TOOLKIT_REMOTE_ROOT:-/mascli/mas-workload-isolation}"
LOGIN_INSECURE="${MAS_TOOLKIT_INSECURE_TLS:-true}"
WAIT_TIMEOUT="${MAS_TOOLKIT_WAIT_TIMEOUT:-600s}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCE_FILE="$SCRIPT_DIR/mas-toolkit-resources.yaml"

step(){ printf '\n============================================================\n %s\n============================================================\n' "$*"; }
fail(){ echo "[FAIL] $*" >&2; exit 1; }
pass(){ echo "[PASS] $*"; }

step "IBM MAS WORKLOAD ISOLATION TOOLKIT INSTALLER"

command -v oc >/dev/null 2>&1 || fail "oc CLI is required."
[[ -f "$RESOURCE_FILE" ]] || fail "Missing resource file: $RESOURCE_FILE"

# Verify this looks like the toolkit root before making cluster changes.
[[ -d "$PROJECT_ROOT/scripts" ]] || fail "Expected local toolkit folder not found: $PROJECT_ROOT/scripts"
pass "Local toolkit directory: $PROJECT_ROOT"
pass "oc CLI available: $(command -v oc)"

step "OPENSHIFT LOGIN"
if USER_INFO="$(oc whoami 2>/dev/null)"; then
  pass "Existing OpenShift session is active as: $USER_INFO"
  echo "API: $(oc whoami --show-server 2>/dev/null || echo UNKNOWN)"
else
  read -r -p "Enter OpenShift API URL (example https://api.cluster.example:6443): " OCP_SERVER
  [[ -n "$OCP_SERVER" ]] || fail "OpenShift API URL is required."

  if [[ -z "${OCP_USER:-}" ]]; then
    read -r -p "Enter OCP Username: " OCP_USER
  fi
  if [[ -z "${OCP_PASSWORD:-}" ]]; then
    read -r -s -p "Enter OCP Password: " OCP_PASSWORD
    echo
  fi

  echo "Authenticating to $OCP_SERVER ..."
  LOGIN_ARGS=("$OCP_SERVER" -u "$OCP_USER" -p "$OCP_PASSWORD")
  if [[ "$LOGIN_INSECURE" == "true" ]]; then
    LOGIN_ARGS+=(--insecure-skip-tls-verify=true)
  fi
  if oc login "${LOGIN_ARGS[@]}"; then
    pass "Successfully logged in as $(oc whoami)"
  else
    unset OCP_PASSWORD
    fail "OpenShift login failed."
  fi
  unset OCP_PASSWORD
fi

step "PERMISSION PRECHECK"
oc auth can-i create namespaces >/dev/null 2>&1 || fail "Unable to check permissions."
CAN_NS="$(oc auth can-i create namespaces 2>/dev/null || true)"
CAN_CRB="$(oc auth can-i create clusterrolebindings.rbac.authorization.k8s.io 2>/dev/null || true)"
echo "Create namespaces          : $CAN_NS"
echo "Create ClusterRoleBindings: $CAN_CRB"
[[ "$CAN_NS" == "yes" && "$CAN_CRB" == "yes" ]] || fail "Installer requires privileges to create the toolkit namespace and cluster-admin binding."

step "CREATE / UPDATE MAS CLI TOOLKIT RESOURCES"
oc apply -f "$RESOURCE_FILE"
pass "Resources applied"

step "WAIT FOR MAS CLI POD"
oc rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT" || {
  oc get pods -n "$NAMESPACE" -o wide || true
  fail "MAS CLI deployment did not become ready within $WAIT_TIMEOUT."
}
POD="$(oc get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$POD" ]] || fail "Unable to discover MAS CLI pod."
pass "MAS CLI pod ready: $POD"

step "COPY LOCAL TOOLKIT TO MAS CLI POD"
# Keep the persistent /mascli mount, but replace only the toolkit project directory.
oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c "rm -rf '$REMOTE_ROOT' && mkdir -p '$REMOTE_ROOT'"
# Copy project contents, not the parent directory itself.
COPYFILE_DISABLE=1 tar -C "$PROJECT_ROOT" -cf - . | \
  oc exec -i -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
  tar -C "$REMOTE_ROOT" -xf -
# Make every shell script in the complete toolkit executable, including installer,
# stable entry points, and versioned historical copies.
oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
  bash -c "find '$REMOTE_ROOT' -type f -name '*.sh' -exec chmod +x {} +"
pass "Executable permission applied to all toolkit .sh files"

step "VERIFY TOOLKIT"
oc exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- bash -c "
  set -e
  for f in \
    '$REMOTE_ROOT/scripts/discovery/mas-cluster-discovery.sh' \
    '$REMOTE_ROOT/scripts/isolation/mas-workload-isolation.sh' \
    '$REMOTE_ROOT/scripts/validation/mas-workload-isolation-validation.sh'
  do
    [ -f \"\$f\" ] || { echo \"[FAIL] Missing: \$f\"; exit 1; }
    [ -x \"\$f\" ] || { echo \"[FAIL] Not executable: \$f\"; exit 1; }
    bash -n \"\$f\" || { echo \"[FAIL] Syntax validation: \$f\"; exit 1; }
    echo \"[PASS] \$f\"
  done
"
pass "Toolkit copied to $REMOTE_ROOT and validated"

step "INSTALLATION COMPLETE"
cat <<EOF
Namespace : $NAMESPACE
Pod       : $POD
Directory : $REMOTE_ROOT

The toolkit files are stored on the MAS CLI PVC mounted at /mascli.

Opening an interactive MAS CLI shell now.
EOF

exec oc exec -it -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
  bash -lc "cd '$REMOTE_ROOT'; echo 'Working directory: $REMOTE_ROOT'; exec bash"
