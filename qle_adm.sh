#!/usr/bin/env bash
# qle_adm.sh - TrueNAS SCALE QLogic FC Target Manager
# Manages qla2xxx_scst targets, LUN mapping, and firmware
# for QLogic ISP2xxx series HBAs on TrueNAS SCALE Community Edition.
#
# Persistent store: set QLE_ADM_HOME to a dataset under /mnt
# Example: QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes deploy install
#
# Environment variables (set in ~/.bashrc or ~/.zshrc):
#   QLE_ADM_HOME        Path to persistent store (required)
#   QLE_ADM_USE_COLOR   0 = disable ANSI color output (default 1)
#   QLE_ADM_USE_UNICODE 0 = ASCII fallback for symbols (default 1)
#
# Requires: bash, python3 (JSON only)
# Version: 7.0

# ─── Configuration ────────────────────────────────────────────────────────────
VERSION="7.0"
CONFIG_SCHEMA=3   # current schema version written by cfg_init

# Migration eligibility table.
# Key format: "from_schema:to_schema"
# Value: "eligible" or "ineligible:<reason>"
# Add a new entry here for every future schema change.
# For multi-hop migrations (e.g. 1->2->3) entries are chained automatically.
declare -A MIGRATION_TABLE=(
    ["1:2"]="eligible"
    ["2:3"]="eligible"
    # ["3:4"]="ineligible:structural change - manual rebuild required"
)

QLE_ADM_HOME="${QLE_ADM_HOME:-}"
CONFIG="${QLE_ADM_HOME}/config.json"
MODPROBE_CONF="/etc/modprobe.d/qla2xxx_scst.conf"
SCST_CONF="/etc/scst.conf"
SCST_DROPIN_DIR="/etc/systemd/system/scst.service.d"
SCST_DROPIN="${SCST_DROPIN_DIR}/qle-adm-ordering.conf"
FIRMWARE_DIR="${QLE_ADM_HOME}/firmware"
LOG="${QLE_ADM_HOME}/qle_adm.log"
SWAP_ENV_FILE="/tmp/qle_adm_swap_env.$$"

QLE_ADM_USE_COLOR="${QLE_ADM_USE_COLOR:-1}"     # 0 = no ANSI color codes in output
QLE_ADM_USE_UNICODE="${QLE_ADM_USE_UNICODE:-1}" # 0 = ASCII fallback for symbols (─ ● ✓ ⚠ ✗ →)

# ISP type to firmware file mapping
declare -A ISP_FW_FILE=(
    ["ISP2100"]="ql2100_fw.bin"
    ["ISP2200"]="ql2200_fw.bin"
    ["ISP2300"]="ql2300_fw.bin"
    ["ISP2322"]="ql2322_fw.bin"
    ["ISP2432"]="ql2400_fw.bin"
    ["ISP2512"]="ql2500_fw.bin"
    ["ISP2522"]="ql2500_fw.bin"
    ["ISP2532"]="ql2500_fw.bin"
)

DRY_RUN=0
VERBOSE=0
YES=0
WATCH_INTERVAL=2

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
WHT='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'
[[ $QLE_ADM_USE_COLOR -eq 0 ]] && RED="" && GRN="" && YLW="" && BLU="" && CYN="" && WHT="" && DIM="" && NC=""

# ─── Symbols ──────────────────────────────────────────────────────────────────
SYM_OK="✓"
SYM_WARN="⚠"
SYM_ERR="✗"
SYM_INFO="→"
SYM_BULLET="●"
SYM_HBAR="─"
[[ $QLE_ADM_USE_UNICODE -eq 0 ]] && SYM_OK="*" && SYM_WARN="!" && SYM_ERR="x" && SYM_INFO=">" && SYM_BULLET="*" && SYM_HBAR="-"

ok()   { echo -e "${GRN}${SYM_OK}${NC} $*";         log "ok: $*"; }
warn() { echo -e "${YLW}${SYM_WARN}${NC}  $*";      log "warn: $*"; }
err()  { echo -e "${RED}${SYM_ERR}${NC} $*" >&2;    log "err: $*"; }
info() { echo -e "${BLU}${SYM_INFO}${NC} $*" >&2;   log "info: $*"; }
gap()  { echo -e "${RED}GAP${NC} $*"; }
terminal_width() {
    local w
    w=$(tput cols 2>/dev/null)
    if [[ "$w" =~ ^[0-9]+$ && "$w" -gt 0 ]]; then
        echo "$w"
    else
        echo 60
    fi
}

hbar() {
    local w; w=$(terminal_width)
    local bar=""
    local i=0
    while [[ $i -lt $w ]]; do
        bar+="${SYM_HBAR}"
        i=$((i+1))
    done
    printf '%s' "$bar"
}

# divider - prints a plain full-width +---...---+ rule.
# Suppressed when _LIST_ALL_MODE=1 so list-all can emit a single final divider.
divider() {
    [[ "${_LIST_ALL_MODE:-0}" == "1" ]] && return
    local w; w=$(terminal_width)
    local inner=$(( w - 2 ))
    local bar="" i=0
    while [[ $i -lt $inner ]]; do bar+="${SYM_HBAR}"; i=$((i+1)); done
    echo "+${bar}+"
}

_divider_force() {
    local w; w=$(terminal_width)
    local inner=$(( w - 2 ))
    local bar="" i=0
    while [[ $i -lt $inner ]]; do bar+="${SYM_HBAR}"; i=$((i+1)); done
    echo "+${bar}+"
}

# hdr - box-style heading:
#   +----...----+
#   | heading   |
#   +----...----+
hdr() {
    local title="$*"
    local w; w=$(terminal_width)
    local inner=$(( w - 2 ))   # columns between the + signs
    local bar="" i=0
    while [[ $i -lt $inner ]]; do bar+="${SYM_HBAR}"; i=$((i+1)); done
    local border="+${bar}+"
    # Pad title to fill inner width:  "| title<spaces> |"
    local tlen=${#title}
    local pad=$(( inner - 2 - tlen ))   # 2 for the leading "  " space after |
    [[ $pad -lt 0 ]] && pad=0
    local spaces="" j=0
    while [[ $j -lt $pad ]]; do spaces+=" "; j=$((j+1)); done
    echo -e "${DIM}${border}${NC}"
    echo -e "${WHT}| ${title}${spaces} |${NC}"
    echo -e "${DIM}${border}${NC}"
}
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null || true; }

# ─── Python JSON helpers ───────────────────────────────────────────────────────
py_json() { python3 -c "$1" 2>/dev/null; }

cfg_get() {
    py_json "
import json, sys
try:
    d = json.load(open('${CONFIG}'))
    keys = '$1'.split('.')
    v = d
    for k in keys:
        v = v[k]
    print(v if not isinstance(v, (list,dict)) else json.dumps(v))
except:
    print('${2:-}')
"
}

cfg_set() {
    # cfg_set <key> <value>  - set a scalar value in config.json
    [[ $DRY_RUN -eq 1 ]] && { info "[DRY-RUN] config set $1 = $2"; return; }
    py_json "
import json
d = json.load(open('${CONFIG}'))
keys = '$1'.split('.')
obj = d
for k in keys[:-1]:
    obj = obj.setdefault(k, {})
obj[keys[-1]] = '$2'
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
}

cfg_del() {
    # cfg_del <key> - remove a key from config.json
    [[ $DRY_RUN -eq 1 ]] && { info "[DRY-RUN] config del $1"; return; }
    py_json "
import json
d = json.load(open('${CONFIG}'))
keys = '$1'.split('.')
obj = d
for k in keys[:-1]:
    obj = obj.get(k, {})
obj.pop(keys[-1], None)
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
}

cfg_init() {
    [[ -f "$CONFIG" ]] && return
    py_json "
import json
d = {
    'version': '${VERSION}',
    'config_schema': 3,
    'mode': 'open',
    'enabled_ports': [],
    'port_groups': {},
    'open_extents': [],
    'groups': {},
    'seen_initiators': {},
    'isp_params': {
        'ISP2432': {'default': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0'},
        'ISP2532': {'default': 'qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0'},
        'ISP2322': {'default': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0'},
        'DEFAULT': {'default': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0'}
    },
    'isp_active_profile': {},
    'wwn_names': {},
    'firmware': {},
    'initscript_preinit_id': None,
    'boot_mode': 'grub',
    'rootwait_was_preexisting': False,
    'hba_identity': {},
    'hba_swap_event': None
}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print('Config initialized.')
"
}

cfg_check_schema() {
    # Hard stop if config.json predates the group-based schema (v6.0+).
    # config_schema must be present and equal to 2.
    # Absent key is treated as non-compliant (same as old installs).
    local result
    result=$(python3 - "${CONFIG}" << 'CSEOF'
import json, re, sys
WWN_RE = re.compile(r'^([0-9a-f]{2}:){7}[0-9a-f]{2}$')
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("err:read:" + str(e))
    sys.exit(0)
schema = d.get('config_schema', None)
if schema == 3:
    print("ok")
    sys.exit(0)
assignments = d.get('assignments', {})
wwn_keys = [k for k in assignments if WWN_RE.match(k.lower())]
if wwn_keys:
    print("err:old_wwn_keys")
elif schema == 2:
    print("err:schema_2")
else:
    print("err:schema_" + str(schema))
CSEOF
)
    if [[ "$result" == "ok" ]]; then
        return 0
    fi
    err "config.json is not compatible with qle_adm v${VERSION}."
    err ""
    if [[ "$result" == "err:old_wwn_keys" ]]; then
        err "The assignments section uses per-initiator WWN keys (pre-6.0 schema)."
        err "This version requires config_schema: 3 (group + port_groups schema)."
    elif [[ "$result" == "err:schema_None" || "$result" == "err:schema_1" ]]; then
        err "config_schema key is missing or set to an old value."
        err "This version requires config_schema: 2 (introduced in v6.0)."
    else
        err "Unexpected config state: ${result}"
    fi
    err ""
    err "To migrate your configuration to the current schema run:"
    err "  qle_adm.sh deploy migrate           # dry-run preview (default)"
    err "  qle_adm.sh deploy migrate --apply   # write changes (backs up first)"
    err ""
    err "If migration is not possible see GUIDE.md section"
    err "'Config Schema Migration' for manual steps."
    exit 1
}

cfg_get_list() {
    py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    keys = '$1'.split('.')
    v = d
    for k in keys:
        v = v[k]
    if isinstance(v, list):
        for i in v: print(i)
    elif isinstance(v, dict):
        for k in v: print(k)
except:
    pass
"
}

cfg_list_add() {
    [[ $DRY_RUN -eq 1 ]] && { info "[DRY-RUN] config list $1 add $2"; return; }
    py_json "
import json
d = json.load(open('${CONFIG}'))
keys = '$1'.split('.')
obj = d
for k in keys[:-1]:
    obj = obj.setdefault(k, {})
lst = obj.setdefault(keys[-1], [])
if '$2' not in lst:
    lst.append('$2')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
}

cfg_list_remove() {
    [[ $DRY_RUN -eq 1 ]] && { info "[DRY-RUN] config list $1 remove $2"; return; }
    py_json "
import json
d = json.load(open('${CONFIG}'))
keys = '$1'.split('.')
obj = d
for k in keys[:-1]:
    obj = obj.setdefault(k, {})
lst = obj.get(keys[-1], [])
if '$2' in lst:
    lst.remove('$2')
obj[keys[-1]] = lst
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
}

cfg_record_seen_initiator() {
    local wwn="$1"
    [[ $DRY_RUN -eq 1 ]] && return
    py_json "
import json
from datetime import datetime
d = json.load(open('${CONFIG}'))
seen = d.setdefault('seen_initiators', {})
seen['${wwn}'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
}

# ─── Interactive confirmation ──────────────────────────────────────────────────
confirm() {
    local msg="$1"
    if [[ $YES -eq 1 || $DRY_RUN -eq 1 ]]; then
        info "[AUTO-YES] ${msg}"
        return 0
    fi
    echo -en "${YLW}?${NC}  ${msg} [y/N] "
    local reply
    read -r reply || true
    [[ "$reply" =~ ^[Yy]$ ]]
}

confirm_or_abort() {
    confirm "$1" || { info "Aborted."; exit 0; }
}

# ─── Filesystem operations ─────────────────────────────────────────────────────
mkdir_v() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        [[ $VERBOSE -eq 1 ]] && info "Directory exists: ${dir}"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] mkdir -pv ${dir}"; return 0
    fi
    if [[ $YES -eq 1 ]]; then
        info "[AUTO-YES] Create directory: ${dir}?"
    else
        echo -en "${YLW}?${NC}  Create directory: ${dir}? [y/N] "
        local reply; read -r reply || true
        [[ "$reply" =~ ^[Yy]$ ]] || { info "Skipped: ${dir}"; return 0; }
    fi
    mkdir -pv "$dir"
    ok "Created directory: ${dir}"
    log "mkdir: ${dir}"
}

file_write() {
    local path="$1" content="$2"
    local parent; parent="$(dirname "$path")"
    local div; div="${DIM}$(hbar)${NC}"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] write file: ${path}"
        echo -e "$div"
        echo "$content"
        echo -e "$div"
        return 0
    fi

    # Ensure parent directory exists
    if [[ ! -d "$parent" ]]; then
        info "Creating parent directory: ${parent}"
        mkdir -pv "$parent" || { err "Failed to create directory: ${parent}"; return 1; }
        ok "Created directory: ${parent}"
        log "mkdir: ${parent}"
    fi

    # Remove broken symlink
    if [[ -L "$path" && ! -e "$path" ]]; then
        warn "Removing broken symlink: ${path}"
        rm -fv "$path"
        log "removed broken symlink: ${path}"
    fi

    if [[ -f "$path" ]]; then
        # Show existing and new content before prompting
        if [[ $YES -eq 1 ]]; then
            info "[AUTO-YES] Overwrite file: ${path}?"
        else
            echo -e "
${YLW}Existing:${NC} ${path}"
            echo -e "$div"
            cat "$path"
            echo -e "$div"
            echo -e "${GRN}New content:${NC}"
            echo -e "$div"
            echo "$content"
            echo -e "$div"
            echo -en "${YLW}?${NC}  Overwrite file: ${path}? [y/N] "
            local reply; read -r reply || true
            [[ "$reply" =~ ^[Yy]$ ]] || { info "Skipped: ${path}"; return 0; }
        fi
    else
        # Show new content before prompting
        if [[ $YES -eq 1 ]]; then
            info "[AUTO-YES] Create file: ${path}?"
        else
            echo -e "
${CYN}New file:${NC} ${path} ${DIM}(does not exist)${NC}"
            echo -e "$div"
            echo "$content"
            echo -e "$div"
            echo -en "${YLW}?${NC}  Create file: ${path}? [y/N] "
            local reply; read -r reply || true
            [[ "$reply" =~ ^[Yy]$ ]] || { info "Skipped: ${path}"; return 0; }
        fi
    fi

    echo "$content" > "$path"
    ok "Wrote file: ${path}"
    log "wrote: ${path}"
}

rm_f_v() {
    local path="$1"
    [[ ! -e "$path" ]] && { [[ $VERBOSE -eq 1 ]] && info "Not found (skip): ${path}"; return 0; }
    if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] rm -fv ${path}"; return 0; fi
    confirm "Delete file: ${path}?" || { info "Skipped: ${path}"; return 0; }
    rm -fv "$path"; ok "Deleted: ${path}"; log "rm: ${path}"
}

rm_rf_v() {
    local path="$1"
    [[ ! -e "$path" ]] && { [[ $VERBOSE -eq 1 ]] && info "Not found (skip): ${path}"; return 0; }
    if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] rm -rfv ${path}"; return 0; fi
    confirm "Delete directory and contents: ${path}?" || { info "Skipped: ${path}"; return 0; }
    rm -rfv "$path"; ok "Deleted: ${path}"; log "rm -rf: ${path}"
}

symlink_v() {
    local target="$1" link="$2"
    if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] ln -sfv ${target} ${link}"; return 0; fi
    confirm "Create symlink: ${link} -> ${target}?" || { info "Skipped: ${link}"; return 0; }
    ln -sfv "$target" "$link"; ok "Symlink: ${link} -> ${target}"; log "symlink: ${link} -> ${target}"
}

copy_v() {
    local src="$1" dst="$2"
    if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] cp -v ${src} ${dst}"; return 0; fi
    [[ -f "$dst" ]] && confirm "Overwrite: ${dst}?" || confirm "Copy ${src} -> ${dst}?" || { info "Skipped."; return 0; }
    cp -v "$src" "$dst"; ok "Copied: ${src} -> ${dst}"; log "cp: ${src} -> ${dst}"
}

run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] $*"; return 0; fi
    [[ $VERBOSE -eq 1 ]] && info "Run: $*"
    log "run: $*"
    "$@"
}

# ─── Sysfs helpers ────────────────────────────────────────────────────────────
sysfs_write() {
    local path="$1" val="$2"
    if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] echo '$val' > $path"; return 0; fi
    if [[ ! -e "$path" ]]; then err "sysfs path not found: $path"; return 1; fi
    echo "$val" > "$path" 2>/dev/null || { err "Failed to write '$val' to $path"; return 1; }
    log "sysfs: $path = $val"
}

# Read current sysfs value and only write if it differs.
# Prevents EINVAL errors from writing a value already set (e.g. enabled=1 when already 1).
sysfs_write_if_changed() {
    local path="$1" val="$2"
    if [[ $DRY_RUN -eq 1 ]]; then info "[DRY-RUN] sysfs_write_if_changed '$val' > $path"; return 0; fi
    if [[ ! -e "$path" ]]; then err "sysfs path not found: $path"; return 1; fi
    local current
    current=$(cat "$path" 2>/dev/null | tr -d '[:space:]' || echo "")
    if [[ "$current" == "$val" ]]; then
        [[ $VERBOSE -eq 1 ]] && info "sysfs: $path already $val - skipping"
        return 0
    fi
    echo "$val" > "$path" 2>/dev/null || { err "Failed to write '$val' to $path (current: $current)"; return 1; }
    log "sysfs: $path = $val (was: $current)"
}

sysfs_read() {
    local path="$1"
    [[ -r "$path" ]] && cat "$path" 2>/dev/null | tr -d '\n' || echo ""
}

hex_to_dec() {
    local val="${1:-0}"
    printf "%d" "$val" 2>/dev/null || echo "0"
}

# ─── WWN index resolution ─────────────────────────────────────────────────────
# Ports are indexed by sorted WWN order - stable across reboots (tied to HW)
# Initiators are indexed from currently active sessions
# Extents are indexed by sorted name from scst.conf

get_port_wwns_sorted() {
    # Returns sorted list of detected FC port WWNs (one per line)
    for host_path in /sys/class/fc_host/host*; do
        [[ -d "$host_path" ]] || continue
        local wwn
        wwn=$(sysfs_read "${host_path}/port_name")
        echo "$wwn" | sed 's/0x//;s/../&:/g;s/:$//'
    done | sort
}

get_port_wwn_by_index() {
    local idx="$1"
    get_port_wwns_sorted | sed -n "$((idx + 1))p"
}

get_initiator_wwns_active() {
    # Returns sorted list of currently connected initiator WWNs
    for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
        [[ -d "$sess_path" ]] || continue
        basename "$sess_path"
    done | sort -u
}

get_initiator_wwn_by_index() {
    local idx="$1"
    get_initiator_wwns_active | sed -n "$((idx + 1))p"
}

get_extents_sorted() {
    grep -E '^\s+DEVICE\s+' "${SCST_CONF}" 2>/dev/null | awk '{print $2}' | sort -u
}

# Returns a newline-separated list of device names currently in scst.conf.
# Used for stale-assignment detection: if a config.json extent is absent
# here, the WUI removed the underlying device without qle_adm being notified.
get_scst_conf_devices() {
    grep -E '^\s+DEVICE\s+' "${SCST_CONF}" 2>/dev/null | awk '{print $2}'
}

get_extent_by_index() {
    local idx="$1"
    get_extents_sorted | sed -n "$((idx + 1))p"
}

resolve_port() {
    # resolve_port <wwn>|--port N → prints resolved WWN or exits with error
    local arg="$1" idx_arg="$2"
    if [[ -n "$arg" && -n "$idx_arg" ]]; then
        err "Specify either a WWN or --port N, not both"
        exit 1
    fi
    if [[ -n "$idx_arg" ]]; then
        local wwn
        wwn=$(get_port_wwn_by_index "$idx_arg")
        if [[ -z "$wwn" ]]; then
            err "No port at index ${idx_arg} - is qla2xxx_scst loaded? (check: ls /sys/class/fc_host/)"
            exit 1
        fi
        # Guard: result must look like a WWN (xx:xx:xx:xx:xx:xx:xx:xx).
        # If fc_host is empty, get_port_wwns_sorted returns nothing and
        # sed -n Np returns empty — caught above.  This catches any other
        # case where a non-WWN string slips through.
        if [[ ! "$wwn" =~ ^([0-9a-fA-F]{2}:){7}[0-9a-fA-F]{2}$ ]]; then
            err "Resolved value '${wwn}' for port ${idx_arg} is not a valid WWN - module may not be loaded"
            exit 1
        fi
        info "Port ${idx_arg} resolved to: ${wwn}"
        echo "$wwn"
    else
        echo "$arg"
    fi
}

resolve_group() {
    # Resolves a group name to a config.json assignments key.
    # Accepts a named group string or a bare WWN (for single-initiator groups).
    local arg="$1"
    if [[ -z "$arg" ]]; then
        err "No group name or WWN specified"
        exit 1
    fi
    local exists
    exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${arg}' in d.get('groups', {}) else 'no')
except: pass
")
    if [[ "$exists" != "yes" ]]; then
        err "Group '${arg}' not found in config.json"
        err "Use 'group create <name>' to define a new group, or 'list-mapping' to see existing ones."
        exit 1
    fi
    echo "$arg"
}

resolve_extent() {
    local arg="$1" idx_arg="$2"
    if [[ -n "$arg" && -n "$idx_arg" ]]; then
        err "Specify either an extent name or --ext N, not both"
        exit 1
    fi
    if [[ -n "$idx_arg" ]]; then
        local ext
        ext=$(get_extent_by_index "$idx_arg")
        [[ -z "$ext" ]] && { err "No extent at index ${idx_arg}"; exit 1; }
        info "Extent ${idx_arg} resolved to: ${ext}"
        echo "$ext"
    else
        echo "$arg"
    fi
}

# ─── HBA detection ────────────────────────────────────────────────────────────
detect_hbas() {
    local idx=0
    for wwn in $(get_port_wwns_sorted); do
        # Find host for this WWN
        local host_num=""
        for host_path in /sys/class/fc_host/host*; do
            [[ -d "$host_path" ]] || continue
            local hwwn
            hwwn=$(sysfs_read "${host_path}/port_name" | sed 's/0x//;s/../&:/g;s/:$//')
            [[ "$hwwn" == "$wwn" ]] && host_num=$(basename "$host_path") && break
        done
        [[ -z "$host_num" ]] && continue
        local scsi_host="/sys/class/scsi_host/${host_num}"
        local port_state port_type fw_raw fw_ver pci_addr isp_type
        port_state=$(sysfs_read "/sys/class/fc_host/${host_num}/port_state")
        port_type=$(sysfs_read  "/sys/class/fc_host/${host_num}/port_type")
        fw_raw=$(sysfs_read "${scsi_host}/fw_version" 2>/dev/null || echo "unknown")
        fw_ver=$(echo "$fw_raw" | awk '{print $1}')
        pci_addr=$(readlink -f "${scsi_host}/device" 2>/dev/null | grep -oP '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | tail -1 || echo "unknown")
        # Prefer dmesg for ISP type; fall back to model_name sysfs attr which
        # contains strings like "QLE2562" from which the ISP type is derivable.
        isp_type=$(dmesg 2>/dev/null | grep "${pci_addr}" | grep -oP 'ISP\d+' | head -1)
        if [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]]; then
            local model_name
            model_name=$(cat "${scsi_host}/model_name" 2>/dev/null || cat "${scsi_host}/board_name" 2>/dev/null || echo "")
            case "$model_name" in
                *QLE2562*|*QLE2564*|*AJ764*) isp_type="ISP2532" ;;
                *QLE2462*|*QLE2460*)         isp_type="ISP2432" ;;
                *QLE2360*|*QLE2362*)         isp_type="ISP2322" ;;
                *QLE2342*|*QLE2340*)         isp_type="ISP2300" ;;
                *) isp_type="UNKNOWN" ;;
            esac
        fi
        echo "${idx} ${host_num} ${pci_addr} ${isp_type} ${wwn} ${fw_ver} ${port_state} ${port_type}"
        idx=$((idx + 1))
    done
}

dmesg_isp_type() {
    # Scan dmesg for ISP type without requiring fc_host entries.
    # Returns the most-frequent ISP type seen since last boot, or empty string.
    # Works even after rmmod, as long as the module loaded at least once this boot.
    dmesg 2>/dev/null \
        | grep -oP 'Found an ISP\K\d+' \
        | sort | uniq -c | sort -rn \
        | awk 'NR==1{print "ISP"$2}'
}

cached_isp_type() {
    # Returns hba_identity.isp_type from config.json, or empty string.
    py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print(d.get('hba_identity', {}).get('isp_type', ''))
except: print('')
"
}

get_isp_type_dominant() {
    # Returns the ISP type used by all target-capable ports.
    # Three-tier fallback:
    #   1. fc_host sysfs (most authoritative; requires module loaded)
    #   2. dmesg direct scan (works after rmmod; fails only on first-ever boot)
    #   3. hba_identity cache in config.json (survives across boots)
    #   4. ISP2532 hard default (last resort)
    # NOTE: warn() writes to stdout; all warn calls here redirect to stderr
    # so callers using $(...) capture only the clean ISP type string.

    # Tier 1: fc_host sysfs
    local all_types
    all_types=$(detect_hbas | awk '{print $4}' | grep -v UNKNOWN | sort | uniq -c | sort -rn)
    if [[ -n "$all_types" ]]; then
        local distinct
        distinct=$(echo "$all_types" | wc -l | tr -d ' ')
        if [[ "$distinct" -gt 1 ]]; then
            warn "Multiple ISP types detected: $(echo "$all_types" | awk '{print $2}' | tr '\n' ' ')" >&2
            warn "Module params will use the most common type - verify with 'module status'" >&2
        fi
        echo "$all_types" | awk '{print $2}' | head -1
        return
    fi

    # Tier 2: dmesg direct scan
    local dmesg_type
    dmesg_type=$(dmesg_isp_type)
    if [[ -n "$dmesg_type" ]]; then
        warn "fc_host unavailable - ISP type from dmesg: ${dmesg_type}" >&2
        echo "$dmesg_type"
        return
    fi

    # Tier 3: cached value in config.json hba_identity
    local cached
    cached=$(cached_isp_type)
    if [[ -n "$cached" ]]; then
        warn "fc_host and dmesg unavailable - ISP type from config cache: ${cached}" >&2
        echo "$cached"
        return
    fi

    # Tier 4: hard default
    warn "Could not determine ISP type from any source - defaulting to ISP2532" >&2
    echo "ISP2532"
}

# _hba_identity_write <isp_type> <port_count> <wwns_json_array>
# Updates hba_identity in config.json with the currently detected hardware.
# Called by deploy reconfigure (registration) and preinit/hba swap (migration).
_hba_identity_write() {
    local isp_type="$1" port_count="$2" wwns_json="$3"
    local model now
    model=$(dmesg 2>/dev/null | grep -oP 'QLogic \K[^\s]+(?= -)' | head -1 || echo "")
    now=$(date -u +"%Y-%m-%dT%H:%M:%S")
    py_json "
import json
d = json.load(open('${CONFIG}'))
d['hba_identity'] = {
    'isp_type':      '${isp_type}',
    'port_count':    ${port_count},
    'port_wwns':     ${wwns_json},
    'model':         '${model}',
    'registered_at': '${now}'
}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
}

get_module_params() {
    # Returns the expanded param string for the given ISP type and profile.
    # The profile name is always resolved to its param string — the name
    # itself is never returned (fixes Bug 1/2: 'default' leaking as output).
    # A stored value that contains no '=' is treated as corrupt/unset and
    # the built-in FALLBACK for the ISP type is returned instead.
    local isp_type="$1" profile_override="${2:-}"
    py_json "
import json
BUILTINS = {
    'ISP2432': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
    'ISP2532': 'qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
    'ISP2322': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
    'DEFAULT': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
}
FALLBACK = BUILTINS.get('${isp_type}', BUILTINS['DEFAULT'])
try:
    d = json.load(open('${CONFIG}'))
    isp_map = d.get('isp_params', {})
    entry = isp_map.get('${isp_type}', isp_map.get('DEFAULT', {}))
    active = d.get('isp_active_profile', {}).get('${isp_type}', 'default')
    profile_name = '${profile_override}' if '${profile_override}' else active
    value = entry.get(profile_name, entry.get('default', FALLBACK))
    # If stored value is not a param string (no '='), use the built-in for this ISP
    if '=' not in str(value):
        value = FALLBACK
    print(value)
except:
    print(FALLBACK)
"
}

get_applied_params() {
    # Read actual running module parameters from sysfs.
    # Returns reconstructed param string, or empty if module not loaded.
    # Note: qlini_mode sysfs returns a numeric value (0/1/2); normalize
    # back to the string form (disabled/enabled/dual) to match config.json.
    local mod="qla2xxx_scst"
    module_loaded "$mod" || { echo ""; return; }
    local base="/sys/module/${mod}/parameters"
    local result=""
    local qlini; qlini=$(cat "${base}/qlini_mode"     2>/dev/null || echo "")
    local fc2;   fc2=$(cat "${base}/ql2xfc2target"    2>/dev/null || echo "")
    local nvme;  nvme=$(cat "${base}/ql2xnvmeenable"  2>/dev/null || echo "")
    local fwbin; fwbin=$(cat "${base}/ql2xfwloadbin"  2>/dev/null || echo "")
    # Normalize qlini_mode numeric -> string
    case "$qlini" in
        0) qlini="disabled" ;;
        1) qlini="enabled"  ;;
        2) qlini="dual"     ;;
    esac
    [[ -n "$qlini" ]] && result+="qlini_mode=${qlini} "
    [[ -n "$fc2"   ]] && result+="ql2xfc2target=${fc2} "
    [[ -n "$nvme"  ]] && result+="ql2xnvmeenable=${nvme} "
    [[ -n "$fwbin" ]] && result+="ql2xfwloadbin=${fwbin} "
    echo "${result% }"
}

# ─── WWN naming helpers ───────────────────────────────────────────────────────

# wwn_port_index <wwn>
# For local HBA ports: derive port index from PCI function number via sysfs.
# For remote ports: look up stored port index in wwn_names config.
wwn_port_index() {
    local wwn="$1"
    # Check sysfs for local HBA port - find fc_host whose port_name matches
    for h in /sys/class/fc_host/host*; do
        local pname; pname=$(cat "${h}/port_name" 2>/dev/null | sed 's/0x//' | \
            sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6:\7:\8/')
        if [[ "$pname" == "$wwn" ]]; then
            # Get PCI address, extract function number from deepest path component
            local pci; pci=$(readlink -f "${h}/device" 2>/dev/null | \
                grep -oP '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.\K[0-9]+' | tail -1 || echo "")
            [[ -n "$pci" ]] && echo "$pci" && return
        fi
    done
    # Fall back to stored port index in config
    py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    entry = d.get('wwn_names', {}).get('${wwn}', {})
    print(entry.get('port', 0))
except:
    print(0)
"
}

# wwn_label <wwn> [role_hint]
# Returns: "name:N" if named, "role:N" if unnamed. role_hint = target|initiator
wwn_label() {
    local wwn="$1" role_hint="${2:-}"
    local name role port
    name=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    e = d.get('wwn_names', {}).get('${wwn}', {})
    print(e.get('name', ''))
except: print('')
")
    role=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    e = d.get('wwn_names', {}).get('${wwn}', {})
    print(e.get('role', '${role_hint}') or '${role_hint}')
except: print('${role_hint}')
")
    port=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    e = d.get('wwn_names', {}).get('${wwn}', {})
    v = e.get('port', None)
    print(str(v) if v is not None else 'LOOKUP')
except: print('LOOKUP')
")
    [[ "$port" == "LOOKUP" ]] && port=$(wwn_port_index "$wwn")
    local label="${name:-${role:-node}}"
    echo "${label}:${port}"
}

cmd_name() {
    local subcmd="${1:-list}"; shift || true
    case "$subcmd" in
        list)
            hdr "WWN Names"
            py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    names = d.get('wwn_names', {})
    if not names:
        print('  (none)')
    else:
        for wwn, entry in sorted(names.items()):
            name = entry.get('name', '')
            role = entry.get('role', '')
            port = entry.get('port', 0)
            label = name if name else f'({role})'
            print(f'  {wwn}  {label}:{port}  [{role}]')
except Exception as e:
    print(f'  error: {e}')
" || true
            ;;
        set)
            # name set <wwn> <name> [--port N]
            local wwn="${1:-}" name="${2:-}"; shift 2 || true
            local port=""
            [[ "${1:-}" == "--port" ]] && { port="${2:-0}"; shift 2 || true; }
            [[ -z "$wwn" || -z "$name" ]] && { err "Usage: name set <wwn> <name> [--port N]"; return 1; }
            # Determine role: local HBA port = target, else initiator
            local role="initiator"
            for h in /sys/class/fc_host/host*; do
                local pname; pname=$(cat "${h}/port_name" 2>/dev/null | sed 's/0x//' | \
                    sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6:\7:\8/')
                [[ "$pname" == "$wwn" ]] && role="target" && break
            done
            # Resolve port index
            if [[ -z "$port" ]]; then
                if [[ "$role" == "target" ]]; then
                    port=$(wwn_port_index "$wwn")
                else
                    # For remote: check if another WWN already uses this name, assign next port
                    port=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    used = [e.get('port',0) for w,e in d.get('wwn_names',{}).items()
            if e.get('name')=='${name}' and w != '${wwn}']
    print(max(used)+1 if used else 0)
except: print(0)
")
                fi
            fi
            py_json "
import json
d = json.load(open('${CONFIG}'))
entry = d.setdefault('wwn_names', {}).setdefault('${wwn}', {})
entry['name'] = '${name}'
entry['role'] = '${role}'
entry['port'] = ${port}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Named ${wwn} ${SYM_INFO} ${name}:${port} [${role}]"
            ;;
        get)
            local wwn="${1:-}"
            [[ -z "$wwn" ]] && { err "Usage: name get <wwn>"; return 1; }
            py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    e = d.get('wwn_names',{}).get('${wwn}',{})
    if e:
        print(f\"{e.get('name','')}:{e.get('port',0)} [{e.get('role','')}]\")
    else:
        print('(not named)')
except: pass
" || true
            ;;
        del)
            local wwn="${1:-}"
            [[ -z "$wwn" ]] && { err "Usage: name del <wwn>"; return 1; }
            py_json "
import json
d = json.load(open('${CONFIG}'))
d.get('wwn_names',{}).pop('${wwn}', None)
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Removed name for ${wwn}"
            ;;
        *) err "Unknown subcommand: ${subcmd}" ;;
    esac
}



# auto_name_target_ports
# Names all detected target port WWNs using the short hostname and port index.
# Only names ports that have no existing entry in wwn_names - never overwrites
# a name set manually by the operator. Safe to call on every boot (idempotent).
auto_name_target_ports() {
    local hostname_short
    hostname_short=$(hostname -s 2>/dev/null || echo "nas")
    local named=0 skipped=0
    while IFS= read -r hba_line; do
        local idx wwn
        idx=$(echo "$hba_line" | awk '{print $1}')
        wwn=$(echo "$hba_line" | awk '{print $5}')
        [[ -z "$wwn" ]] && continue
        # Check whether this WWN already has a name entry
        local existing
        existing=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    e = d.get('wwn_names', {}).get('${wwn}', {})
    print(e.get('name', ''))
except: pass
")
        if [[ -n "$existing" ]]; then
            [[ $VERBOSE -eq 1 ]] && info "Target ${wwn} already named '${existing}' - skipping"
            skipped=$((skipped + 1))
            continue
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            info "[DRY-RUN] Would name ${wwn} -> ${hostname_short}:${idx} [target]"
            named=$((named + 1))
            continue
        fi
        py_json "
import json
d = json.load(open('${CONFIG}'))
entry = d.setdefault('wwn_names', {}).setdefault('${wwn}', {})
entry['name'] = '${hostname_short}'
entry['role'] = 'target'
entry['port'] = int('${idx}')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
        ok "Named target port ${wwn} -> ${hostname_short}:${idx}"
        named=$((named + 1))
    done < <(detect_hbas)
    [[ $named -eq 0 && $skipped -gt 0 ]] && info "Target ports already named - no changes made" || true
}

scst_target_path() { echo "/sys/kernel/scst_tgt/targets/qla2x00t/${1}"; }

scst_enable_target() {
    local wwn="$1" idx="$2"
    local tgt_path; tgt_path=$(scst_target_path "$wwn")
    [[ -d "$tgt_path" ]] || { warn "SCST target path not found for ${wwn}"; return 0; }

    # Set unique rel_tgt_id before enabling (fixes "Relative target id not unique")
    # Use base 10 to avoid collision with iSCSI targets which typically occupy 1-9
    local rel_id=$(( idx + 10 ))
    local rel_path="${tgt_path}/rel_tgt_id"
    if [[ -e "$rel_path" ]]; then
        sysfs_write_if_changed "$rel_path" "$rel_id" || true
    fi

    sysfs_write_if_changed "${tgt_path}/enabled" "1"
}

scst_record_sessions() {
    # Record any currently connected initiators to seen_initiators in config
    for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
        [[ -d "$sess_path" ]] || continue
        local wwn; wwn=$(basename "$sess_path")
        cfg_record_seen_initiator "$wwn"
    done
}

# ─── Firmware helpers ─────────────────────────────────────────────────────────

# fw_version_dir <isp_type> <version>
# Returns the path to a versioned firmware directory.
fw_version_dir() { echo "${FIRMWARE_DIR}/${1}/${2}"; }

# fw_version_file <isp_type> <version>
# Returns the path to the firmware binary in a versioned directory.
fw_version_file() { echo "${FIRMWARE_DIR}/${1}/${2}/${ISP_FW_FILE[$1]:-}"; }

# fw_extract_version <file>
# Extracts the version string from a firmware binary.
fw_extract_version() {
    strings "$1" 2>/dev/null | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown"
}

# fw_selected <isp_type>
# Returns the selected firmware source for an ISP type from config.json.
# Default is "hba" if not set.
fw_selected() {
    py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print(d.get('firmware', {}).get('${1}', {}).get('selected', 'hba'))
except: print('hba')
"
}

# fw_set_selected <isp_type> <value>
# Sets the selected firmware source in config.json.
fw_set_selected() {
    py_json "
import json
d = json.load(open('${CONFIG}'))
d.setdefault('firmware', {}).setdefault('${1}', {})['selected'] = '${2}'
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
}

# fw_dist_marker <isp_type> <version_dir>
# Returns the os marker filename if one exists in the version dir, else empty.
fw_dist_marker() {
    find "${1}/${2}/" -maxdepth 1 -name "os_*" -printf "%f\n" 2>/dev/null | head -1 || true
}

# fw_store_versioned <isp_type> <src_file> <base_ver> <source_tag>
# Stores a firmware file in the versioned directory structure.
# <source_tag> is one of: os, hba, imported — used for disambiguation on collision.
# Result (final version directory name) is written to global _FW_STORED_VER.
# Do NOT call in a subshell - ok/warn messages print to terminal directly.
_FW_STORED_VER=""
fw_store_versioned() {
    local isp_type="$1" src_file="$2" base_ver="$3" source_tag="$4"
    local fw_file="${ISP_FW_FILE[$isp_type]:-}"
    local dest_ver="$base_ver"
    local dest_dir="${FIRMWARE_DIR}/${isp_type}/${dest_ver}"
    local dest_file="${dest_dir}/${fw_file}"

    if [[ -d "$dest_dir" && -f "$dest_file" ]]; then
        local sha_new sha_existing
        sha_new=$(sha256sum "$src_file" 2>/dev/null | awk '{print $1}')
        sha_existing=$(sha256sum "$dest_file" 2>/dev/null | awk '{print $1}')
        if [[ "$sha_new" == "$sha_existing" ]]; then
            ok "Version ${base_ver} already stored - content identical (SHA256 match), skipping"
            _FW_STORED_VER="$dest_ver"
            return 0
        else
            warn "Version ${base_ver} already stored but content differs (SHA256 mismatch)"
            warn "Existing: ${dest_file}"
            warn "Storing new file as ${base_ver}-${source_tag} to preserve both"
            dest_ver="${base_ver}-${source_tag}"
            dest_dir="${FIRMWARE_DIR}/${isp_type}/${dest_ver}"
            dest_file="${dest_dir}/${fw_file}"
        fi
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$dest_dir"
        cp "$src_file" "$dest_file"
        ok "Stored ${isp_type} firmware v${dest_ver} ${SYM_INFO} ${dest_file}"
    else
        info "[DRY-RUN] mkdir -p ${dest_dir} && cp ${src_file} ${dest_file}"
    fi
    _FW_STORED_VER="$dest_ver"
}


# Copies the selected firmware version into /usr/lib/firmware/ and returns
# the ql2xfwloadbin value to use (0=hba, 2=filesystem).
# Modifies the caller's $params variable is NOT done here - caller must
# strip and set ql2xfwloadbin based on return value.
inject_firmware() {
    local isp_type="$1"
    local fw_file="${ISP_FW_FILE[$isp_type]:-}"
    [[ -z "$fw_file" ]] && { echo "0"; return; }

    local selected; selected=$(fw_selected "$isp_type")

    if [[ "$selected" == "hba" ]]; then
        echo "0"
        return
    fi

    local src_file=""
    if [[ "$selected" == "dist" ]]; then
        # Find the dist-marked version directory
        local dist_ver=""
        for vdir in "${FIRMWARE_DIR}/${isp_type}/"/*/; do
            [[ -d "$vdir" ]] || continue
            local marker; marker=$(find "$vdir" -maxdepth 1 -name "os_*" 2>/dev/null | head -1)
            if [[ -n "$marker" ]]; then
                dist_ver=$(basename "$vdir")
                break
            fi
        done
        if [[ -z "$dist_ver" ]]; then
            warn "No OS dist firmware saved for ${isp_type} - using HBA flash (run 'fw save-os' to capture)"
            echo "0"
            return
        fi
        src_file="${FIRMWARE_DIR}/${isp_type}/${dist_ver}/${fw_file}"
    else
        src_file="${FIRMWARE_DIR}/${isp_type}/${selected}/${fw_file}"
    fi

    if [[ ! -f "$src_file" ]]; then
        warn "Selected firmware file not found: ${src_file} - using HBA flash"
        echo "0"
        return
    fi

    local ver; ver=$(fw_extract_version "$src_file")
    info "Injecting firmware ${isp_type} v${ver} ${SYM_INFO} /usr/lib/firmware/${fw_file}"
    if [[ $DRY_RUN -eq 0 ]]; then
        cp "$src_file" "/usr/lib/firmware/${fw_file}"
    else
        info "[DRY-RUN] cp ${src_file} /usr/lib/firmware/${fw_file}"
    fi
    echo "2"
}


# ─── Module management ────────────────────────────────────────────────────────
module_loaded() { [[ -d "/sys/module/${1}" ]]; }

load_target_module() {
    local isp_type="$1"
    local params; params=$(get_module_params "$isp_type")
    # Strip ql2xfwloadbin from base params - inject_firmware sets the correct value.
    params=$(echo "$params" | sed 's/ql2xfwloadbin=[^ ]*//g' | tr -s ' ' | sed 's/^ //;s/ $//')
    local fwbin; fwbin=$(inject_firmware "$isp_type")
    params="${params} ql2xfwloadbin=${fwbin}"
    info "Loading qla2xxx_scst: ${params}"
    if [[ $DRY_RUN -eq 0 ]]; then
        modprobe -r qla2xxx 2>/dev/null || true
        modprobe -r qla2xxx_scst 2>/dev/null || true
        sleep 1
        local boot_mode; boot_mode=$(cfg_get 'boot_mode' 'grub')
        if [[ "$boot_mode" == "blacklist" ]]; then
            modprobe -i qla2xxx_scst $params
        else
            modprobe qla2xxx_scst $params
        fi
        log "loaded qla2xxx_scst params=${params}"
    else
        info "[DRY-RUN] modprobe -r qla2xxx"
        info "[DRY-RUN] modprobe qla2xxx_scst ${params}"
    fi
}

# ─── Kernel extra options helpers ─────────────────────────────────────────────
# Tokens qle_adm owns (all modes): module params use qla2xxx_scst.<param>=<val>
# syntax for per-module kernel cmdline delivery. module_blacklist=qla2xxx_scst
# is owned in blacklist mode only. rootwait is owned in grub/blacklist modes.
#
# Owned token prefixes/values (used by parser to partition foreign vs owned):
#   qla2xxx_scst.*=*
#   module_blacklist=qla2xxx_scst
#   rootwait

GRUB_OWNED_PARAMS=(
    "qlini_mode"
    "ql2xfc2target"
    "ql2xnvmeenable"
    "ql2xfwloadbin"
)

# grub_read_current: returns the current kernel_extra_options string
grub_read_current() {
    midclt call system.advanced.config 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('kernel_extra_options', ''))
" 2>/dev/null || echo ""
}

# grub_parse <string>
# Partitions tokens into owned and foreign.
# Prints two lines: "OWNED:<space-sep owned tokens>" and "FOREIGN:<space-sep foreign tokens>"
grub_parse() {
    local opts="$1"
    python3 << PYEOF
import sys
opts = """${opts}"""
tokens = opts.split()
owned_prefixes = ["qla2xxx_scst.", "module_blacklist=qla2xxx_scst"]
owned = []
foreign = []
for t in tokens:
    is_owned = False
    for p in owned_prefixes:
        if t.startswith(p):
            is_owned = True
            break
    if t == "rootwait":
        is_owned = True
    if is_owned:
        owned.append(t)
    else:
        foreign.append(t)
print("OWNED:" + " ".join(owned))
print("FOREIGN:" + " ".join(foreign))
PYEOF
}

# grub_compose_tokens <boot_mode> <isp_type> <params_string>
# Builds the full set of owned tokens appropriate for the given mode.
# Prints one token per line.
grub_compose_owned() {
    local mode="$1" isp_type="$2" params="$3"
    python3 << PYEOF
mode = """${mode}"""
params_str = """${params}"""

# Parse isp params into key=val dict
param_map = {}
for tok in params_str.split():
    if '=' in tok:
        k, v = tok.split('=', 1)
        param_map[k] = v

tokens = []

if mode in ("grub", "blacklist"):
    tokens.append("rootwait")

if mode == "grub":
    for k in ["qlini_mode", "ql2xfc2target", "ql2xnvmeenable", "ql2xfwloadbin"]:
        if k in param_map:
            tokens.append(f"qla2xxx_scst.{k}={param_map[k]}")

if mode == "blacklist":
    tokens.append("module_blacklist=qla2xxx_scst")

for t in tokens:
    print(t)
PYEOF
}

# grub_detect_conflicts <foreign_tokens> <new_owned_tokens>
# Warns if a foreign token looks like it conflicts with an owned one.
grub_detect_conflicts() {
    local foreign="$1" owned="$2"
    python3 << PYEOF
foreign = """${foreign}""".split()
owned_keys = {"qlini_mode", "ql2xfc2target", "ql2xnvmeenable", "ql2xfwloadbin",
              "module_blacklist", "rootwait"}
conflicts = []
for t in foreign:
    key = t.split('=')[0].lstrip('-')
    if key in owned_keys:
        conflicts.append(t)
for c in conflicts:
    print(c)
PYEOF
}

# grub_apply <new_options_string>
# Calls middleware to write the new kernel_extra_options string.
grub_apply() {
    local new_opts="${1:-}"
    if [[ $DRY_RUN -eq 0 ]]; then
        # Some middleware versions reject a missing key; always send the field,
        # using an empty string when all owned tokens have been removed.
        local payload
        payload=$(printf '{"kernel_extra_options":"%s"}' "$new_opts")
        if midclt call system.advanced.update "$payload" >/dev/null 2>&1; then
            ok "kernel_extra_options applied: ${new_opts:-<empty>}"
        else
            # Retry with explicit empty string in case the payload quoting failed
            if [[ -z "$new_opts" ]] && midclt call system.advanced.update \
                    '{"kernel_extra_options":""}' >/dev/null 2>&1; then
                ok "kernel_extra_options applied: <empty>"
            else
                err "Failed to apply kernel_extra_options via middleware"
                return 1
            fi
        fi
    else
        info "[DRY-RUN] midclt call system.advanced.update '{\"kernel_extra_options\":\"${new_opts}\"}'"
    fi
}

# grub_show_diff <before> <after> [step_label]
# Prints a before/after diff of the kernel options string.
grub_show_diff() {
    local before="$1" after="$2" label="${3:-}"
    [[ -n "$label" ]] && echo -e "  ${CYN}${label}${NC}"
    echo -e "  ${CYN}kernel_extra_options:${NC}"
    echo -e "  ${YLW}Before:${NC} ${before:-<empty>}"
    echo -e "  ${GRN}After: ${NC} ${after:-<empty>}"
    echo ""
}

# grub_install_mode <mode> <isp_type> <params> [step_label] [confirm_msg]
# Computes new options string for the given mode, shows diff, confirms, applies.
# Also updates rootwait_was_preexisting in config.
grub_install_mode() {
    local mode="$1" isp_type="$2" params="$3"
    local step_label="${4:-}" confirm_msg="${5:-Apply these kernel_extra_options changes?}"
    local current; current=$(grub_read_current)

    local parsed; parsed=$(grub_parse "$current")
    local foreign; foreign=$(echo "$parsed" | grep '^FOREIGN:' | cut -d: -f2-)
    local existing_owned; existing_owned=$(echo "$parsed" | grep '^OWNED:' | cut -d: -f2-)

    # Detect conflicts in foreign tokens
    local new_owned_tokens; new_owned_tokens=$(grub_compose_owned "$mode" "$isp_type" "$params")
    local conflicts; conflicts=$(grub_detect_conflicts "$foreign" "$new_owned_tokens")
    if [[ -n "$conflicts" ]]; then
        warn "The following tokens in kernel_extra_options look like they may conflict with qle_adm:"
        while IFS= read -r c; do
            warn "  $c"
        done <<< "$conflicts"
        warn "These are in the 'foreign' (non-qle_adm) portion and will be left unchanged."
        warn "Remove them manually if they conflict."
    fi

    # Track rootwait pre-existence
    local rootwait_preexisting=false
    if echo "$foreign $existing_owned" | grep -qw "rootwait"; then
        # rootwait was already present before qle_adm
        if echo "$existing_owned" | grep -qw "rootwait"; then
            # we own it already, keep as-is
            rootwait_preexisting=false
        else
            rootwait_preexisting=true
        fi
    fi

    # Build new options: foreign tokens preserved, new owned tokens appended
    local new_opts
    new_opts=$(python3 << PYEOF
foreign = """${foreign}""".strip()
new_owned = """${new_owned_tokens}""".strip().split('\n') if """${new_owned_tokens}""".strip() else []
foreign_parts = foreign.split() if foreign else []
parts = foreign_parts + new_owned
print(" ".join(p for p in parts if p))
PYEOF
)

    echo ""
    grub_show_diff "$current" "$new_opts" "$step_label"
    confirm_or_abort "$confirm_msg"
    grub_apply "$new_opts"

    # Record rootwait tracking in config
    if [[ $DRY_RUN -eq 0 ]]; then
        local rw_pre_str
        [[ "$rootwait_preexisting" == "true" ]] && rw_pre_str="True" || rw_pre_str="False"
        py_json "
import json
d = json.load(open('${CONFIG}'))
d['rootwait_was_preexisting'] = ${rw_pre_str}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
" || true
    fi
}

# grub_remove_owned [step_label] [confirm_msg]
# Strips all qle_adm-owned tokens from kernel_extra_options.
# Preserves rootwait if it was pre-existing before qle_adm installed it.
grub_remove_owned() {
    local step_label="${1:-}" confirm_msg="${2:-Remove qle_adm kernel_extra_options tokens?}"
    local current; current=$(grub_read_current)
    local parsed; parsed=$(grub_parse "$current")
    local foreign; foreign=$(echo "$parsed" | grep '^FOREIGN:' | cut -d: -f2-)

    local rootwait_preexisting; rootwait_preexisting=$(cfg_get 'rootwait_was_preexisting' 'false')

    local new_opts
    new_opts=$(python3 << PYEOF
foreign = """${foreign}""".strip()
rootwait_pre = """${rootwait_preexisting}""".strip().lower() == "true"
parts = foreign.split() if foreign else []
# If rootwait was pre-existing, ensure it stays (it's in foreign already)
# If not, it was owned by qle_adm (now stripped since it's not in foreign)
print(" ".join(p for p in parts if p))
PYEOF
)

    [[ "$current" == "$new_opts" ]] && { info "No qle_adm-owned tokens found in kernel_extra_options"; return 0; }
    echo ""
    grub_show_diff "$current" "$new_opts" "$step_label"
    confirm_or_abort "$confirm_msg"
    grub_apply "$new_opts"
}

# ─── TrueNAS init script helpers ──────────────────────────────────────────────
INITSCRIPT_COMMENT_PREINIT="qle_adm FC target preinit"
INITSCRIPT_TIMEOUT=60

initscript_find_id_preinit() {
    midclt call initshutdownscript.query 2>/dev/null | python3 -c "
import json, sys
entries = json.load(sys.stdin)
for e in entries:
    if e.get('comment','') == '${INITSCRIPT_COMMENT_PREINIT}':
        print(e['id'])
        break
" 2>/dev/null || true
}

# Install or update the PREINIT entry. Prints the id on success.
initscript_install_preinit() {
    local cmd="QLE_ADM_HOME=${QLE_ADM_HOME} ${QLE_ADM_HOME}/qle_adm.sh sync --boot"
    local existing_id; existing_id=$(initscript_find_id_preinit)
    if [[ -n "$existing_id" ]]; then
        info "Updating existing PREINIT entry (id=${existing_id})"
        if [[ $DRY_RUN -eq 0 ]]; then
            midclt call initshutdownscript.update "${existing_id}" \
                "{\"type\":\"COMMAND\",\"command\":\"${cmd}\",\"when\":\"PREINIT\",\"enabled\":true,\"timeout\":${INITSCRIPT_TIMEOUT},\"comment\":\"${INITSCRIPT_COMMENT_PREINIT}\"}" \
                >/dev/null 2>&1 || true
        else
            info "[DRY-RUN] midclt call initshutdownscript.update ${existing_id} (PREINIT) ..."
        fi
        echo "$existing_id"
    else
        info "Creating PREINIT boot entry"
        if [[ $DRY_RUN -eq 0 ]]; then
            local result
            result=$(midclt call initshutdownscript.create \
                "{\"type\":\"COMMAND\",\"command\":\"${cmd}\",\"when\":\"PREINIT\",\"enabled\":true,\"timeout\":${INITSCRIPT_TIMEOUT},\"comment\":\"${INITSCRIPT_COMMENT_PREINIT}\"}" \
                2>/dev/null)
            python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$result" 2>/dev/null || true
        else
            info "[DRY-RUN] midclt call initshutdownscript.create (PREINIT) ..."
        fi
    fi
}

# Delete the PREINIT entry.
initscript_remove() {
    local preinit_id; preinit_id=$(cfg_get 'initscript_preinit_id' '')
    [[ -z "$preinit_id" ]] && preinit_id=$(initscript_find_id_preinit)
    if [[ -n "$preinit_id" ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            midclt call initshutdownscript.delete "$preinit_id" >/dev/null 2>&1 && \
                ok "Removed PREINIT entry (id=${preinit_id})" || \
                warn "Failed to remove PREINIT entry (id=${preinit_id}) - remove manually in WUI"
        else
            info "[DRY-RUN] midclt call initshutdownscript.delete ${preinit_id} (PREINIT)"
        fi
    else
        warn "No PREINIT entry found to remove"
    fi
}

# Check and report PREINIT entry state for cmd_status.
# Returns 1 if any gap found.
initscript_status() {
    local gaps=0

    # PREINIT entry
    local preinit_id; preinit_id=$(initscript_find_id_preinit)
    if [[ -n "$preinit_id" ]]; then
        local enabled
        enabled=$(midclt call initshutdownscript.query 2>/dev/null | python3 -c "
import json,sys
for e in json.load(sys.stdin):
    if str(e.get('id','')) == '${preinit_id}':
        print(e.get('enabled', False))
        break
" 2>/dev/null || echo "unknown")
        if [[ "$enabled" == "True" ]]; then
            ok "PREINIT boot entry registered (id=${preinit_id}, enabled)"
        else
            gap "PREINIT boot entry registered (id=${preinit_id}) but DISABLED - enable in WUI"
            gaps=$((gaps + 1))
        fi
    else
        gap "PREINIT boot entry missing - run 'qle_adm.sh deploy install'"
        gaps=$((gaps + 1))
    fi

    [[ $gaps -gt 0 ]] && return 1 || return 0
}



# ─── Config schema migration functions ────────────────────────────────────────
# Each function: migrate_N_to_M <config_path> <dry_run:0|1>
# Prints a summary of changes. On dry_run=0 backs up config then writes.
# Backup naming: config.json.bak, config.json.bak.1, config.json.bak.2 ...

_migrate_backup() {
    local cfg="$1"
    local bak="${cfg}.bak"
    if [[ ! -f "$bak" ]]; then
        cp "$cfg" "$bak"
        ok "Backup written: ${bak}"
    else
        local n=1
        while [[ -f "${bak}.${n}" ]]; do
            n=$((n + 1))
        done
        cp "$cfg" "${bak}.${n}"
        ok "Backup written: ${bak}.${n}"
    fi
}

migrate_1_to_2() {
    # Schema 1 → 2: per-initiator WWN-keyed assignments → group-based assignments.
    # Each old assignment entry (key = WWN) becomes a named group where:
    #   group name   = the WWN (rename with 'group rename' afterwards)
    #   initiators   = [wwn]
    #   extents, luns, pending_luns = preserved unchanged
    # config_schema set to 2, version stamped to ${VERSION}. pending_luns_version removed.
    local cfg="$1" dry_run="$2"
    local tmp_script; tmp_script=$(mktemp /tmp/qle_migrate.XXXXXX.py)
    cat > "$tmp_script" << 'PYEOF'
import json, re, sys

cfg_path   = sys.argv[1]
script_ver = sys.argv[2]   # VERSION from the shell, e.g. "6.0"
WWN_RE = re.compile(r'^([0-9a-f]{2}:){7}[0-9a-f]{2}$')

try:
    d = json.load(open(cfg_path))
except Exception as e:
    print("err:" + str(e)); sys.exit(1)

old_assignments = d.get('assignments', {})
new_assignments = {}
changes = []

for key, data in old_assignments.items():
    if WWN_RE.match(key.lower()):
        new_entry = {
            'initiators': [key],
            'extents': data.get('extents', []),
            'luns': data.get('luns', {}),
        }
        if data.get('pending_luns'):
            new_entry['pending_luns'] = data['pending_luns']
        new_assignments[key] = new_entry
        changes.append("  group '" + key + "': 1 initiator, " + str(len(new_entry['extents'])) + " extent(s)")
    else:
        new_assignments[key] = data

d['assignments'] = new_assignments
d['config_schema'] = 2
d['version'] = script_ver
d.setdefault('groups', {})
d.pop('pending_luns_version', None)

preview = json.dumps(d, indent=2)
print("ok")
for c in changes:
    print(c)
print("---JSON---")
print(preview)
PYEOF

    local result; result=$(python3 "$tmp_script" "$cfg" "${VERSION}")
    local rc=$?; rm -f "$tmp_script"
    [[ $rc -ne 0 || "$result" == err:* ]] && { err "Migration failed: ${result#err:}"; return 1; }

    # Split result: summary lines above ---JSON---, JSON below
    local summary="" json_out="" in_json=0
    while IFS= read -r line; do
        if [[ "$line" == "---JSON---" ]]; then in_json=1; continue; fi
        if [[ $in_json -eq 1 ]]; then json_out+="${line}"$'\n'
        elif [[ "$line" != "ok" ]]; then summary+="${line}"$'\n'; fi
    done <<< "$result"

    echo -e "${CYN}Changes:${NC}"
    [[ -n "$summary" ]] && echo "$summary" || echo "  (no assignments to migrate)"

    if [[ $dry_run -eq 1 ]]; then
        echo -e "${CYN}Resulting config.json (preview):${NC}"
        echo "$json_out"
        return 0
    fi

    _migrate_backup "$cfg"
    printf '%s' "$json_out" > "$cfg"
    ok "config.json written (schema 2, version ${VERSION})"
}

migrate_2_to_3() {
    # Schema 2 → 3: assignments + enabled_ports → groups + port_groups.
    # Each entry in assignments becomes a groups entry (initiators + luns preserved).
    # port_groups is built by associating all groups with all currently enabled ports
    # (preserves the "every group on every port" default; user refines afterwards).
    # assignments key is removed. config_schema set to 3, version stamped.
    local cfg="$1" dry_run="$2"
    local tmp_script; tmp_script=$(mktemp /tmp/qle_migrate.XXXXXX.py)
    cat > "$tmp_script" << 'PYEOF'
import json, sys

cfg_path   = sys.argv[1]
script_ver = sys.argv[2]

try:
    d = json.load(open(cfg_path))
except Exception as e:
    print("err:" + str(e)); sys.exit(1)

old_assignments = d.get('assignments', {})
enabled_ports   = d.get('enabled_ports', [])
new_groups      = {}
changes         = []

for grp_name, data in old_assignments.items():
    new_entry = {
        'initiators':   data.get('initiators', []),
        'luns':         data.get('luns', {}),
        'pending_luns': data.get('pending_luns', {}),
    }
    new_groups[grp_name] = new_entry
    n_inits = len(new_entry['initiators'])
    n_luns  = len(new_entry['luns'])
    changes.append(f"  group '{grp_name}': {n_inits} initiator(s), {n_luns} LUN mapping(s)")

# Build port_groups: every group on every currently enabled port
new_port_groups = {}
for port in enabled_ports:
    new_port_groups[port] = list(new_groups.keys())
    changes.append(f"  port '{port}': attached {len(new_groups)} group(s)")

d['groups']      = new_groups
d['port_groups'] = new_port_groups
d.pop('assignments', None)
d['config_schema'] = 3
d['version']       = script_ver

preview = json.dumps(d, indent=2)
print("ok")
for c in changes:
    print(c)
print("---JSON---")
print(preview)
PYEOF

    local result; result=$(python3 "$tmp_script" "$cfg" "${VERSION}")
    local rc=$?; rm -f "$tmp_script"
    [[ $rc -ne 0 || "$result" == err:* ]] && { err "Migration failed: ${result#err:}"; return 1; }

    local summary="" json_out="" in_json=0
    while IFS= read -r line; do
        if [[ "$line" == "---JSON---" ]]; then in_json=1; continue; fi
        if [[ $in_json -eq 1 ]]; then json_out+="${line}"$'\n'
        elif [[ "$line" != "ok" ]]; then summary+="${line}"$'\n'; fi
    done <<< "$result"

    echo -e "${CYN}Changes:${NC}"
    [[ -n "$summary" ]] && echo "$summary" || echo "  (nothing to migrate)"

    if [[ $dry_run -eq 1 ]]; then
        echo -e "${CYN}Resulting config.json (preview):${NC}"
        echo "$json_out"
        return 0
    fi

    _migrate_backup "$cfg"
    printf '%s' "$json_out" > "$cfg"
    ok "config.json written (schema 3, version ${VERSION})"
}

cmd_deploy() {
    local subcmd="${1:-status}"; shift || true

    # ── shared helpers ──────────────────────────────────────────────────────
    _deploy_write_common_artefacts() {
        local isp_type="$1" mode="$2"
        local params; params=$(get_module_params "$isp_type")

        if [[ "$mode" == "grub" ]]; then
            # Remove modprobe conf — kernel cmdline takes priority; having both
            # is a conflict risk.
            if [[ -f "$MODPROBE_CONF" ]]; then
                info "grub mode: removing modprobe conf (replaced by kernel cmdline params)"
                [[ $DRY_RUN -eq 0 ]] && rm -f "$MODPROBE_CONF" \
                    && ok "Removed: ${MODPROBE_CONF}" \
                    || info "[DRY-RUN] rm ${MODPROBE_CONF}"
            fi
        else
            file_write "$MODPROBE_CONF" "options qla2xxx_scst ${params}"
            ok "modprobe config written: ${MODPROBE_CONF}"
        fi

        # SCST ordering drop-in — always present in all modes
        if [[ $DRY_RUN -eq 0 ]]; then
            mkdir -p "$SCST_DROPIN_DIR"
            cat > "$SCST_DROPIN" << 'DROPIN'
[Unit]
After=ix-preinit.service
DROPIN
            systemctl daemon-reload || true
            ok "SCST ordering drop-in written: ${SCST_DROPIN}"
        else
            info "[DRY-RUN] would write ${SCST_DROPIN} and daemon-reload"
        fi

        # PREINIT boot entry — all modes (scope of work differs at runtime)
        local preinit_id; preinit_id=$(initscript_install_preinit)
        if [[ -n "$preinit_id" && $DRY_RUN -eq 0 ]]; then
            cfg_set 'initscript_preinit_id' "$preinit_id"
            ok "Boot entry registered (id=${preinit_id}) - visible in System > Advanced > Init/Shutdown Scripts"
        fi
    }

    _deploy_remove_artefacts() {
        # Remove /etc artefacts owned by qle_adm
        rm_f_v "$MODPROBE_CONF"
        if [[ -f "$SCST_DROPIN" ]]; then
            rm_f_v "$SCST_DROPIN"
            [[ $DRY_RUN -eq 0 ]] && systemctl daemon-reload || true
        fi
        initscript_remove
    }

    _deploy_install_grub_options() {
        local mode="$1" isp_type="$2" step_label="${3:-}"
        local params; params=$(get_module_params "$isp_type")
        info "Configuring kernel_extra_options for ${mode} mode (${isp_type}): ${params}"
        grub_install_mode "$mode" "$isp_type" "$params" "$step_label" "Apply these kernel_extra_options changes?"
    }

    _deploy_remove_grub_options() {
        local step_label="${1:-}"
        local current; current=$(grub_read_current)
        local parsed; parsed=$(grub_parse "$current")
        local existing_owned; existing_owned=$(echo "$parsed" | grep '^OWNED:' | cut -d: -f2-)
        if [[ -z "${existing_owned// /}" ]]; then
            info "No qle_adm-owned tokens found in kernel_extra_options - nothing to remove"
        else
            grub_remove_owned "$step_label" "Remove these kernel_extra_options tokens?"
        fi
    }

    _deploy_prompt_mode() {
        # Menu and prompt must go to /dev/tty - this function is called
        # inside $(...) so stdout is captured. Anything echo'd to stdout
        # becomes part of new_mode; only the final selection is echo'd there.
        echo -e "\n  ${CYN}Select boot mode:${NC}" >/dev/tty
        echo -e "  ${WHT}grub${NC}      - Kernel cmdline params via TrueNAS middleware." >/dev/tty
        echo -e "              No module reload at boot. Firmware: HBA flash or OS dist only." >/dev/tty
        echo -e "              (default)" >/dev/tty
        echo -e "  ${WHT}blacklist${NC} - Module blacklisted at boot; loaded correctly by boot entry." >/dev/tty
        echo -e "              Firmware: HBA, OS dist, or user-stored versions." >/dev/tty
        echo -e "  ${WHT}reload${NC}    - Module reloaded at every boot to apply correct params." >/dev/tty
        echo -e "              Firmware: HBA, OS dist, or user-stored versions." >/dev/tty
        echo -e "              (same as previous behaviour)\n" >/dev/tty
        echo -en "${YLW}?${NC}  Choose mode [grub/blacklist/reload] (default: grub): " >/dev/tty
        local reply; read -r reply </dev/tty || true
        reply="${reply:-grub}"
        case "$reply" in
            grub|blacklist|reload) echo "$reply" ;;
            *) echo "reload" ;;
        esac
    }

    _deploy_post_reconfigure_prompt() {
        local new_mode="$1"
        _reconfigure_used_sync=0
        echo -e "\n  ${CYN}Mode changed to ${WHT}${new_mode}${CYN}. Changes take full effect on next boot.${NC}"
        echo -e "  Options:\n"
        echo -e "  ${WHT}1)${NC} Reboot now       - clean, guaranteed correct"
        echo -e "  ${WHT}2)${NC} sync --restart   - write scst.conf and restart SCST immediately"
        echo -e "                       (drops all active FC and iSCSI sessions)"
        echo -e "  ${WHT}3)${NC} Do nothing       - new mode takes full effect on next boot\n"
        echo -en "${YLW}?${NC}  Choose [1/2/3] (default: 3): "
        local reply; read -r reply || true
        case "${reply:-3}" in
            1)
                warn "Rebooting in 5 seconds - Ctrl-C to cancel"
                sleep 5
                reboot
                ;;
            2)
                _reconfigure_used_sync=1
                cmd_sync --restart
                ;;
            3)
                info "No immediate action taken. Reboot when ready."
                ;;
            *)
                info "No immediate action taken. Reboot when ready."
                ;;
        esac
    }

    # ── subcommands ─────────────────────────────────────────────────────────
    case "$subcmd" in

        install)
            hdr "Deploy: Install qle_adm.sh v${VERSION}"

            # Validate QLE_ADM_HOME
            if [[ -z "${QLE_ADM_HOME}" ]]; then
                err "QLE_ADM_HOME is not set."
                err "qle_adm.sh must be installed on a data pool to survive boot environment changes."
                err ""
                err "Set QLE_ADM_HOME before installing:"
                err "  QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes deploy install"
                return 1
            fi
            if [[ "${QLE_ADM_HOME}" != /mnt/* ]]; then
                warn "QLE_ADM_HOME (${QLE_ADM_HOME}) is not under /mnt - non-persistent store"
                confirm_or_abort "Continue installing to a non-persistent location anyway?"
            fi

            mkdir_v "${QLE_ADM_HOME}"
            mkdir_v "${FIRMWARE_DIR}"
            [[ $DRY_RUN -eq 0 ]] && { touch "$LOG"; cfg_init; }

            # Determine boot mode
            local new_mode=""
            for arg in "$@"; do
                [[ "$arg" == "--mode" ]] && { new_mode="${1:-}"; break; }
                [[ "$arg" == --mode=* ]] && { new_mode="${arg#--mode=}"; break; }
            done
            # Parse --mode <val> properly
            local i=0
            for arg in "$@"; do
                if [[ "$arg" == "--mode" ]]; then
                    local args_arr=("$@")
                    new_mode="${args_arr[$((i+1))]:-}"
                    break
                fi
                i=$((i+1))
            done
            if [[ -z "$new_mode" ]]; then
                if [[ $YES -eq 1 ]]; then
                    new_mode="grub"
                    info "No --mode specified, defaulting to: grub"
                else
                    new_mode=$(_deploy_prompt_mode)
                fi
            fi
            case "$new_mode" in
                grub|blacklist|reload) ;;
                *) err "Invalid mode '${new_mode}'. Choose: grub, blacklist, reload"; return 1 ;;
            esac

            local isp_type; isp_type=$(get_isp_type_dominant)
            [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && isp_type="ISP2532"

            # Write /etc artefacts
            _deploy_write_common_artefacts "$isp_type" "$new_mode"

            # Kernel cmdline (grub and blacklist modes only)
            if [[ "$new_mode" == "grub" || "$new_mode" == "blacklist" ]]; then
                _deploy_install_grub_options "$new_mode" "$isp_type"
            fi

            # Record boot_mode in config
            [[ $DRY_RUN -eq 0 ]] && cfg_set 'boot_mode' "$new_mode"
            log "deploy install: boot_mode=${new_mode}"

            # Install script
            local src_real dst_real
            src_real=$(realpath "$0" 2>/dev/null || echo "$0")
            dst_real=$(realpath "${QLE_ADM_HOME}/qle_adm.sh" 2>/dev/null || echo "${QLE_ADM_HOME}/qle_adm.sh")
            if [[ "$src_real" == "$dst_real" ]]; then
                ok "Script already installed at ${QLE_ADM_HOME}/qle_adm.sh"
            else
                copy_v "$0" "${QLE_ADM_HOME}/qle_adm.sh"
                [[ $DRY_RUN -eq 0 && -f "${QLE_ADM_HOME}/qle_adm.sh" ]] && chmod +x "${QLE_ADM_HOME}/qle_adm.sh"
            fi

            echo ""
            info "Naming target ports..."
            auto_name_target_ports

            ok "Installation complete [boot_mode=${new_mode}]"
            info "Invoke as: ${QLE_ADM_HOME}/qle_adm.sh <command>"
            info "Run 'qle_adm.sh status' to check state"
            info "Run 'qle_adm.sh list-extents' to see available devices"
            echo ""
            echo -e "  ${CYN}Add to your shell startup script (e.g. ~/.bashrc or ~/.zshrc):${NC}"
            echo -e "  ${WHT}export QLE_ADM_HOME=${QLE_ADM_HOME}${NC}"
            echo -e "  ${WHT}PATH=\"\${PATH}:\${QLE_ADM_HOME}\"${NC}"

            if [[ "$new_mode" == "grub" || "$new_mode" == "blacklist" ]]; then
                info "Reboot to activate new boot mode: ${new_mode}"
            fi
            divider
            ;;

        uninstall)
            hdr "Deploy: Uninstall qle_adm.sh"
            warn "This will remove all qle_adm-managed configuration"

            local sessions=0
            for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
                [[ -d "$sess_path" ]] && sessions=$((sessions + 1))
            done
            [[ $sessions -gt 0 ]] && warn "${sessions} active FC session(s) will be disconnected"
            confirm_or_abort "Proceed with uninstall? All qle_adm configuration will be removed."

            local cur_mode; cur_mode=$(cfg_get 'boot_mode' 'grub')
            log "deploy uninstall: boot_mode=${cur_mode}"

            # Remove kernel cmdline tokens if applicable
            if [[ "$cur_mode" == "grub" || "$cur_mode" == "blacklist" ]]; then
                _deploy_remove_grub_options
            fi

            # Teardown module and sessions
            cmd_teardown --no-confirm
            _deploy_remove_artefacts

            ok "Uninstall complete. Config preserved at ${QLE_ADM_HOME}"
            info "To fully remove: rm -rf ${QLE_ADM_HOME}"
            divider
            ;;

        reconfigure)
            hdr "Deploy: Reconfigure boot mode"
            local cur_mode; cur_mode=$(cfg_get 'boot_mode' 'grub')
            info "Current boot mode: ${cur_mode}"

            # Parse --mode argument
            local new_mode=""
            local i=0
            for arg in "$@"; do
                if [[ "$arg" == "--mode" ]]; then
                    local args_arr=("$@")
                    new_mode="${args_arr[$((i+1))]:-}"
                    break
                fi
                i=$((i+1))
            done
            if [[ -z "$new_mode" ]]; then
                if [[ $YES -eq 1 ]]; then
                    err "reconfigure requires --mode <grub|blacklist|reload> when using --yes"
                    return 1
                fi
                new_mode=$(_deploy_prompt_mode)
            fi
            case "$new_mode" in
                grub|blacklist|reload) ;;
                *) err "Invalid mode '${new_mode}'. Choose: grub, blacklist, reload"; return 1 ;;
            esac

            if [[ "$new_mode" == "$cur_mode" ]]; then
                info "Already in ${cur_mode} mode."
                if [[ $YES -eq 1 ]]; then
                    info "Re-applying ${cur_mode} mode artefacts (--yes)"
                else
                    echo -en "${YLW}?${NC}  Re-apply ${cur_mode} mode artefacts to fix any gaps? [y/N] "
                    local reapply_reply; read -r reapply_reply || true
                    if [[ ! "$reapply_reply" =~ ^[Yy]$ ]]; then
                        info "No changes made."
                        divider; return 0
                    fi
                fi
                local isp_type; isp_type=$(get_isp_type_dominant)
                [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && isp_type="ISP2532"
                info "Re-applying ${cur_mode} mode artefacts..."
                echo ""
                _deploy_write_common_artefacts "$isp_type" "$cur_mode"
                if [[ "$cur_mode" == "grub" || "$cur_mode" == "blacklist" ]]; then
                    _deploy_install_grub_options "$cur_mode" "$isp_type"
                fi
                [[ $DRY_RUN -eq 0 ]] && cfg_set 'boot_mode' "$cur_mode"
                # Register/update hba_identity so PREINIT can detect card swaps
                if [[ $DRY_RUN -eq 0 ]]; then
                    local det_wwns det_count
                    det_wwns=$(python3 -c "
import os, json
hosts = sorted(h for h in os.listdir('/sys/class/fc_host/') if h.startswith('host'))
wwns = []
for h in hosts:
    try:
        raw = open(f'/sys/class/fc_host/{h}/port_name').read().strip().replace('0x','')
        wwns.append(':'.join(raw[i:i+2] for i in range(0,16,2)))
    except: pass
print(json.dumps(wwns))
" 2>/dev/null || echo "[]")
                    det_count=$(echo "$det_wwns" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                    if [[ "$det_count" -gt 0 ]]; then
                        _hba_identity_write "$isp_type" "$det_count" "$det_wwns"
                        ok "HBA identity registered: ${isp_type} ${det_count}-port"
                    fi
                fi
                log "deploy reconfigure: re-applied ${cur_mode} mode"
                ok "Re-applied ${cur_mode} mode artefacts"
                divider; return 0
            fi

            local isp_type; isp_type=$(get_isp_type_dominant)
            [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && isp_type="ISP2532"

            info "Switching: ${cur_mode} -> ${new_mode}"
            echo ""

            # Determine if both old and new modes touch kernel_extra_options
            local two_step=0
            if [[ ( "$cur_mode" == "grub" || "$cur_mode" == "blacklist" ) && \
                  ( "$new_mode" == "grub" || "$new_mode" == "blacklist" ) ]]; then
                two_step=1
            fi

            # Tear down old mode artefacts
            if [[ "$cur_mode" == "grub" || "$cur_mode" == "blacklist" ]]; then
                local remove_label=""
                [[ $two_step -eq 1 ]] && remove_label="Step 1 of 2 - Remove ${cur_mode} mode tokens"
                info "Removing old kernel cmdline tokens (${cur_mode} mode)..."
                _deploy_remove_grub_options "$remove_label"
            fi

            # Set up new mode artefacts
            _deploy_write_common_artefacts "$isp_type" "$new_mode"
            if [[ "$new_mode" == "grub" || "$new_mode" == "blacklist" ]]; then
                local install_label=""
                [[ $two_step -eq 1 ]] && install_label="Step 2 of 2 - Add ${new_mode} mode tokens"
                _deploy_install_grub_options "$new_mode" "$isp_type" "$install_label"
            fi

            [[ $DRY_RUN -eq 0 ]] && cfg_set 'boot_mode' "$new_mode"
            log "deploy reconfigure: ${cur_mode} -> ${new_mode}"
            ok "Boot mode changed: ${cur_mode} → ${new_mode}"

            # Register/update hba_identity so PREINIT can detect future card swaps
            if [[ $DRY_RUN -eq 0 ]]; then
                local det_wwns det_count
                det_wwns=$(python3 -c "
import os, json
hosts = sorted(h for h in os.listdir('/sys/class/fc_host/') if h.startswith('host'))
wwns = []
for h in hosts:
    try:
        raw = open(f'/sys/class/fc_host/{h}/port_name').read().strip().replace('0x','')
        wwns.append(':'.join(raw[i:i+2] for i in range(0,16,2)))
    except: pass
print(json.dumps(wwns))
" 2>/dev/null || echo "[]")
                det_count=$(echo "$det_wwns" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                if [[ "$det_count" -gt 0 ]]; then
                    _hba_identity_write "$isp_type" "$det_count" "$det_wwns"
                    ok "HBA identity registered: ${isp_type} ${det_count}-port"
                fi
            fi

            local _reconfigure_used_sync=0
            if [[ $YES -eq 0 && $DRY_RUN -eq 0 ]]; then
                _deploy_post_reconfigure_prompt "$new_mode"
            else
                info "Reboot to activate new boot mode: ${new_mode}"
            fi
            [[ $_reconfigure_used_sync -eq 0 ]] && divider || true
            ;;

        status)
            hdr "Deploy Status"
            cfg_init
            cfg_check_schema
            local cur_mode; cur_mode=$(cfg_get 'boot_mode' 'grub')

            # Last booted mode from log
            local last_boot_mode=""
            local last_boot_line
            last_boot_line=$(grep "=== Boot sync started" "${LOG}" 2>/dev/null | tail -1 || true)
            if [[ -n "$last_boot_line" ]]; then
                last_boot_mode=$(echo "$last_boot_line" | grep -oP '(?<=boot_mode=)[^\]]+' || true)
            fi

            echo -e "\n  ${CYN}Boot mode:${NC} ${WHT}${cur_mode}${NC} ${DIM}(configured)${NC}"
            if [[ -n "$last_boot_mode" ]]; then
                if [[ "$last_boot_mode" == "$cur_mode" ]]; then
                    echo -e "  ${CYN}Last boot:${NC}  ${WHT}${last_boot_mode}${NC} ${DIM}(matches configured)${NC}"
                else
                    echo -e "  ${CYN}Last boot:${NC}  ${WHT}${last_boot_mode}${NC}"
                    echo -e "  ${YLW}Pending reboot:${NC} mode change ${last_boot_mode} -> ${cur_mode} not yet active"
                fi
            else
                echo -e "  ${CYN}Last boot:${NC}  ${DIM}no boot sync entry found in log${NC}"
            fi
            echo ""

            # PREINIT boot entry - show command
            local preinit_id; preinit_id=$(initscript_find_id_preinit)
            if [[ -n "$preinit_id" ]]; then
                local entry_json
                entry_json=$(midclt call initshutdownscript.query 2>/dev/null | python3 -c "
import json,sys
for e in json.load(sys.stdin):
    if str(e.get('id','')) == '${preinit_id}':
        print(json.dumps(e))
        break
" 2>/dev/null || echo "")
                if [[ -n "$entry_json" ]]; then
                    local enabled cmd_str
                    enabled=$(echo "$entry_json" | python3 -c "import json,sys; e=json.load(sys.stdin); print(e.get('enabled',False))" 2>/dev/null || echo "unknown")
                    cmd_str=$(echo "$entry_json" | python3 -c "import json,sys; e=json.load(sys.stdin); print(e.get('command',''))" 2>/dev/null || echo "")
                    if [[ "$enabled" == "True" ]]; then
                        ok "Boot entry: registered (id=${preinit_id}, enabled)"
                    else
                        warn "Boot entry: registered (id=${preinit_id}) but DISABLED"
                    fi
                    echo -e "  ${DIM}command: ${cmd_str}${NC}"
                    # Verify command points to current QLE_ADM_HOME
                    if [[ -n "$cmd_str" && "$cmd_str" != *"${QLE_ADM_HOME}"* ]]; then
                        warn "Boot entry command path differs from current QLE_ADM_HOME (${QLE_ADM_HOME})"
                        warn "Run 'deploy install' to update the boot entry"
                    fi
                else
                    ok "Boot entry: registered (id=${preinit_id})"
                fi
            else
                gap "Boot entry: missing - run 'deploy install'"
            fi

            # SCST ordering drop-in
            if [[ -f "$SCST_DROPIN" ]]; then
                ok "SCST drop-in: ${SCST_DROPIN}"
            else
                gap "SCST drop-in: missing - run 'sync --boot' or 'deploy install'"
            fi

            # Mode-specific artefacts
            case "$cur_mode" in
                grub)
                    local cur_opts; cur_opts=$(grub_read_current)
                    local parsed; parsed=$(grub_parse "$cur_opts")
                    local owned; owned=$(echo "$parsed" | grep '^OWNED:' | cut -d: -f2-)
                    local foreign; foreign=$(echo "$parsed" | grep '^FOREIGN:' | cut -d: -f2-)
                    echo ""
                    echo -e "  ${CYN}kernel_extra_options:${NC}"
                    if [[ -n "${owned// /}" ]]; then
                        ok "  Owned tokens:  ${owned}"
                    else
                        gap "  No qle_adm-owned tokens found in kernel_extra_options"
                    fi
                    [[ -n "${foreign// /}" ]] && echo -e "  ${DIM}Foreign tokens: ${foreign}${NC}"
                    if [[ -f "$MODPROBE_CONF" ]]; then
                        warn "Modprobe conf exists in grub mode (conflict risk): ${MODPROBE_CONF}"
                    fi
                    local rw_pre; rw_pre=$(cfg_get 'rootwait_was_preexisting' 'false')
                    echo -e "  ${DIM}rootwait_was_preexisting: ${rw_pre}${NC}"
                    ;;
                blacklist)
                    local cur_opts; cur_opts=$(grub_read_current)
                    local parsed; parsed=$(grub_parse "$cur_opts")
                    local owned; owned=$(echo "$parsed" | grep '^OWNED:' | cut -d: -f2-)
                    echo ""
                    echo -e "  ${CYN}kernel_extra_options:${NC}"
                    if echo "$owned" | grep -q "module_blacklist=qla2xxx_scst"; then
                        ok "  module_blacklist=qla2xxx_scst present"
                    else
                        gap "  module_blacklist=qla2xxx_scst missing from kernel_extra_options"
                    fi
                    if echo "$owned" | grep -q "rootwait"; then
                        ok "  rootwait present"
                    else
                        gap "  rootwait missing from kernel_extra_options"
                    fi
                    local rw_pre; rw_pre=$(cfg_get 'rootwait_was_preexisting' 'false')
                    echo -e "  ${DIM}rootwait_was_preexisting: ${rw_pre}${NC}"
                    if [[ -f "$MODPROBE_CONF" ]]; then
                        ok "Modprobe conf: ${MODPROBE_CONF}"
                        local conf_content; conf_content=$(grep '^options' "$MODPROBE_CONF" 2>/dev/null | sed 's/options qla2xxx_scst //' || true)
                        [[ -n "$conf_content" ]] && echo -e "  ${DIM}options: ${conf_content}${NC}"
                    else
                        gap "Modprobe conf missing: ${MODPROBE_CONF}"
                    fi
                    ;;
                reload|*)
                    if [[ -f "$MODPROBE_CONF" ]]; then
                        ok "Modprobe conf: ${MODPROBE_CONF}"
                        local conf_content; conf_content=$(grep '^options' "$MODPROBE_CONF" 2>/dev/null | sed 's/options qla2xxx_scst //' || true)
                        [[ -n "$conf_content" ]] && echo -e "  ${DIM}options: ${conf_content}${NC}"
                    else
                        gap "Modprobe conf missing: ${MODPROBE_CONF} - run 'sync --boot'"
                    fi
                    ;;
            esac
            divider
            ;;

        migrate)
            # ── deploy migrate ─────────────────────────────────────────────
            # User-initiated, optional migration of config.json to the current
            # schema. Defaults to --dry-run; requires --apply to write.
            # Always backs up config before writing.
            local dry_run_migrate=1
            for _arg in "$@"; do
                [[ "$_arg" == "--apply" ]] && dry_run_migrate=0
            done

            hdr "Deploy: Config Migration"

            local detected_schema
            detected_schema=$(python3 - "${CONFIG}" << 'CSEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('config_schema', 1))
except Exception as e:
    print("err:" + str(e))
CSEOF
)
            if [[ "$detected_schema" == err:* ]]; then
                err "Cannot read config.json: ${detected_schema#err:}"
                return 1
            fi

            if [[ "$detected_schema" == "$CONFIG_SCHEMA" ]]; then
                ok "config.json is already at schema ${CONFIG_SCHEMA} - no migration needed."
                divider; return 0
            fi

            # Build migration path by chaining eligible single-step hops
            local current="$detected_schema"
            local migration_path=()
            while [[ "$current" != "$CONFIG_SCHEMA" ]]; do
                local next=$((current + 1))
                local key="${current}:${next}"
                local eligibility="${MIGRATION_TABLE[$key]:-}"
                if [[ -z "$eligibility" ]]; then
                    err "No migration path from schema ${current} to ${CONFIG_SCHEMA}."
                    err "This configuration cannot be migrated automatically."
                    err ""
                    err "Manual steps:"
                    err "  1. Back up:  cp ${CONFIG} ${CONFIG}.bak"
                    err "  2. Re-init:  rm ${CONFIG} && qle_adm.sh deploy install"
                    err "  3. Re-add ports, groups, and LUN mappings manually."
                    err ""
                    err "See GUIDE.md section 'Config Schema Migration' for details."
                    return 1
                fi
                if [[ "$eligibility" != "eligible" ]]; then
                    local reason="${eligibility#ineligible:}"
                    err "Migration from schema ${current} to ${next} is not supported:"
                    err "  ${reason}"
                    err "See GUIDE.md section 'Config Schema Migration' for manual steps."
                    return 1
                fi
                migration_path+=("${current}:${next}")
                current="$next"
            done

            echo -e "Detected schema: ${WHT}${detected_schema}${NC}"
            echo -e "Target schema:   ${WHT}${CONFIG_SCHEMA}${NC}"
            echo -e "Migration path:  ${WHT}$(IFS=' → '; echo "${migration_path[*]// → / → }")${NC}"
            echo ""

            if [[ $dry_run_migrate -eq 1 ]]; then
                info "DRY-RUN mode (default). No files will be written."
                info "Run with '--apply' to write changes. A backup is created automatically."
                echo ""
            fi

            for hop in "${migration_path[@]}"; do
                local from="${hop%%:*}" to="${hop##*:}"
                local fn="migrate_${from}_to_${to}"
                if ! declare -f "$fn" > /dev/null 2>&1; then
                    err "Internal error: migration function '${fn}' not defined."
                    return 1
                fi
                echo -e "${CYN}Step: schema ${from} → ${to}${NC}"
                "$fn" "$CONFIG" "$dry_run_migrate" || return 1
                echo ""
            done

            if [[ $dry_run_migrate -eq 1 ]]; then
                info "Dry-run complete. Review the output above, then run:"
                info "  qle_adm.sh deploy migrate --apply"
            else
                ok "Migration to schema ${CONFIG_SCHEMA} complete."
                echo ""
                local grp_list
                grp_list=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    src = d.get('groups', d.get('assignments', {}))
    for g in src.keys():
        print(g)
except: pass
")
                if [[ -n "$grp_list" ]]; then
                    echo -e "${YLW}Post-migration steps:${NC}"
                    echo ""
                    local detected_schema_post
                    detected_schema_post=$(python3 - "${CONFIG}" << 'CSEOF'
import json, sys
try: print(json.load(open(sys.argv[1])).get("config_schema", "?"))
except: print("?")
CSEOF
)
                    if [[ "$detected_schema_post" == "2" ]]; then
                        echo -e "${YLW}Group names were derived from initiator WWNs.${NC}"
                        echo -e "${YLW}Rename them to meaningful names:${NC}"
                        echo ""
                        while IFS= read -r grp; do
                            echo -e "  qle_adm.sh group rename ${grp} <new-name>"
                        done <<< "$grp_list"
                    elif [[ "$detected_schema_post" == "3" ]]; then
                        echo -e "${YLW}All groups were attached to all ports by default.${NC}"
                        echo -e "${YLW}Review and refine port associations for your fabric topology:${NC}"
                        echo ""
                        echo -e "  qle_adm.sh list-mapping             # review groups and port attachments"
                        echo -e "  qle_adm.sh port detach <port> <group>  # remove unwanted associations"
                        echo -e "  qle_adm.sh port attach <port> <group>  # add specific associations"
                    fi
                    echo ""
                    echo -e "${DIM}Run 'list-mapping' to review the current group and port configuration.${NC}"
                fi
                log "deploy migrate: schema ${detected_schema} → ${CONFIG_SCHEMA}"
            fi
            divider
            ;;

        *)
            err "Unknown deploy subcommand: ${subcmd}"
            err "Usage: deploy <install|uninstall|reconfigure|status|migrate>"
            err "  deploy install [--mode grub|blacklist|reload]"
            err "  deploy uninstall"
            err "  deploy reconfigure [--mode grub|blacklist|reload]"
            err "  deploy status"
            err "  deploy migrate [--apply]   (default: dry-run preview)"
            return 1
            ;;
    esac
}

# ─── scst.conf FC target block renderer ───────────────────────────────────────
# Serializes the full TARGET_DRIVER qla2x00t { TARGET ... { GROUP ... } } block
# from config.json into /etc/scst.conf, replacing any existing block.
#
# Called by sync --boot (before SCST starts on every boot) and by sync
# (at runtime after a WUI iSCSI save wiped the block). SCST reads the file
# naturally at startup - no sysfs apply step is needed or performed at boot.
render_scst_conf() {
    local conf="${SCST_CONF}"
    if [[ ! -f "$conf" ]]; then
        err "${SCST_CONF} not found - SCST must be installed and started at least"
        err "once before qle_adm can write the FC target block."
        err "Verify SCST is active: systemctl is-active scst"
        return 1
    fi

    local block
    block=$(python3 << PYEOF 2>/dev/null
import json, sys

try:
    d = json.load(open('${CONFIG}'))
except Exception as e:
    sys.stderr.write(f'qle_adm: config load failed: {e}\n')
    sys.exit(1)

enabled_ports = d.get('enabled_ports', [])
port_groups   = d.get('port_groups', {})
open_extents  = d.get('open_extents', [])
groups        = d.get('groups', {})

lines = []
lines.append('TARGET_DRIVER qla2x00t {')
lines.append('')

for port_idx, wwn in enumerate(enabled_ports):
    rel_tgt_id = port_idx + 10
    lines.append(f'    TARGET {wwn} {{')
    lines.append(f'        enabled 1')
    lines.append(f'        rel_tgt_id {rel_tgt_id}')
    lines.append('')

    for lun_idx, ext in enumerate(open_extents):
        lines.append(f'        LUN {lun_idx} {ext}')

    if open_extents:
        lines.append('')

    active_grp_names = port_groups.get(wwn, [])
    for grp_name in active_grp_names:
        data = groups.get(grp_name, {})
        luns       = data.get('luns', {})
        extents    = list(luns.keys())
        initiators = data.get('initiators', [])
        if not luns:
            continue
        lines.append(f'        GROUP {grp_name} {{')
        for init_wwn in initiators:
            lines.append(f'            INITIATOR {init_wwn}')
        if initiators:
            lines.append('')
        for ext, lun_id in luns.items():
            lines.append(f'            LUN {lun_id} {ext}')
        lines.append('        }')
        lines.append('')

    lines.append('    }')
    lines.append('')

lines.append('}')
print('\n'.join(lines))
PYEOF
)
    local py_exit=$?

    if [[ $py_exit -ne 0 || -z "$block" ]]; then
        err "render_scst_conf: failed to render FC target block"
        err "Check that ${CONFIG} exists and is valid JSON"
        err "Run: ls -la ${CONFIG}"
        return 1
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would replace TARGET_DRIVER qla2x00t block in ${conf}"
        echo "$block"
        return 0
    fi

    # Strip existing block (brace-counted) then append rebuilt one.
    # The rendered block is written to a temp file rather than passed as
    # argv[2] to avoid ARG_MAX overflow with large configs (7+ assignments
    # across 4 ports generates a block that exceeds the kernel argv limit,
    # causing sudo to abort with "argv[3] mismatch" and killing the write).
    local tmp_block
    tmp_block=$(mktemp /tmp/qle_adm_block.XXXXXX)
    printf '%s\n' "$block" > "$tmp_block"

    python3 - "$conf" "$tmp_block" << 'PYEOF'
import sys, re

conf_path  = sys.argv[1]
block_path = sys.argv[2]

with open(block_path) as f:
    new_block = f.read().rstrip()

with open(conf_path) as f:
    content = f.read()

pattern = re.compile(r'\n?TARGET_DRIVER\s+qla2x00t\s*\{', re.MULTILINE)
m = pattern.search(content)
if m:
    depth = 0
    for j, ch in enumerate(content[m.start():], m.start()):
        if ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                content = content[:m.start()].rstrip() + content[j+1:]
                break

content = content.rstrip() + '\n\n' + new_block + '\n'

with open(conf_path, 'w') as f:
    f.write(content)
PYEOF

    local py_exit=$?
    rm -f "$tmp_block"
    if [[ $py_exit -ne 0 ]]; then
        err "render_scst_conf: failed to write FC target block to ${conf}"
        return 1
    fi

    ok "FC target block written to ${conf}"
    log "render_scst_conf: rewrote TARGET_DRIVER qla2x00t block in ${conf}"
}

# Apply /etc/scst.conf to the live SCST sysfs tree via scstadmin.
# Non-disruptive: adds/removes LUN entries incrementally, no restart,
# no session drops. Fails cleanly if qla2x00t is not yet registered.
# Optional first arg: timeout in seconds to wait for qla2x00t (default 0).
scstadmin_apply() {
    local wait_secs="${1:-0}"

    # Optionally poll for qla2x00t registration (used by --preinit)
    if [[ $wait_secs -gt 0 ]]; then
        local elapsed=0
        while [[ ! -d /sys/kernel/scst_tgt/targets/qla2x00t ]] && \
              [[ $elapsed -lt $wait_secs ]]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if [[ ! -d /sys/kernel/scst_tgt/targets/qla2x00t ]]; then
            warn "qla2x00t not registered with SCST after ${wait_secs}s - skipping scstadmin apply"
            warn "Run 'sync --apply' once SCST has started"
            return 1
        fi
        info "qla2x00t registered after ${elapsed}s"
    else
        # Preflight - fail clearly rather than letting scstadmin produce a
        # cryptic FATAL error
        if [[ ! -d /sys/kernel/scst_tgt/targets/qla2x00t ]]; then
            err "qla2x00t is not registered with SCST"
            err "SCST may not be running or the module loaded after SCST started"
            err "Try 'sync --restart' to do a full restart, or wait and retry 'sync --apply'"
            return 1
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] scstadmin -force -noprompt -config ${SCST_CONF}"
        return 0
    fi

    local tmpout; tmpout=$(mktemp)
    if scstadmin -force -noprompt -config "${SCST_CONF}" >"$tmpout" 2>&1; then
        local changes; changes=$(grep -c "done\." "$tmpout" 2>/dev/null || echo 0)
        ok "scstadmin applied ${SCST_CONF} (${changes} change(s))"
        rm -f "$tmpout"
        return 0
    else
        # Detect the SCST kernel constraint: a group with active initiator
        # sessions cannot be removed even after its LUNs are cleared.
        # This occurs when group structure changes (add/remove groups,
        # change initiator membership) while sessions are active.
        # sync --apply is only safe for LUN-map changes within stable groups.
        if grep -q "is not empty" "$tmpout" 2>/dev/null; then
            err "scstadmin apply failed: SCST refused to remove a group with active sessions."
            err ""
            err "sync --apply is for LUN mapping changes within stable groups only."
            err "Group structural changes (add/remove groups, change initiator"
            err "membership, port attach/detach) require a full SCST restart:"
            err "  sync --restart"
        else
            err "scstadmin apply failed:"
            cat "$tmpout" >&2
        fi
        rm -f "$tmpout"
        return 1
    fi
}




# ─── PREINIT HBA swap detection ───────────────────────────────────────────────
#
# Called at the start of sync --boot.  Compares hba_identity in config.json
# against the hardware detected via /sys/class/fc_host and dmesg.
#
# Decision matrix:
#   WWNs identical                          → match        (no-op)
#   No hba_identity registered              → unregistered (register, no migration)
#   ISP type differs (any port count)       → bare_block   (case b)
#   Same ISP, new port count < old          → bare_block   (case b)
#   Same ISP, new port count >= old         → auto_migrate (case a / exact match)
#
# Returns one of: match | unregistered | auto_migrate | bare_block
# Populates SWAP_* globals for use by preinit_swap_execute.

preinit_swap_detect() {
    # Detects whether an HBA card swap has occurred since hba_identity was last
    # registered.  Writes SWAP_* variables to SWAP_ENV_FILE so the caller can
    # source them (they would be lost if set inside a $(...) subshell).
    # Echoes one of: match | unregistered | auto_migrate | bare_block
    local cfg_isp cfg_count cfg_wwns_json det_isp det_count det_wwns_json

    cfg_isp=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print(d.get('hba_identity', {}).get('isp_type', ''))
except: print('')
")
    if [[ -z "$cfg_isp" ]]; then
        # Collect detected values so unregistered path can write hba_identity
        det_isp=$(get_isp_type_dominant 2>/dev/null)
        [[ -z "$det_isp" || "$det_isp" == "UNKNOWN" ]] && det_isp="ISP2532"
        det_count=$(ls /sys/class/fc_host/ 2>/dev/null | grep -c 'host' || echo 0)
        det_wwns_json=$(python3 -c "
import os, json
try:
    hosts = sorted(h for h in os.listdir('/sys/class/fc_host/') if h.startswith('host'))
    wwns = []
    for h in hosts:
        raw = open(f'/sys/class/fc_host/{h}/port_name').read().strip().replace('0x','')
        wwns.append(':'.join(raw[i:i+2] for i in range(0,16,2)))
    print(json.dumps(wwns))
except: print('[]')
" 2>/dev/null || echo "[]")
        cat > "$SWAP_ENV_FILE" << ENVEOF
SWAP_CFG_ISP=""
SWAP_CFG_COUNT=0
SWAP_CFG_WWNS="[]"
SWAP_DET_ISP="${det_isp}"
SWAP_DET_COUNT=${det_count}
SWAP_DET_WWNS='${det_wwns_json}'
ENVEOF
        echo "unregistered"; return
    fi

    cfg_count=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print(d.get('hba_identity', {}).get('port_count', 0))
except: print(0)
")
    cfg_wwns_json=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    import json as j; print(j.dumps(d.get('hba_identity', {}).get('port_wwns', [])))
except: print('[]')
")

    det_isp=$(get_isp_type_dominant 2>/dev/null)
    [[ -z "$det_isp" || "$det_isp" == "UNKNOWN" ]] && det_isp="ISP2532"

    det_count=$(ls /sys/class/fc_host/ 2>/dev/null | grep -c 'host' || echo 0)
    det_wwns_json=$(python3 -c "
import os, json
try:
    hosts = sorted(h for h in os.listdir('/sys/class/fc_host/') if h.startswith('host'))
    wwns = []
    for h in hosts:
        raw = open(f'/sys/class/fc_host/{h}/port_name').read().strip().replace('0x','')
        wwns.append(':'.join(raw[i:i+2] for i in range(0,16,2)))
    print(json.dumps(wwns))
except: print('[]')
" 2>/dev/null || echo "[]")

    # Write SWAP_* to temp file — parent must source this after $(...) capture
    cat > "$SWAP_ENV_FILE" << ENVEOF
SWAP_CFG_ISP="${cfg_isp}"
SWAP_CFG_COUNT=${cfg_count}
SWAP_CFG_WWNS='${cfg_wwns_json}'
SWAP_DET_ISP="${det_isp}"
SWAP_DET_COUNT=${det_count}
SWAP_DET_WWNS='${det_wwns_json}'
ENVEOF

    local cfg_flat det_flat
    cfg_flat=$(python3 -c "import json,sys; print(' '.join(json.loads(sys.stdin.read())))" <<< "$cfg_wwns_json" 2>/dev/null || echo "")
    det_flat=$(python3 -c "import json,sys; print(' '.join(json.loads(sys.stdin.read())))" <<< "$det_wwns_json" 2>/dev/null || echo "")

    [[ "$det_flat" == "$cfg_flat" ]] && { echo "match"; return; }

    if [[ "$det_isp" != "$cfg_isp" ]]; then
        echo "bare_block"; return
    fi
    if [[ "$det_count" -ge "$cfg_count" ]]; then
        echo "auto_migrate"; return
    fi
    echo "bare_block"
}

# preinit_swap_execute <action>
# Executes the migration action determined by preinit_swap_detect.
# Returns 0 to continue normal boot path (render_scst_conf will run).
# Returns 1 for bare_block: bare block already written, skip render_scst_conf.
preinit_swap_execute() {
    local action="$1"
    local now; now=$(date -u +"%Y-%m-%dT%H:%M:%S")

    case "$action" in

        match)
            log "boot: HBA identity match - no swap detected"
            info "boot: HBA identity match - no swap detected"
            return 0
            ;;

        unregistered)
            # First boot with hba_identity feature. Register current hardware.
            # Do not touch enabled_ports — let existing sync --boot flow handle it.
            log "boot: hba_identity absent - registering current hardware (first registration)"
            if [[ "$SWAP_DET_COUNT" -gt 0 ]]; then
                _hba_identity_write "$SWAP_DET_ISP" "$SWAP_DET_COUNT" "$SWAP_DET_WWNS"
                log "boot: registered ${SWAP_DET_ISP} ${SWAP_DET_COUNT}-port as hba_identity"
                ok "boot: HBA identity registered: ${SWAP_DET_ISP} ${SWAP_DET_COUNT}-port"
            else
                warn "boot: hba_identity absent but no FC ports detected - registration skipped"
            fi
            return 0
            ;;

        auto_migrate)
            log "boot: HBA swap detected (auto_migrate) old=${SWAP_CFG_ISP}/${SWAP_CFG_COUNT}p new=${SWAP_DET_ISP}/${SWAP_DET_COUNT}p"
            warn "HBA swap detected at boot - auto-migrating port configuration"

            local migration_notes
            migration_notes=$(python3 << PYEOF
import json, sys

cfg_path = '${CONFIG}'
cfg  = json.load(open(cfg_path))
old_wwns = json.loads("""${SWAP_CFG_WWNS}""")
new_wwns = json.loads("""${SWAP_DET_WWNS}""")

# Map old port i -> new port i for i in 0..len(old_wwns)-1
wwn_map = {old: new_wwns[i] for i, old in enumerate(old_wwns) if i < len(new_wwns)}

# Remap enabled_ports
cfg['enabled_ports'] = [wwn_map.get(w, w) for w in cfg.get('enabled_ports', [])]

# Remap target-side wwn_names; preserve initiator-side entries unchanged
old_target_set = set(old_wwns)
new_names = {}
for wwn, entry in cfg.get('wwn_names', {}).items():
    if wwn in wwn_map:
        new_names[wwn_map[wwn]] = entry
    elif wwn not in old_target_set:
        new_names[wwn] = entry
cfg['wwn_names'] = new_names

# Extra new ports not in old config
extra_ports = new_wwns[len(old_wwns):]

# Update hba_identity
cfg['hba_identity'] = {
    'isp_type':      '${SWAP_DET_ISP}',
    'port_count':    len(new_wwns),
    'port_wwns':     new_wwns,
    'model':         cfg.get('hba_identity', {}).get('model', ''),
    'registered_at': '${now}'
}

notes = f"Auto-migrated {len(old_wwns)} port(s) to new HBA WWNs."
if extra_ports:
    notes += f" {len(extra_ports)} new port(s) available - use 'port enable' to activate."

# Only write swap event if WWNs actually changed — skip for no-op same-card migrations
if old_wwns != new_wwns[:len(old_wwns)] or extra_ports:
    cfg['hba_swap_event'] = {
        'detected_at':  '${now}',
        'old_isp':      '${SWAP_CFG_ISP}',
        'old_wwns':     old_wwns,
        'new_isp':      '${SWAP_DET_ISP}',
        'new_wwns':     new_wwns,
        'action':       'auto_migrated',
        'extra_ports':  extra_ports,
        'notes':        notes
    }
else:
    cfg['hba_swap_event'] = None

json.dump(cfg, open(cfg_path, 'w'), indent=2)
print(notes)
PYEOF
)
            ok "boot: ${migration_notes}"
            log "boot: ${migration_notes}"

            # In grub mode, fix module params if they don't match the detected ISP
            _preinit_fix_grub_params_if_needed "$SWAP_DET_ISP"

            # Normal render_scst_conf will follow in the boot path
            return 0
            ;;

        bare_block)
            log "boot: HBA swap detected (bare_block) old=${SWAP_CFG_ISP}/${SWAP_CFG_COUNT}p new=${SWAP_DET_ISP}/${SWAP_DET_COUNT}p"
            warn "HBA swap: ISP type mismatch or port count reduced - writing bare FC block"
            warn "FC targets will be absent until 'hba swap' is run. iSCSI is unaffected."

            python3 << PYEOF
import json
cfg = json.load(open('${CONFIG}'))
old_wwns = json.loads("""${SWAP_CFG_WWNS}""")
new_wwns = json.loads("""${SWAP_DET_WWNS}""")
cfg['hba_swap_event'] = {
    'detected_at': '${now}',
    'old_isp':     '${SWAP_CFG_ISP}',
    'old_wwns':    old_wwns,
    'new_isp':     '${SWAP_DET_ISP}',
    'new_wwns':    new_wwns,
    'action':      'bare_block_written',
    'extra_ports': [],
    'notes':       "Manual 'hba swap' required before FC targets can be activated."
}
json.dump(cfg, open('${CONFIG}', 'w'), indent=2)
PYEOF
            # Write a bare TARGET_DRIVER block directly - skip render_scst_conf
            _preinit_write_bare_fc_block
            return 1
            ;;
    esac
    return 0
}

# Write a bare TARGET_DRIVER qla2x00t {} block into scst.conf.
# Used by the bare_block swap path so SCST can start (iSCSI still works)
# even when FC targets cannot be configured.
_preinit_write_bare_fc_block() {
    [[ ! -f "$SCST_CONF" ]] && { warn "boot: ${SCST_CONF} not found - cannot write bare FC block"; return 1; }
    python3 - "$SCST_CONF" << 'PYEOF'
import sys, re
conf_path = sys.argv[1]
with open(conf_path) as f:
    content = f.read()
bare = '\nTARGET_DRIVER qla2x00t {\n}\n'
pattern = re.compile(r'\n?TARGET_DRIVER\s+qla2x00t\s*\{', re.MULTILINE)
m = pattern.search(content)
if m:
    # Remove existing block (brace counting)
    depth, i, start = 0, m.start(), m.start()
    for idx in range(m.start(), len(content)):
        if content[idx] == '{': depth += 1
        elif content[idx] == '}':
            depth -= 1
            if depth == 0:
                content = content[:start] + content[idx+1:]
                break
content = content.rstrip() + bare
with open(conf_path, 'w') as f:
    f.write(content)
PYEOF
    ok "boot: bare TARGET_DRIVER qla2x00t block written to ${SCST_CONF}"
    log "boot: bare FC block written (HBA swap bare_block path)"
}

# Fix module params in grub mode if applied params don't match configured params
# for the detected ISP type.  midclt is confirmed available at PREINIT on
# TrueNAS 25.10 (middlewared starts ~84s before ix-preinit fires).
_preinit_fix_grub_params_if_needed() {
    local det_isp="$1"
    local boot_mode; boot_mode=$(cfg_get 'boot_mode' 'grub')
    [[ "$boot_mode" != "grub" ]] && return 0
    module_loaded "qla2xxx_scst" || return 0

    local configured applied
    configured=$(get_module_params "$det_isp")
    applied=$(get_applied_params)

    if [[ -n "$applied" && "$applied" != "$configured" ]]; then
        warn "boot: module params drift detected for ${det_isp} - correcting"
        log "boot: param drift: applied='${applied}' configured='${configured}'"
        modprobe -r qla2xxx_scst 2>/dev/null || true
        sleep 1
        modprobe qla2xxx_scst $configured
        log "boot: reloaded qla2xxx_scst with ${configured}"
        ok "boot: module reloaded with correct params for ${det_isp}"
        # Update kernel_extra_options for next boot
        local new_opts="rootwait"
        for tok in $configured; do
            new_opts+=" qla2xxx_scst.${tok}"
        done
        midclt call system.advanced.update \
            "{\"kernel_extra_options\":\"${new_opts}\"}" \
            >/dev/null 2>&1 \
            && log "boot: kernel_extra_options updated for ${det_isp}" \
            || warn "boot: could not update kernel_extra_options via middleware - run 'deploy reconfigure' to fix"
    fi
    return 0
}

cmd_sync() {
    local boot_mode_flag=0 restart_mode=0 apply_mode=0
    for arg in "$@"; do
        [[ "$arg" == "--boot" ]]    && boot_mode_flag=1
        [[ "$arg" == "--restart" ]] && restart_mode=1
        [[ "$arg" == "--apply" ]]   && apply_mode=1
        # Backward compat: --preinit and --system both map to --boot
        [[ "$arg" == "--preinit" || "$arg" == "--system" ]] && boot_mode_flag=1
    done
    # --boot is an unattended boot context - never prompt
    [[ $boot_mode_flag -eq 1 ]] && YES=1

    local mode_label=""
    [[ $boot_mode_flag -eq 1 ]] && mode_label+=" (boot)"
    [[ $restart_mode   -eq 1 ]] && mode_label+=" (restart)"
    [[ $apply_mode     -eq 1 ]] && mode_label+=" (apply)"
    hdr "Sync${mode_label}"
    cfg_init
    cfg_check_schema

    local isp_type; isp_type=$(get_isp_type_dominant)
    [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && isp_type="ISP2532"

    local boot_mode; boot_mode=$(cfg_get 'boot_mode' 'grub')

    if [[ $boot_mode_flag -eq 1 ]]; then
        # Boot context: write /etc files then manage module according to boot_mode.
        log "=== Boot sync started [boot_mode=${boot_mode}] ==="

        # HBA swap detection - must run before render_scst_conf so that
        # enabled_ports and wwn_names reflect the current card's WWNs.
        # preinit_swap_detect runs in a subshell ($(...)); it writes SWAP_*
        # variables to SWAP_ENV_FILE so they survive back into this shell.
        local swap_action
        swap_action=$(preinit_swap_detect)
        # shellcheck source=/dev/null
        [[ -f "$SWAP_ENV_FILE" ]] && source "$SWAP_ENV_FILE" && rm -f "$SWAP_ENV_FILE"
        local swap_skip_render=0
        preinit_swap_execute "$swap_action" || swap_skip_render=1
        # Re-read isp_type after possible migration (auto_migrate updates hba_identity)
        isp_type=$(get_isp_type_dominant 2>/dev/null)
        [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && isp_type="ISP2532"

        # Always write modprobe conf except in grub mode (where it would conflict
        # with the cmdline params and must not exist).
        if [[ "$boot_mode" == "grub" ]]; then
            if [[ -f "$MODPROBE_CONF" ]]; then
                warn "grub mode: removing conflicting modprobe conf ${MODPROBE_CONF}"
                [[ $DRY_RUN -eq 0 ]] && rm -f "$MODPROBE_CONF" || info "[DRY-RUN] rm ${MODPROBE_CONF}"
            fi
        else
            local params; params=$(get_module_params "$isp_type")
            file_write "$MODPROBE_CONF" "options qla2xxx_scst ${params}"
            ok "modprobe config written: ${MODPROBE_CONF}"
        fi

        # Always ensure SCST ordering drop-in is present (all modes)
        if [[ $DRY_RUN -eq 0 ]]; then
            mkdir -p "$SCST_DROPIN_DIR"
            cat > "$SCST_DROPIN" << 'DROPIN'
[Unit]
After=ix-preinit.service
DROPIN
            systemctl daemon-reload || true
            ok "SCST ordering drop-in written: ${SCST_DROPIN}"
        else
            info "[DRY-RUN] would write ${SCST_DROPIN} and daemon-reload"
        fi

        # Always write scst.conf before SCST starts (all modes)
        # Skipped if bare_block swap path already wrote it directly.
        if [[ $swap_skip_render -eq 0 ]]; then
            render_scst_conf || return 1
            auto_name_target_ports
        fi

        # Module management — mode specific
        case "$boot_mode" in
            grub)
                # Params delivered via kernel cmdline - no module management needed.
                info "boot_mode=grub: module params set via kernel cmdline - no reload"
                ok "Boot sync complete (grub mode) - scst.conf updated"
                ;;
            blacklist)
                # Module was blacklisted; PREINIT is the first load.
                if module_loaded "qla2xxx_scst"; then
                    info "blacklist mode: qla2xxx_scst already loaded - skipping load"
                else
                    info "blacklist mode: loading qla2xxx_scst for first time"
                    local params; params=$(get_module_params "$isp_type")
                    params=$(echo "$params" | sed 's/ql2xfwloadbin=[^ ]*//g' | tr -s ' ' | sed 's/^ //;s/ $//')
                    local fwbin; fwbin=$(inject_firmware "$isp_type")
                    params="${params} ql2xfwloadbin=${fwbin}"
                    if [[ $DRY_RUN -eq 0 ]]; then
                        modprobe -i qla2xxx_scst $params
                        log "boot: loaded qla2xxx_scst params=${params}"
                        ok "qla2xxx_scst loaded (blacklist mode)"
                    else
                        info "[DRY-RUN] modprobe -i qla2xxx_scst ${params}"
                    fi
                fi
                ok "Boot sync complete (blacklist mode)"
                ;;
            reload|*)
                # Classic mode: unload the early-boot default-param load, reload correctly.
                if module_loaded "qla2xxx_scst"; then
                    info "reload mode: reloading qla2xxx_scst with configured params"
                    local params; params=$(get_module_params "$isp_type")
                    params=$(echo "$params" | sed 's/ql2xfwloadbin=[^ ]*//g' | tr -s ' ' | sed 's/^ //;s/ $//')
                    local fwbin; fwbin=$(inject_firmware "$isp_type")
                    params="${params} ql2xfwloadbin=${fwbin}"
                    if [[ $DRY_RUN -eq 0 ]]; then
                        modprobe -r qla2xxx_scst 2>/dev/null || true
                        sleep 1
                        modprobe qla2xxx_scst $params
                        log "boot: reloaded qla2xxx_scst params=${params}"
                        ok "qla2xxx_scst reloaded with correct params"
                    else
                        info "[DRY-RUN] modprobe -r qla2xxx_scst && modprobe qla2xxx_scst ${params}"
                    fi
                else
                    info "reload mode: qla2xxx_scst not loaded - SCST will load with modprobe conf params"
                fi
                ok "Boot sync complete (reload mode)"
                ;;
        esac
        divider
        return 0
    fi

    # Non-boot sync path: write scst.conf, optionally restart or apply.

    # Pending LUN changes: validate merged map before writing scst.conf.
    # Validation only runs when --restart or --apply is given, since those
    # are the only paths that actually apply the new LUN numbers. Without a
    # flag, scst.conf is written from current (non-pending) luns only.
    if [[ $restart_mode -eq 1 || $apply_mode -eq 1 ]]; then
        local pending_conflict=0
        local pending_wwns
        pending_wwns=$(py_json "
import json
d = json.load(open('${CONFIG}'))
for wwn, data in d.get('groups', {}).items():
    if data.get('pending_luns'):
        print(wwn)
" 2>/dev/null || true)
        if [[ -n "$pending_wwns" ]]; then
            while IFS= read -r wwn; do
                local valid
                valid=$(py_json "
import json
d = json.load(open('${CONFIG}'))
a = d.get('groups', {}).get('${wwn}', {})
luns = dict(a.get('luns', {}))
pending = dict(a.get('pending_luns', {}))
merged = {}
for ext, n in luns.items():
    merged[ext] = pending.get(ext, n)
for ext, n in pending.items():
    if ext not in merged:
        merged[ext] = n
seen = {}
for ext, n in merged.items():
    if n in seen:
        print(f'conflict:{n}:{seen[n]}:{ext}')
        exit()
    seen[n] = ext
print('ok')
" 2>/dev/null || echo "ok")
                if [[ "$valid" != "ok" ]]; then
                    local clun cext1 cext2
                    IFS=: read -r _ clun cext1 cext2 <<< "$valid"
                    err "Pending LUN conflict for ${wwn}: LUN ${clun} claimed by both '${cext1}' and '${cext2}'"
                    err "Resolve with 'lun set' before applying. Use 'lun status' to review."
                    pending_conflict=1
                fi
            done <<< "$pending_wwns"
            if [[ $pending_conflict -eq 1 ]]; then
                err "Pending LUN conflicts must be resolved before sync can apply changes."
                return 1
            fi
            # All pending maps are valid - promote pending_luns into luns
            info "Promoting pending LUN changes..."
            py_json "
import json
d = json.load(open('${CONFIG}'))
for wwn, data in d.get('groups', {}).items():
    pending = data.get('pending_luns', {})
    if pending:
        for ext, n in pending.items():
            data.setdefault('luns', {})[ext] = n
        data['pending_luns'] = {}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
" 2>/dev/null
            ok "Pending LUN changes promoted and will be applied"
            log "sync: pending LUN changes promoted for: $(echo "$pending_wwns" | tr '\n' ' ')"
        fi
    fi

    # Also warn if pending changes exist but no apply flag was given
    if [[ $restart_mode -eq 0 && $apply_mode -eq 0 ]]; then
        local has_pending
        has_pending=$(py_json "
import json
d = json.load(open('${CONFIG}'))
total = sum(len(data.get('pending_luns', {})) for data in d.get('groups', {}).values())
print(total)
" 2>/dev/null || echo "0")
        [[ "$has_pending" -gt 0 ]] && \
            warn "Pending LUN changes exist (${has_pending} entries). Apply with 'sync --restart' or 'sync --apply'."
    fi
    render_scst_conf || return 1

    # Warn if config.json contains assignments for extents no longer in scst.conf.
    local stale_exts
    stale_exts=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    scst_devs = set(line.strip() for line in open('${SCST_CONF}') if line.strip().startswith('DEVICE ')) if True else set()
    import re
    scst_devs = set(re.findall(r'^\s+DEVICE\s+(\S+)', open('${SCST_CONF}').read(), re.MULTILINE))
    cfg_exts = set()
    for ext in d.get('open_extents', []):
        cfg_exts.add(ext)
    for grp, data in d.get('groups', {}).items():
        for ext in data.get('luns', {}).keys():
            cfg_exts.add(ext)
    for ext in sorted(cfg_exts - scst_devs):
        print(ext)
except: pass
" 2>/dev/null || true)
    if [[ -n "$stale_exts" ]]; then
        warn "Stale assignments detected - these extents are in config.json but not in ${SCST_CONF}:"
        while IFS= read -r ext; do
            warn "  ${ext}"
        done <<< "$stale_exts"
        warn "The WUI may have removed the underlying device. Run 'group unmap <group> <extent>' to clean up."
        warn "Use 'list-extents' or 'list-mapping' to identify stale entries."
    fi

    local port_count; port_count=$(cfg_get_list "enabled_ports" | grep -c . || true)
    if [[ "$port_count" -eq 0 ]]; then
        info "No ports enabled - bare TARGET_DRIVER block written. Use 'port enable' to add targets."
    fi

    if [[ $restart_mode -eq 1 ]]; then
        local sessions=0
        for sess_path in /sys/kernel/scst_tgt/targets/*/sessions/*/; do
            [[ -d "$sess_path" ]] && sessions=$((sessions + 1))
        done
        [[ $sessions -gt 0 ]] && warn "${sessions} active session(s) will be dropped by the SCST restart"
        warn "sync --restart will restart scst.service - all active sessions will be disconnected"
        confirm_or_abort "Restart scst.service now?"
        if [[ $DRY_RUN -eq 0 ]]; then
            systemctl restart scst
            ok "scst.service restarted - FC targets initialized from scst.conf"
        else
            info "[DRY-RUN] systemctl restart scst"
        fi

    elif [[ $apply_mode -eq 1 ]]; then
        scstadmin_apply 0 || return 1
        ok "Sync --apply complete - live sysfs updated from scst.conf"

    else
        ok "Sync complete - scst.conf updated from config.json"
        info "Live sysfs state not touched. Use 'sync --apply' to apply non-disruptively,"
        info "or 'sync --restart' to restart SCST (drops all active sessions)."
    fi
    divider
}

cmd_teardown() {
    local no_confirm=0
    [[ "${1:-}" == "--no-confirm" ]] && no_confirm=1

    hdr "Tearing down FC targets"
    local sessions=0
    for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
        [[ -d "$sess_path" ]] && sessions=$((sessions + 1))
    done
    if [[ $sessions -gt 0 && $no_confirm -eq 0 ]]; then
        warn "${sessions} active session(s) will be disconnected"
        confirm_or_abort "Continue teardown? Active sessions will be dropped."
    elif [[ $sessions -gt 0 ]]; then
        warn "${sessions} active session(s) will be disconnected"
    fi
    if module_loaded "qla2xxx_scst"; then
        run_cmd systemctl stop scst 2>/dev/null || true
        run_cmd modprobe -r qla2xxx_scst 2>/dev/null || true
        run_cmd modprobe qla2xxx qlini_mode=enabled ql2xnvmeenable=0
        ok "Reverted to initiator mode (plain qla2xxx)"
    else
        ok "qla2xxx_scst not loaded"
    fi
    divider
}

cmd_module() {
    local subcmd="${1:-status}"; shift || true
    local isp_type; isp_type=$(get_isp_type_dominant)
    [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && isp_type="ISP2532"

    _module_load() {
        local params; params=$(get_module_params "$isp_type")
        # Strip ql2xfwloadbin from base params - inject_firmware sets the correct value.
        params=$(echo "$params" | sed 's/ql2xfwloadbin=[^ ]*//g' | tr -s ' ' | sed 's/^ //;s/ $//')
        local fwbin; fwbin=$(inject_firmware "$isp_type")
        params="${params} ql2xfwloadbin=${fwbin}"
        info "Loading qla2xxx_scst (${isp_type}): ${params}"
        if [[ $DRY_RUN -eq 0 ]]; then
            modprobe -r qla2xxx     2>/dev/null || true
            modprobe -r qla2xxx_scst 2>/dev/null || true
            sleep 1
            modprobe qla2xxx_scst $params
            sleep 3
            log "module load: qla2xxx_scst params=${params}"
            ok "qla2xxx_scst loaded"
        else
            info "[DRY-RUN] modprobe -r qla2xxx"
            info "[DRY-RUN] modprobe -r qla2xxx_scst"
            info "[DRY-RUN] modprobe qla2xxx_scst ${params}"
        fi
    }

    _module_unload() {
        if ! module_loaded "qla2xxx_scst"; then
            warn "qla2xxx_scst not loaded - nothing to unload"
            return 0
        fi
        local sessions=0
        for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
            [[ -d "$sess_path" ]] && sessions=$((sessions + 1))
        done
        [[ $sessions -gt 0 ]] && warn "${sessions} active FC session(s) will be dropped"
        confirm_or_abort "Unload qla2xxx_scst and revert to initiator mode?"
        if [[ $DRY_RUN -eq 0 ]]; then
            modprobe -r qla2xxx_scst 2>/dev/null || true
            modprobe qla2xxx qlini_mode=enabled ql2xnvmeenable=0
            log "module unload: reverted to qla2xxx initiator"
            ok "Reverted to initiator mode (plain qla2xxx)"
        else
            info "[DRY-RUN] modprobe -r qla2xxx_scst"
            info "[DRY-RUN] modprobe qla2xxx qlini_mode=enabled ql2xnvmeenable=0"
        fi
    }

    case "$subcmd" in
        load)
            hdr "Module Load"
            if module_loaded "qla2xxx_scst"; then
                local applied configured
                applied=$(get_applied_params)
                configured=$(get_module_params "$isp_type")
                if [[ "$applied" == "$configured" ]]; then
                    ok "qla2xxx_scst already loaded with correct params"
                    divider
                    return 0
                fi
                warn "qla2xxx_scst loaded but params differ from configured"
                info "Applied   : ${applied}"
                info "Configured: ${configured}"
                confirm_or_abort "Reload module with correct params? Active FC sessions will be dropped."
            fi
            _module_load
            divider
            ;;
        unload)
            hdr "Module Unload"
            _module_unload
            divider
            ;;
        reload)
            hdr "Module Reload"
            local sessions=0
            for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
                [[ -d "$sess_path" ]] && sessions=$((sessions + 1))
            done
            [[ $sessions -gt 0 ]] && warn "${sessions} active FC session(s) will be dropped by the reload"
            confirm_or_abort "Reload qla2xxx_scst? SCST will be stopped - all active FC and iSCSI sessions will be dropped."
            if [[ $DRY_RUN -eq 0 ]]; then
                info "Stopping scst.service to release module reference count"
                systemctl stop scst 2>/dev/null || true
                sleep 1
                if module_loaded "qla2xxx_scst"; then
                    modprobe -r qla2xxx_scst 2>/dev/null || \
                        warn "modprobe -r qla2xxx_scst failed - module may still be in use"
                    sleep 1
                fi
                _module_load
                info "Starting scst.service"
                systemctl start scst 2>/dev/null || \
                    warn "scst.service failed to start - check 'systemctl status scst'"
            else
                info "[DRY-RUN] systemctl stop scst"
                info "[DRY-RUN] modprobe -r qla2xxx_scst"
                _module_load
                info "[DRY-RUN] systemctl start scst"
            fi
            divider
            ;;
        status)
            hdr "Module Status"
            # Show all detected ports and their ISP types
            local port_count=0
            local isp_types_seen=""
            echo -e "\n  ${CYN}Detected ports:${NC}"
            detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
                local state_col="$RED"; [[ "$state" == "Online" ]] && state_col="$GRN"
                echo -e "  [${idx}] ${wwn}  ${isp}  ${host}  ${state_col}${state}${NC}"
            done
            # Count distinct ISP types
            local distinct_types
            distinct_types=$(detect_hbas | awk '{print $4}' | sort -u | grep -v UNKNOWN)
            local type_count; type_count=$(echo "$distinct_types" | grep -c . || true)
            if [[ "$type_count" -gt 1 ]]; then
                warn "Multiple ISP types present: $(echo "$distinct_types" | tr '\n' ' ')"
                warn "Module params apply globally - all ports share the same loaded module"
            fi
            echo ""
            if module_loaded "qla2xxx_scst"; then
                ok "qla2xxx_scst loaded (target mode)"
                local applied configured
                applied=$(get_applied_params)
                configured=$(get_module_params "$isp_type")
                echo -e "\n  ${CYN}Applied params:${NC}"
                echo "  ${applied}"
                echo -e "\n  ${CYN}Configured params (${isp_type}):${NC}"
                echo "  ${configured}"
                if [[ "$applied" == "$configured" ]]; then
                    echo -e "\n  $(ok "Params match configured")"
                else
                    echo -e "\n  $(warn "Params differ from configured - run 'sync --restart' or reboot to resync")"
                fi
            elif module_loaded "qla2xxx"; then
                warn "qla2xxx loaded (initiator mode) - not target mode"
                info "Run 'module load' to switch to target mode"
            else
                err "No QLogic FC module loaded"
            fi
            divider
            ;;
        *) err "Unknown subcommand: ${subcmd}  (load|unload|reload|status)" ;;
    esac
}

# ─── Log management ───────────────────────────────────────────────────────────
# Boot sessions are delimited by "=== PREINIT sync started" marker lines.
# Commands that operate on sessions (boot, last, trim) require at least one
# boot with the marker present to work correctly.

_log_boot_offsets() {
    # Print byte offsets of each boot sync marker line in the log.
    grep -ob "=== Boot sync started" "$LOG" 2>/dev/null | cut -d: -f1 || true
}

_log_session_count() {
    grep -c "=== Boot sync started" "$LOG" 2>/dev/null || echo 0
}

_log_extract_session() {
    # Extract session N (1-based from end) from the log.
    # Session 1 = most recent, 2 = previous, etc.
    local n="${1:-1}"
    local offsets; mapfile -t offsets < <(_log_boot_offsets)
    local total="${#offsets[@]}"
    if [[ $total -eq 0 ]]; then
        warn "No boot markers found in log - boot with qle_adm installed first to enable session commands"
        return 1
    fi
    local idx=$(( total - n ))
    if [[ $idx -lt 0 ]]; then
        err "Only ${total} boot session(s) recorded, cannot show session ${n}"
        return 1
    fi
    local start="${offsets[$idx]}"
    local end=""
    if [[ $(( idx + 1 )) -lt $total ]]; then
        end="${offsets[$(( idx + 1 ))]}"
    fi
    if [[ -n "$end" ]]; then
        dd if="$LOG" bs=1 skip="$start" count=$(( end - start )) 2>/dev/null
    else
        dd if="$LOG" bs=1 skip="$start" 2>/dev/null
    fi
}

_log_strip_trailing_dividers() {
    # Remove trailing +─...─+ divider lines that may have been logged at session end.
    # These arise when a sync run's closing divider() output gets captured into the log.
    # We strip them so cmd_log's own divider() call is the sole session boundary marker.
    local line last_content_line=0 lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done
    # Walk backward, dropping lines that look like a logged divider.
    local end=$(( ${#lines[@]} - 1 ))
    while [[ $end -ge 0 ]]; do
        # Match bare +───+ lines (direct output) and timestamped ones ([...] +───+)
        if [[ "${lines[$end]}" =~ ^(\[[0-9-]{10}\ [0-9:]{8}\]\ )?\+[─\-]+\+$ ]]; then
            end=$(( end - 1 ))
        else
            break
        fi
    done
    local i=0
    while [[ $i -le $end ]]; do
        printf '%s\n' "${lines[$i]}"
        i=$(( i + 1 ))
    done
}

cmd_log() {
    local subcmd="${1:-show}"; shift || true

    # Allow bare --tail N as a shorthand for "show --tail N" since show is the default.
    if [[ "$subcmd" == "--tail" ]]; then
        local _tail_arg="${1:-50}"; shift || true
        set -- "--tail" "$_tail_arg" "$@"
        subcmd="show"
    fi

    case "$subcmd" in
        show)
            # Show the full log, paged. --tail N shows last N lines.
            local tail_n=""
            [[ "${1:-}" == "--tail" ]] && tail_n="${2:-50}"
            if [[ ! -f "$LOG" ]]; then
                info "Log file not found: ${LOG}"
                return 0
            fi
            if [[ -n "$tail_n" ]]; then
                tail -n "$tail_n" "$LOG"
            else
                less +G "$LOG" 2>/dev/null || cat "$LOG"
            fi
            ;;
        boot)
            # Show the current (most recent) boot session.
            if [[ ! -f "$LOG" ]]; then info "Log file not found: ${LOG}"; return 0; fi
            hdr "Current boot session"
            _log_extract_session 1 | _log_strip_trailing_dividers || return 1
            divider
            ;;
        last)
            # Show the previous N boot sessions. Default 1 (the session before current).
            local n="${1:-1}"
            if [[ ! -f "$LOG" ]]; then info "Log file not found: ${LOG}"; return 0; fi
            local i=1
            while [[ $i -le $n ]]; do
                local label; [[ $i -eq 1 ]] && label="Previous boot session" || label="Boot session -${i}"
                hdr "$label"
                _log_extract_session $(( i + 1 )) | _log_strip_trailing_dividers || break
                divider
                i=$(( i + 1 ))
            done
            ;;
        clear)
            if [[ ! -f "$LOG" ]]; then info "Log file not found: ${LOG}"; return 0; fi
            local lines; lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
            warn "This will permanently delete ${lines} lines from ${LOG}"
            confirm_or_abort "Clear log?"
            if [[ $DRY_RUN -eq 0 ]]; then
                : > "$LOG"
                ok "Log cleared: ${LOG}"
            else
                info "[DRY-RUN] would truncate ${LOG}"
            fi
            ;;
        trim)
            # Keep the last N boot sessions, discard older entries. Default 10.
            local keep="${1:-10}"
            if [[ ! -f "$LOG" ]]; then info "Log file not found: ${LOG}"; return 0; fi
            local total; total=$(_log_session_count)
            if [[ $total -eq 0 ]]; then
                warn "No boot markers found - nothing to trim"
                return 0
            fi
            if [[ $total -le $keep ]]; then
                ok "Only ${total} session(s) recorded - nothing to trim (keeping ${keep})"
                return 0
            fi
            local discard=$(( total - keep ))
            warn "Will discard ${discard} oldest boot session(s), keeping ${keep}"
            confirm_or_abort "Trim log?"
            if [[ $DRY_RUN -eq 0 ]]; then
                # Find the byte offset of the (discard+1)th marker - keep from there
                local offsets; mapfile -t offsets < <(_log_boot_offsets)
                local keep_from="${offsets[$discard]}"
                local tmpfile; tmpfile=$(mktemp)
                dd if="$LOG" bs=1 skip="$keep_from" 2>/dev/null > "$tmpfile"
                mv "$tmpfile" "$LOG"
                ok "Log trimmed: kept ${keep} most recent boot session(s)"
            else
                info "[DRY-RUN] would trim ${discard} oldest session(s) from ${LOG}"
            fi
            ;;
        grep)
            local pattern="${1:-}"
            [[ -z "$pattern" ]] && { err "Usage: log grep <pattern>"; return 1; }
            if [[ ! -f "$LOG" ]]; then info "Log file not found: ${LOG}"; return 0; fi
            grep --color=auto "$pattern" "$LOG" || true
            ;;
        path)
            echo "$LOG"
            ;;
        status)
            hdr "Log Status"
            if [[ ! -f "$LOG" ]]; then
                info "Log file not found: ${LOG}"
                divider; return 0
            fi
            local lines; lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
            local size; size=$(du -sh "$LOG" 2>/dev/null | cut -f1 || echo "unknown")
            local sessions; sessions=$(_log_session_count)
            local oldest newest
            oldest=$(head -1 "$LOG" 2>/dev/null | grep -oP '^\[\K[^\]]+' || echo "unknown")
            newest=$(tail -1 "$LOG" 2>/dev/null | grep -oP '^\[\K[^\]]+' || echo "unknown")
            echo -e "  Path     : ${LOG}"
            echo -e "  Size     : ${size}"
            echo -e "  Lines    : ${lines}"
            echo -e "  Sessions : ${sessions} boot session(s) recorded"
            echo -e "  Oldest   : ${oldest}"
            echo -e "  Newest   : ${newest}"
            divider
            ;;
        *)
            err "Unknown log subcommand: ${subcmd}"
            err "Usage: log [show] [--tail N] | boot | last [N] | clear | trim [N] | grep <pattern> | path | status"
            return 1
            ;;
    esac
}




cmd_status() {
    hdr "qle_adm Status v${VERSION}"
    cfg_init
    cfg_check_schema

    # QLE_ADM_HOME display
    echo -e "\n${CYN}Home:${NC}"
    if [[ -z "${QLE_ADM_HOME}" ]]; then
        echo -e "  QLE_ADM_HOME = ${YLW}(not set)${NC}"
        warn "QLE_ADM_HOME is not set - persistent state will not survive reboots"
    elif [[ "${QLE_ADM_HOME}" == /mnt/* ]]; then
        echo -e "  QLE_ADM_HOME = ${WHT}${QLE_ADM_HOME}${NC}"
    else
        echo -e "  QLE_ADM_HOME = ${WHT}${QLE_ADM_HOME}${NC}  ${RED}(non-persistent store)${NC}"
    fi

    local gaps=0

    # HBA swap event — display and clear (shows once after a boot-time auto-migration)
    local swap_event
    swap_event=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    e = d.get('hba_swap_event')
    if e:
        import json as j; print(j.dumps(e))
except: pass
" 2>/dev/null || true)
    if [[ -n "$swap_event" ]]; then
        local ev_action ev_old_isp ev_new_isp ev_at ev_notes
        ev_action=$(python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('action',''))" <<< "$swap_event" 2>/dev/null || echo "")
        ev_old_isp=$(python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('old_isp',''))" <<< "$swap_event" 2>/dev/null || echo "")
        ev_new_isp=$(python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('new_isp',''))" <<< "$swap_event" 2>/dev/null || echo "")
        ev_at=$(python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('detected_at',''))" <<< "$swap_event" 2>/dev/null || echo "")
        ev_notes=$(python3 -c "import json,sys; e=json.loads(sys.stdin.read()); print(e.get('notes',''))" <<< "$swap_event" 2>/dev/null || echo "")
        echo -e "\n${YLW}${SYM_WARN}  HBA swap detected at last boot (${ev_at}):${NC}"
        echo -e "     Action : ${ev_action}"
        echo -e "     Old HBA: ${ev_old_isp}"
        echo -e "     New HBA: ${ev_new_isp}"
        echo -e "     Notes  : ${ev_notes}"
        if [[ "$ev_action" == "bare_block_written" ]]; then
            echo -e "     ${YLW}Run 'hba swap' to migrate configuration to the new card.${NC}"
            gaps=$((gaps + 1))
        fi
        # Clear after display — event is shown only once
        py_json "
import json
d = json.load(open('${CONFIG}'))
d['hba_swap_event'] = None
json.dump(d, open('${CONFIG}', 'w'), indent=2)
" 2>/dev/null || true
    fi
    echo -e "\n${CYN}Modules:${NC}"
    if [[ -d /sys/module/qla2xxx_scst ]]; then
        ok "qla2xxx_scst loaded (target mode)"
        # Warn if multiple distinct ISP types are present - params are global
        local distinct_types
        distinct_types=$(detect_hbas | awk '{print $4}' | sort -u | grep -v UNKNOWN)
        local type_count; type_count=$(echo "$distinct_types" | grep -c . || true)
        [[ "$type_count" -gt 1 ]] && \
            warn "Multiple ISP types detected: $(echo "$distinct_types" | tr '\n' ' ')- module params are global"
    elif [[ -d /sys/module/qla2xxx ]]; then
        warn "qla2xxx loaded (initiator mode) - not target mode"
        gap "qla2xxx_scst not loaded"
        gaps=$((gaps + 1))
    else
        gap "No QLogic FC module loaded"
        gaps=$((gaps + 1))
    fi

    # SCST service
    echo -e "\n${CYN}SCST Service:${NC}"
    local scst_sysfs=0
    [[ -d /sys/kernel/scst_tgt ]] && scst_sysfs=1
    local scst_systemd=0
    systemctl is-active scst &>/dev/null && scst_systemd=1
    if [[ $scst_sysfs -eq 1 && $scst_systemd -eq 1 ]]; then
        ok "scst.service active"
    elif [[ $scst_sysfs -eq 1 && $scst_systemd -eq 0 ]]; then
        ok "SCST running (sysfs active; systemd unit reports inactive - may be middleware-managed)"
    else
        gap "SCST not running - verify under System > Services in the WUI or run: systemctl start scst"
        gaps=$((gaps + 1))
    fi

    # Boot mode and configuration artefacts
    echo -e "\n${CYN}Boot Mode:${NC}"
    local cur_boot_mode; cur_boot_mode=$(cfg_get 'boot_mode' 'grub')
    if [[ ! -f "${CONFIG}" ]]; then
        echo -e "  ${DIM}Not installed - run 'deploy install'${NC}"
    else
        echo -e "  mode: ${WHT}${cur_boot_mode}${NC}"
    fi

    echo -e "\n${CYN}Configuration:${NC}"
    if [[ ! -f "${CONFIG}" ]]; then
        gap "Not installed - run 'deploy install' to set up boot mode and artefacts"
        gaps=$((gaps + 1))
    else
        # modprobe conf — expected in reload/blacklist, must be absent in grub
        if [[ "$cur_boot_mode" == "grub" ]]; then
            if [[ -f "$MODPROBE_CONF" ]]; then
                warn "modprobe conf present in grub mode (conflict risk): ${MODPROBE_CONF}"
                gaps=$((gaps + 1))
            else
                ok "modprobe conf absent (correct for grub mode)"
            fi
            # Check and display kernel_extra_options owned tokens
            local cur_opts; cur_opts=$(grub_read_current)
            local parsed; parsed=$(grub_parse "$cur_opts")
            local owned; owned=$(echo "$parsed" | grep '^OWNED:' | cut -d: -f2-)
            echo -e "  kernel_extra_options: ${DIM}${cur_opts:-<empty>}${NC}"
            if [[ -n "${owned// /}" ]]; then
                ok "kernel_extra_options: qle_adm-owned tokens present"
            else
                gap "kernel_extra_options: no qle_adm-owned tokens found - run 'deploy reconfigure'"
                gaps=$((gaps + 1))
            fi
        else
            if [[ -f "$MODPROBE_CONF" ]]; then
                ok "modprobe conf present: ${MODPROBE_CONF}"
                local conf_opts; conf_opts=$(grep '^options' "$MODPROBE_CONF" 2>/dev/null | sed 's/options qla2xxx_scst //' || true)
                [[ -n "$conf_opts" ]] && echo -e "  ${DIM}options: ${conf_opts}${NC}"
            else
                gap "modprobe conf missing: ${MODPROBE_CONF}"
                gap "  This is normal after a BE change or upgrade - the boot entry will"
                gap "  restore it on next reboot. To restore now: sync --boot"
                gaps=$((gaps + 1))
            fi
        fi

        # blacklist mode: check and display kernel_extra_options tokens
        if [[ "$cur_boot_mode" == "blacklist" ]]; then
            local cur_opts; cur_opts=$(grub_read_current)
            echo -e "  kernel_extra_options: ${DIM}${cur_opts:-<empty>}${NC}"
            if echo "$cur_opts" | grep -q "module_blacklist=qla2xxx_scst"; then
                ok "kernel_extra_options: module_blacklist=qla2xxx_scst present"
            else
                gap "kernel_extra_options: module_blacklist=qla2xxx_scst missing - run 'deploy reconfigure'"
                gaps=$((gaps + 1))
            fi
            if echo "$cur_opts" | grep -qw "rootwait"; then
                ok "kernel_extra_options: rootwait present"
            else
                gap "kernel_extra_options: rootwait missing - run 'deploy reconfigure'"
                gaps=$((gaps + 1))
            fi
        fi

        # SCST ordering drop-in — all modes
        if [[ -f "$SCST_DROPIN" ]]; then
            ok "SCST ordering drop-in present: ${SCST_DROPIN}"
        else
            gap "SCST ordering drop-in missing: ${SCST_DROPIN}"
            gap "Run 'sync --boot' or 'deploy install' to restore it"
            gaps=$((gaps + 2))
        fi

        # Boot entry — all modes
        if initscript_status; then
            true
        else
            gaps=$((gaps + 1))
        fi

        if grep -q "TARGET_DRIVER qla2x00t" /etc/scst.conf 2>/dev/null; then
            ok "scst.conf contains TARGET_DRIVER qla2x00t block"
        else
            gap "scst.conf missing TARGET_DRIVER qla2x00t block - run 'qle_adm.sh sync'"
            gaps=$((gaps + 1))
        fi

        # Verify qla2x00t is actually registered with the running SCST instance.
        if [[ $scst_sysfs -eq 1 ]]; then
            if [[ -d /sys/kernel/scst_tgt/targets/qla2x00t ]]; then
                ok "qla2x00t registered with SCST"
            else
                gap "qla2x00t not registered with SCST"
                gap "PREINIT may not have run, or SCST started before PREINIT completed"
                gap "Run 'sync --restart' to recover, or reinstall to restore boot entries"
                gaps=$((gaps + 3))
            fi
        fi
    fi # end: installed check

    # Param drift check
    local isp_type; isp_type=$(get_isp_type_dominant 2>/dev/null || echo "")
    if [[ -n "$isp_type" ]] && module_loaded "qla2xxx_scst"; then
        local applied configured
        applied=$(get_applied_params)
        configured=$(get_module_params "$isp_type")
        if [[ -n "$applied" && "$applied" != "$configured" ]]; then
            gap "Module params drift - applied differs from configured"
            if [[ "$cur_boot_mode" == "grub" ]]; then
                gap "grub mode: params are set via kernel cmdline - reboot to resync"
            else
                gap "Run 'sync --restart' or reboot to resync (likely caused by a BE change)"
            fi
            gaps=$((gaps + 2))
        fi
    fi

    # Firmware
    echo -e "\n${CYN}Firmware:${NC}"
    detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
        local selected; selected=$(fw_selected "$isp")
        local sel_label
        case "$selected" in
            hba)  sel_label="${DIM}HBA flash${NC}" ;;
            dist) sel_label="${CYN}dist${NC}" ;;
            *)    sel_label="${CYN}v${selected}${NC}" ;;
        esac
        echo -e "  [${idx}] ${host} (${isp})  running=${fw}  source=${sel_label}"
    done

    # Port status
    echo -e "\n${CYN}FC Ports:${NC}"
    local enabled_ports; enabled_ports=$(cfg_get_list "enabled_ports")
    detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
        local managed
        echo "$enabled_ports" | grep -q "$wwn" && managed="${GRN}[managed]${NC}" || managed="${DIM}[unmanaged]${NC}"
        local state_color="$RED"
        [[ "$state" == "Online" ]] && state_color="$GRN"
        local ptype_short; ptype_short=$(echo "$ptype" | sed 's/Point-To-Point (direct nport connection)/P2P/')
        echo -e "  [${idx}] ${wwn}  ${isp}  ${host}"
        echo -e "      State: ${state_color}${state}${NC}  Type: ${ptype_short}  FW: ${fw}  ${managed}"
    done

    # Sessions
    echo -e "\n${CYN}Active Sessions:${NC}"
    local session_count=0
    local i=0
    for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
        [[ -d "$sess_path" ]] || continue
        local init_wwn tgt_wwn cmds
        init_wwn=$(basename "$sess_path")
        tgt_wwn=$(echo "$sess_path" | grep -oP '(?<=qla2x00t/)[^/]+')
        cmds=$(sysfs_read "${sess_path}/active_commands")
        local init_label tgt_label
        init_label=$(wwn_label "$init_wwn" "initiator")
        tgt_label=$(wwn_label "$tgt_wwn" "target")
        echo -e "  [${i}] ${GRN}${SYM_BULLET}${NC} ${init_wwn} (${CYN}${init_label}${NC}) ${SYM_INFO} ${tgt_wwn} (${CYN}${tgt_label}${NC})  (active_cmds: ${cmds})"
        cfg_record_seen_initiator "$init_wwn"
        i=$((i + 1))
        session_count=$((session_count + 1))
    done
    [[ $session_count -eq 0 ]] && echo -e "  ${DIM}(no active sessions)${NC}" || true

    echo ""
    if [[ $gaps -eq 0 ]]; then
        ok "No gaps detected - system fully operational"
    else
        warn "${gaps} gap(s) detected - review GAP lines above for remediation"
    fi
    divider
}

cmd_hba() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        swap)
            hdr "HBA Swap"
            cfg_init
            cfg_check_schema

            local force=0
            for arg in "$@"; do [[ "$arg" == "--force" ]] && force=1; done

            # Detect current hardware
            local det_isp det_count det_wwns_json
            det_isp=$(get_isp_type_dominant 2>/dev/null)
            [[ -z "$det_isp" || "$det_isp" == "UNKNOWN" ]] && det_isp="ISP2532"
            det_count=$(ls /sys/class/fc_host/ 2>/dev/null | grep -c 'host' || echo 0)
            det_wwns_json=$(python3 -c "
import os, json
try:
    hosts = sorted(h for h in os.listdir('/sys/class/fc_host/') if h.startswith('host'))
    wwns = []
    for h in hosts:
        raw = open(f'/sys/class/fc_host/{h}/port_name').read().strip().replace('0x','')
        wwns.append(':'.join(raw[i:i+2] for i in range(0,16,2)))
    print(json.dumps(wwns))
except: print('[]')
" 2>/dev/null || echo "[]")

            if [[ "$det_count" -eq 0 ]]; then
                err "No FC ports detected - is qla2xxx_scst loaded?"
                return 1
            fi

            local cfg_isp cfg_count cfg_wwns_json
            cfg_isp=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print(d.get('hba_identity', {}).get('isp_type', ''))
except: print('')
")
            cfg_count=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print(d.get('hba_identity', {}).get('port_count', 0))
except: print(0)
")
            cfg_wwns_json=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    import json as j; print(j.dumps(d.get('hba_identity', {}).get('port_wwns', [])))
except: print('[]')
")

            info "Configured HBA: ${cfg_isp:-<none>}  ${cfg_count}-port"
            info "Detected HBA:   ${det_isp}  ${det_count}-port"
            echo ""

            # Guard: no hba_identity registered yet — cannot migrate or map
            if [[ -z "$cfg_isp" ]]; then
                warn "No HBA identity registered in config.json."
                warn "Run 'deploy reconfigure' to register the current card,"
                warn "or use 'hba swap --force' to clear and rebuild FC config from scratch."
                return 1
            fi

            if [[ $force -eq 1 ]]; then
                # Force path: clear FC config, register new identity, require manual port enable
                warn "Force mode: clearing enabled_ports and target WWN names"
                warn "Assignments, extents, and initiator names are preserved."
                confirm_or_abort "Clear FC port config and register new HBA identity?"
                local now; now=$(date -u +"%Y-%m-%dT%H:%M:%S")
                python3 << PYEOF
import json
cfg = json.load(open('${CONFIG}'))
old_wwns = json.loads("""${cfg_wwns_json}""")
old_target_set = set(old_wwns)
# Clear enabled_ports
cfg['enabled_ports'] = []
# Remove target-side wwn_names only; preserve initiator entries
new_names = {w: e for w, e in cfg.get('wwn_names', {}).items() if w not in old_target_set}
cfg['wwn_names'] = new_names
cfg['hba_identity'] = {
    'isp_type':      '${det_isp}',
    'port_count':    ${det_count},
    'port_wwns':     json.loads("""${det_wwns_json}"""),
    'model':         '',
    'registered_at': '${now}'
}
json.dump(cfg, open('${CONFIG}', 'w'), indent=2)
PYEOF
                ok "HBA identity updated. Run 'deploy reconfigure' then 'port enable' to activate FC targets."
                return 0
            fi

            # Validate auto-migrate conditions
            if [[ "$det_isp" != "$cfg_isp" ]]; then
                err "ISP type changed (${cfg_isp} → ${det_isp}) - use 'hba swap --force' for cross-ISP migration"
                return 1
            fi
            if [[ "$det_count" -lt "$cfg_count" ]]; then
                err "New card has fewer ports (${det_count} < ${cfg_count}) - use 'hba swap --force'"
                return 1
            fi

            # Show mapping table
            python3 << PYEOF
import json
old_wwns = json.loads("""${cfg_wwns_json}""")
new_wwns = json.loads("""${det_wwns_json}""")
print("  Port mapping:")
for i, old in enumerate(old_wwns):
    print(f"    old nas0:{i}  {old}  →  new nas0:{i}  {new_wwns[i]}")
extra = new_wwns[len(old_wwns):]
for j, w in enumerate(extra):
    print(f"    new (unactivated):  nas0:{len(old_wwns)+j}  {w}")
PYEOF
            echo ""
            confirm_or_abort "Apply this port mapping?"

            # Execute migration (same logic as PREINIT auto_migrate)
            SWAP_CFG_ISP="$cfg_isp"
            SWAP_CFG_COUNT="$cfg_count"
            SWAP_CFG_WWNS="$cfg_wwns_json"
            SWAP_DET_ISP="$det_isp"
            SWAP_DET_COUNT="$det_count"
            SWAP_DET_WWNS="$det_wwns_json"
            preinit_swap_execute "auto_migrate"

            # Apply to live sysfs if SCST is running
            if systemctl is-active scst &>/dev/null; then
                info "Applying to live sysfs..."
                scstadmin_apply 0 && ok "Live sysfs updated" || warn "scstadmin apply failed - restart SCST to apply"
            else
                info "SCST not running - changes will take effect at next boot"
            fi

            ok "HBA swap complete. Run 'status' to verify."
            ;;

        *)
            err "Usage: hba swap [--force]"
            err "  hba swap          - auto-migrate port config to new card (same ISP, same or more ports)"
            err "  hba swap --force  - clear FC port config for manual reconfiguration (cross-ISP or port reduction)"
            return 1
            ;;
    esac
}

cmd_list_hba() {
    hdr "HBA Information"
    detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
        local scsi_host="/sys/class/scsi_host/${host}"
        local fc_host="/sys/class/fc_host/${host}"

        local fw_raw fw_build
        fw_raw=$(sysfs_read "${scsi_host}/fw_version" 2>/dev/null || echo "unknown")
        fw_ver=$(echo "$fw_raw" | awk '{print $1}')
        fw_build=$(echo "$fw_raw" | grep -oP '(?<=\()\d+(?=\))' || echo "")

        local ptype_short
        ptype_short=$(echo "$ptype" | sed 's/Point-To-Point (direct nport connection)/Point-To-Point/')

        local state_val
        [[ "$state" == "Online" ]] && state_val="${GRN}${state}${NC}" || state_val="${RED}${state}${NC}"

        local speed max_speed
        speed=$(sysfs_read "${fc_host}/speed" 2>/dev/null | grep -oP '[0-9]+' | head -1 || echo "?")
        max_speed=$(sysfs_read "${fc_host}/supported_speeds" 2>/dev/null | grep -oP '[0-9]+' | tail -1 || echo "?")

        local optrom_fw primary_fw serial model
        optrom_fw=$(sysfs_read "${scsi_host}/optrom_fw_version" 2>/dev/null | awk '{print $1}' || echo "")
        primary_fw=$(sysfs_read "${scsi_host}/optrom_gold_fw_version" 2>/dev/null | awk '{print $1}' || echo "")
        serial=$(sysfs_read "${scsi_host}/serial_num" 2>/dev/null || echo "")
        model=$(sysfs_read "${scsi_host}/model_desc" 2>/dev/null || echo "")

        local pci_lnkcap_speed pci_lnkcap_width pci_lnksta_speed pci_lnksta_width pci_downgraded
        local lspci_out; lspci_out=$(lspci -vv -s "$pci" 2>/dev/null)
        pci_lnkcap_speed=$(echo "$lspci_out" | grep -oP 'LnkCap:.*Speed \K[^,]+' || echo "?")
        pci_lnkcap_width=$(echo "$lspci_out" | grep -oP 'LnkCap:.*Width \K[^,]+' || echo "?")
        pci_lnksta_speed=$(echo "$lspci_out" | grep -oP 'LnkSta:.*Speed \K[^,]+' || echo "?")
        pci_lnksta_width=$(echo "$lspci_out" | grep -oP 'LnkSta:.*Width \K\S+' || echo "?")
        pci_downgraded=""
        echo "$lspci_out" | grep -q "downgraded" && pci_downgraded=" [${YLW}downgraded${NC}]"

        local fw_file stored stored_ver
        fw_file="${ISP_FW_FILE[$isp]:-}"
        stored="${FIRMWARE_DIR}/${isp}/${fw_file}"
        [[ -n "$fw_file" && -f "$stored" ]] && \
            stored_ver=$(strings "$stored" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown") || \
            stored_ver=""

        local primary_fw_val optrom_fw_val stored_ver_val
        primary_fw_val="${primary_fw:-${DIM}not exposed by driver${NC}}"
        optrom_fw_val="${optrom_fw:-${DIM}n/a${NC}}"
        stored_ver_val="${stored_ver:-${DIM}none${NC}}"

        echo -e "\n${DIM}[${idx}]${NC} ${host} - ${isp} @ ${DIM}${pci}${NC}"
        echo -e "  ${CYN}WWN        :${NC} ${DIM}${wwn}${NC}"
        echo -e "  ${CYN}Running FW :${NC} ${fw_ver}${fw_build:+ (build ${fw_build})}"
        echo -e "  ${CYN}Primary FW :${NC} ${primary_fw_val}"
        echo -e "  ${CYN}Optrom FW  :${NC} ${optrom_fw_val}"
        echo -e "  ${CYN}Stored FW  :${NC} ${stored_ver_val}"
        echo -e "  ${CYN}Port State :${NC} [${state_val}]"
        echo -e "  ${CYN}Port Type  :${NC} ${ptype_short}"
        echo -e "  ${CYN}Link Speed :${NC} ${speed} Gbps"
        echo -e "  ${CYN}Max Speed  :${NC} ${max_speed} Gbps"
        echo -e "  ${CYN}Model      :${NC} ${model}"
        echo -e "  ${CYN}Serial     :${NC} ${serial}"
        echo -e "  ${CYN}PCIe Cap   :${NC} ${pci_lnkcap_speed} ${pci_lnkcap_width}"
        echo -e "  ${CYN}PCIe Link  :${NC} ${pci_lnksta_speed} ${pci_lnksta_width}${pci_downgraded}"
    done
    divider
}

cmd_list_all() {
    # Run all five list commands with per-command dividers suppressed;
    # print a single divider at the very end.
    local _LIST_ALL_MODE=1
    cmd_list_hba
    cmd_list_ports
    cmd_list_extents
    cmd_list_initiators
    cmd_list_mapping
    _divider_force
}

cmd_list_ports() {
    hdr "FC Ports"
    cfg_init
    cfg_check_schema
    local enabled_ports; enabled_ports=$(cfg_get_list "enabled_ports")
    detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
        local managed_val state_val ptype_short
        echo "$enabled_ports" | grep -q "$wwn" && managed_val="${GRN}managed${NC}" || managed_val="${YLW}unmanaged${NC}"
        [[ "$state" == "Online" ]] && state_val="${GRN}${state}${NC}" || state_val="${RED}${state}${NC}"
        ptype_short=$(echo "$ptype" | sed 's/Point-To-Point (direct nport connection)/P2P/')
        local label; label=$(wwn_label "$wwn" "target")
        echo -e "  ${DIM}[${idx}]${NC} ${DIM}${wwn}${NC} (${CYN}${label}${NC})  ${isp}  ${host}  [${state_val}]  ${ptype_short}  [${managed_val}]"
    done
    divider
}

cmd_list_extents() {
    hdr "Available Extents"
    local open_extents; open_extents=$(cfg_get_list "open_extents")

    # Build scst.conf device set once for stale detection.
    # An extent in config.json that is absent from scst.conf was deleted
    # via the WUI without going through qle_adm unassign.
    local scst_devices; scst_devices=$(get_scst_conf_devices)

    local idx=0
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        local status live_status _w stale_tag=""

        # Stale check: extent is in config.json but not in scst.conf.
        local stale=0
        if [[ -n "$scst_devices" ]]; then
            echo "$scst_devices" | grep -q "^${ext}$" || stale=1
        fi

        # Size and serial number from SCST sysfs — reported immediately after
        # the extent name as physical facts about the device.
        local dev_path="/sys/kernel/scst_tgt/devices/${ext}"
        local size="" serial=""
        if [[ -d "$dev_path" ]]; then
            local size_mb_raw; size_mb_raw=$(sysfs_read "${dev_path}/size_mb" 2>/dev/null || echo "")
            if [[ -n "$size_mb_raw" && "$size_mb_raw" =~ ^[0-9]+$ ]]; then
                local size_val
                size_val=$(python3 -c "
mb = int('${size_mb_raw}')
gib = mb / 1024.0
mib = mb
kib = mb * 1024
if gib >= 1.0:
    print(f'{gib:.2f} GiB')
elif mib >= 1:
    print(f'{mib:.2f} MiB')
else:
    print(f'{kib:.2f} KiB')
" 2>/dev/null || echo "${size_mb_raw} MB")
                size="${CYN}size:${NC}${size_val}"
            fi
            # Read the SCSI Unit Serial Number (USN) directly from SCST sysfs.
            # This is the serial the initiator sees via INQUIRY page 0x80,
            # and is always present when the device is registered. Avoids
            # probing udevadm which has no serial data for zvols.
            local usn; usn=$(sysfs_read "${dev_path}/usn" 2>/dev/null || echo "")
            usn="${usn%\[key\]}"
            [[ -n "$usn" ]] && serial="${CYN}s/n:${NC}${usn}"
        fi

        # config:[...] — unified config state. Brackets contain OPEN and/or group
        # names. Both can appear simultaneously (extent is open AND in a group).
        # OPEN appears first if present; group names follow in sorted order.
        # Examples: config:[UNMAPPED]  config:[OPEN]  config:[g1ed2]  config:[OPEN,g1ed2,vostro]
        status=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    is_open = '${ext}' in d.get('open_extents', [])
    grps = sorted(g for g,data in d.get('groups',{}).items() if '${ext}' in data.get('luns',{}))
    parts = (['OPEN'] if is_open else []) + grps
    print(','.join(parts) if parts else 'UNMAPPED')
except:
    print('UNMAPPED')
")
        if [[ "$status" == "UNMAPPED" ]]; then
            status="${CYN}config:${NC}${DIM}[UNMAPPED]${NC}"
            stale_tag=""
        else
            # Build stale remediation hints (one line per group) before wrapping
            if [[ $stale -eq 1 ]]; then
                for _w in $(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    grps = sorted(g for g,data in d.get('groups',{}).items() if '${ext}' in data.get('luns',{}))
    print(' '.join(grps))
except: pass
"); do
                    stale_tag+=$'\n'"      ${DIM}run: group unmap ${_w} ${ext}${NC}"
                done
            fi
            if [[ "$status" == OPEN* ]] && [[ "$status" != *,* ]]; then
                status="${CYN}config:${NC}${GRN}[OPEN]${NC}"
            elif [[ "$status" == OPEN* ]]; then
                status="${CYN}config:${NC}${GRN}[${status}]${NC}"
            else
                status="${CYN}config:${NC}[${status}]"
            fi
        fi

        if [[ $stale -eq 1 ]]; then
            live_status="${YLW}[stale - not in scst.conf]${NC}"
        else
            # Live sysfs status - four states:
            #   sysfs:[no sysfs]  - LUN not in sysfs at all; run 'sync --apply'
            #   sysfs:[mapped]    - LUN in sysfs ini_group, no initiator session
            #   sysfs:[connected] - initiator session present, no command in flight
            #   sysfs:[active]    - active_commands > 0 on this LUN right now
            #
            # Detection: each ini_group lun dir contains a 'device' symlink ->
            # ../../../../../../../devices/<extent-name>. Read it to confirm
            # the extent is mapped. Then check for a session on the same target
            # for the same initiator group. If found, check session I/O counters.
            # Per-lun active_commands is available under session/lun<N>/.
            local lun_found=0
            local matched_target="" matched_lun_n="" matched_init_group=""
            if [[ -d /sys/kernel/scst_tgt/targets/qla2x00t ]]; then
                for lun_dir in /sys/kernel/scst_tgt/targets/qla2x00t/*/ini_groups/*/luns/[0-9]*/; do
                    [[ -L "${lun_dir}device" ]] || continue
                    local dev_target; dev_target=$(readlink -f "${lun_dir}device" 2>/dev/null || true)
                    if [[ "$(basename "$dev_target")" == "$ext" ]]; then
                        lun_found=1
                        matched_target=$(echo "$lun_dir" | grep -oP '(?<=qla2x00t/)[^/]+')
                        matched_init_group=$(echo "$lun_dir" | grep -oP '(?<=ini_groups/)[^/]+')
                        matched_lun_n=$(basename "${lun_dir%/}")
                        break
                    fi
                done
            fi

            if [[ $lun_found -eq 0 ]]; then
                live_status="${CYN}sysfs:${NC}${YLW}[no sysfs]${NC}"
            else
                # Session detection: sessions are indexed by initiator WWN, not
                # group name. Look up the group's initiator WWNs from config.json
                # then search all target sessions for any matching WWN.
                local group_inits
                group_inits=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    inits = d.get('groups', {}).get('${matched_init_group}', {}).get('initiators', [])
    print(' '.join(inits))
except: pass
")
                local sess_path=""
                for _tgt_dir in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
                    [[ -d "$_tgt_dir" ]] || continue
                    local _sp_name; _sp_name=$(basename "${_tgt_dir%/}")
                    for _init_wwn in $group_inits; do
                        if [[ "${_sp_name,,}" == "${_init_wwn,,}" ]]; then
                            sess_path="$_tgt_dir"
                            break 2
                        fi
                    done
                done
                if [[ -z "$sess_path" ]]; then
                    live_status="${CYN}sysfs:${NC}${DIM}[mapped]${NC}"
                else
                    # Gate on active_commands for this LUN only.
                    # [active]    = command(s) in flight on this LUN right now.
                    # [connected] = session present, no command in flight.
                    # Session-level lifetime IO counters are not used: they
                    # accumulate across all LUNs and would make every extent
                    # in the group appear active after any one LUN is used.
                    local lun_path="${sess_path}lun${matched_lun_n}"
                    local ac
                    ac=$(hex_to_dec "$(sysfs_read "${lun_path}/active_commands" 2>/dev/null || echo 0)")
                    if [[ $ac -eq 0 ]]; then
                        live_status="${CYN}sysfs:${NC}${GRN}[connected]${NC}"
                    else
                        live_status="${CYN}sysfs:${NC}${GRN}[active]${NC} ${DIM}(active_cmds:${ac})${NC}"
                    fi
                fi
            fi
        fi

        echo -e "  ${DIM}[${idx}]${NC} ${ext}  ${size}  ${serial:+${serial}  }${status}  ${live_status}${stale_tag}"
        idx=$((idx + 1))
    done < <(get_extents_sorted)

    # Stale extents: in config.json assignments but not in scst.conf and
    # not already shown via get_extents_sorted (which reads scst.conf).
    local stale_extents
    stale_extents=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    scst_devs = set('''${scst_devices}'''.split()) if '''${scst_devices}'''.strip() else set()
    cfg_exts = set()
    for ext in d.get('open_extents', []):
        cfg_exts.add(ext)
    for grp, data in d.get('groups', {}).items():
        for ext in data.get('luns', {}).keys():
            cfg_exts.add(ext)
    for ext in sorted(cfg_exts - scst_devs):
        print(ext)
except: pass
")
    if [[ -n "$stale_extents" ]]; then
        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            local _w cfg_label="" unmap_cmds=""
            local grp_list
            grp_list=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    is_open = '${ext}' in d.get('open_extents', [])
    grps = sorted(g for g,data in d.get('groups',{}).items() if '${ext}' in data.get('luns',{}))
    parts = (['OPEN'] if is_open else []) + grps
    print(','.join(parts) if parts else 'UNMAPPED')
except:
    print('UNMAPPED')
")
            if [[ "$grp_list" == "UNMAPPED" ]]; then
                cfg_label="${CYN}config:${NC}${DIM}[UNMAPPED]${NC}"
            elif [[ "$grp_list" == OPEN* ]] && [[ "$grp_list" != *,* ]]; then
                cfg_label="${CYN}config:${NC}${GRN}[OPEN]${NC}"
            elif [[ "$grp_list" == OPEN* ]]; then
                cfg_label="${CYN}config:${NC}${GRN}[${grp_list}]${NC}"
            else
                cfg_label="${CYN}config:${NC}[${grp_list}]"
            fi
            for _w in $(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    grps = sorted(g for g,data in d.get('groups',{}).items() if '${ext}' in data.get('luns',{}))
    print(' '.join(grps))
except: pass
"); do
                unmap_cmds+=$'\n'"      ${DIM}run: group unmap ${_w} ${ext}${NC}"
            done
            echo -e "  ${DIM}[*]${NC} ${ext}  ${cfg_label}  ${YLW}[stale - not in scst.conf]${NC}${unmap_cmds}"
            idx=$((idx + 1))
        done <<< "$stale_extents"
    fi

    [[ $idx -eq 0 ]] && echo -e "  ${DIM}No extents found in ${SCST_CONF}${NC}" || true
    divider
}

cmd_list_initiators() {
    hdr "Initiators"

    echo -e "\n${CYN}Connected:${NC}"
    local found=0
    local i=0
    for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
        [[ -d "$sess_path" ]] || continue
        local init_wwn tgt_wwn cmds rc wc rk wk
        init_wwn=$(basename "$sess_path")
        tgt_wwn=$(echo "$sess_path" | grep -oP '(?<=qla2x00t/)[^/]+')
        cmds=$(hex_to_dec "$(sysfs_read "${sess_path}/commands")")
        rc=$(hex_to_dec   "$(sysfs_read "${sess_path}/read_cmd_count")")
        wc=$(hex_to_dec   "$(sysfs_read "${sess_path}/write_cmd_count")")
        rk=$(hex_to_dec   "$(sysfs_read "${sess_path}/read_io_count_kb")")
        wk=$(hex_to_dec   "$(sysfs_read "${sess_path}/write_io_count_kb")")
        local init_label tgt_label
        init_label=$(wwn_label "$init_wwn" "initiator")
        tgt_label=$(wwn_label "$tgt_wwn" "target")
        echo -e "  ${DIM}[${i}]${NC} ${GRN}${SYM_BULLET}${NC} ${DIM}${init_wwn}${NC} (${CYN}${init_label}${NC}) ${SYM_INFO} ${DIM}${tgt_wwn}${NC} (${CYN}${tgt_label}${NC})"
        echo -e "       ${CYN}cmds:${NC}${cmds}  ${CYN}R:${NC}${rc} (${rk} KB)  ${CYN}W:${NC}${wc} (${wk} KB)"
        cfg_record_seen_initiator "$init_wwn"
        i=$((i + 1))
        found=$((found + 1))
    done
    [[ $found -eq 0 ]] && echo -e "  ${DIM}(none)${NC}" || true

    echo -e "\n${CYN}Previously Seen:${NC}"
    local seen_list
    seen_list=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    seen = d.get('seen_initiators', {})
    for wwn, ts in sorted(seen.items(), key=lambda x: x[1], reverse=True):
        print(f'{wwn} {ts}')
except: pass
")
    if [[ -z "$seen_list" ]]; then
        echo -e "  ${DIM}(none recorded)${NC}"
    else
        while IFS=' ' read -r wwn ts; do
            local lbl; lbl=$(wwn_label "$wwn" "initiator")
            echo -e "  ${DIM}${wwn}${NC} (${CYN}${lbl}${NC})  ${CYN}last seen:${NC} ${ts}"
        done <<< "$seen_list"
    fi
    divider
}

cmd_list_mapping() {
    hdr "LUN Mapping Topology"

    local scst_devices; scst_devices=$(get_scst_conf_devices)

    # ── Open access ────────────────────────────────────────────────────────────
    echo -e "\n${CYN}Open Access (all initiators):${NC}"
    local open_extents; open_extents=$(cfg_get_list "open_extents")
    if [[ -z "$open_extents" ]]; then
        echo -e "  ${DIM}(none)${NC}"
    else
        local lun=0
        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            local stale_tag=""
            if [[ -n "$scst_devices" ]] && ! echo "$scst_devices" | grep -q "^${ext}$"; then
                stale_tag=$'\n'"      ${DIM}run: close ${ext}${NC}"
            fi
            echo -e "  ${CYN}LUN ${lun}:${NC} ${ext}${stale_tag}"
            lun=$((lun + 1))
        done <<< "$open_extents"
    fi

    # ── Group definitions ──────────────────────────────────────────────────────
    echo -e "\n${CYN}Groups:${NC}"
    local _tmp; _tmp=$(mktemp)
    cat > "$_tmp" << 'PYEOF'
import json, sys
cfg = sys.argv[1]
try:
    d = json.load(open(cfg))
    groups = d.get("groups", {})
    port_groups = d.get("port_groups", {})
    for grp, data in groups.items():
        luns_map = data.get("luns", {})
        initiators = data.get("initiators", [])
        pairs = " ".join(str(lun_id) + ":" + ext for ext, lun_id in luns_map.items())
        inits = ",".join(initiators)
        ports = ",".join(p for p, gs in port_groups.items() if grp in gs)
        mapped = "yes" if luns_map else "no"
        print(grp + "|" + inits + "|" + pairs + "|" + ports + "|" + mapped)
except: pass
PYEOF
    local grp_list; grp_list=$(python3 "$_tmp" "${CONFIG}" 2>/dev/null)
    rm -f "$_tmp"
    if [[ -z "$grp_list" ]]; then
        echo -e "  ${DIM}(none)${NC}"
    else
        local stale_warned=0
        while IFS='|' read -r grp inits pairs ports mapped; do
            if [[ "$mapped" == "no" ]]; then
                echo -e "  ${grp}  ${DIM}(no LUN mappings)${NC}"
            else
                echo -e "  ${grp}"
            fi
            if [[ -n "$inits" ]]; then
                IFS=',' read -ra init_arr <<< "$inits"
                for init_wwn in "${init_arr[@]}"; do
                    local ilbl; ilbl=$(wwn_label "$init_wwn" "initiator")
                    echo -e "    ${CYN}initiator:${NC} ${DIM}${init_wwn}${NC} (${ilbl})"
                done
            else
                echo -e "    ${CYN}initiators:${NC} ${DIM}(none)${NC}"
            fi
            if [[ -n "$ports" ]]; then
                IFS=',' read -ra port_arr <<< "$ports"
                for port_wwn in "${port_arr[@]}"; do
                    local plbl; plbl=$(wwn_label "$port_wwn" "target")
                    echo -e "    ${CYN}port:${NC} ${DIM}${port_wwn}${NC} (${plbl})"
                done
            else
                echo -e "    ${YLW}not attached to any port${NC}"
            fi
            if [[ -n "$pairs" ]]; then
                for pair in $pairs; do
                    local lun ext stale_tag=""
                    lun="${pair%%:*}"
                    ext="${pair#*:}"
                    if [[ -n "$scst_devices" ]] && ! echo "$scst_devices" | grep -q "^${ext}$"; then
                        stale_tag=$'\n'"        ${DIM}run: group unmap ${grp} ${ext}${NC}"
                        stale_warned=1
                    fi
                    echo -e "    ${CYN}LUN ${lun}:${NC} ${ext}${stale_tag}"
                done
            fi
        done <<< "$grp_list"
        if [[ $stale_warned -eq 1 ]]; then
            echo ""
            echo -e "  ${YLW}Stale mappings exist. The extent was removed from the WUI without${NC}"
            echo -e "  ${YLW}going through qle_adm. Run 'group unmap <group> <extent>' to clean up.${NC}"
        fi
    fi

    # ── Port-centric summary ───────────────────────────────────────────────────
    echo -e "\n${CYN}Port Associations:${NC}"
    local enabled_ports; enabled_ports=$(cfg_get_list "enabled_ports")
    if [[ -z "$enabled_ports" ]]; then
        echo -e "  ${DIM}(no ports enabled)${NC}"
    else
        while IFS= read -r pwwn; do
            [[ -z "$pwwn" ]] && continue
            local plbl; plbl=$(wwn_label "$pwwn" "target")
            local port_grps
            port_grps=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    gs = d.get('port_groups', {}).get('${pwwn}', [])
    print(' '.join(gs) if gs else '')
except: pass
")
            if [[ -n "$port_grps" ]]; then
                echo -e "  ${DIM}${pwwn}${NC} (${CYN}${plbl}${NC}): ${port_grps}"
            else
                echo -e "  ${DIM}${pwwn}${NC} (${CYN}${plbl}${NC}): ${YLW}(no groups attached)${NC}"
            fi
        done <<< "$enabled_ports"
    fi

    divider
}

cmd_port_enable() {
    local wwn_arg="" port_idx="" attach_all=0
    # Parse args: positional WWN/index and optional --attach-all
    local _parsed_pos=0
    for _a in "$@"; do
        if [[ "$_a" == "--attach-all" ]]; then attach_all=1
        elif [[ $_parsed_pos -eq 0 && -n "$_a" ]]; then
            # Could be a WWN or used as port_idx from --port N passed by main
            wwn_arg="$_a"; _parsed_pos=1
        fi
    done
    # opt_port from main() is passed as second positional
    port_idx="${2:-}"
    local wwn; wwn=$(resolve_port "$wwn_arg" "$port_idx")
    [[ -z "$wwn" ]] && { err "Usage: port enable <wwn>|--port N [--attach-all]"; return 1; }
    wwn=$(echo "$wwn" | tr '[:upper:]' '[:lower:]')
    info "Enabling port ${wwn}"
    cfg_list_add "enabled_ports" "$wwn"
    # Initialise port_groups entry (empty by default)
    py_json "
import json
d = json.load(open('${CONFIG}'))
pg = d.setdefault('port_groups', {})
if '${wwn}' not in pg:
    pg['${wwn}'] = []
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
    if [[ $attach_all -eq 1 ]]; then
        local all_groups
        all_groups=$(py_json "
import json
d = json.load(open('${CONFIG}'))
for g in d.get('groups', {}).keys():
    print(g)
")
        if [[ -n "$all_groups" ]]; then
            py_json "
import json
d = json.load(open('${CONFIG}'))
pg = d.setdefault('port_groups', {})
existing = pg.get('${wwn}', [])
for g in d.get('groups', {}).keys():
    if g not in existing:
        existing.append(g)
pg['${wwn}'] = existing
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            info "All groups attached to port ${wwn}"
        else
            info "No groups defined yet - port_groups entry initialised empty"
        fi
    else
        info "Port enabled with no groups attached. Use 'port attach ${wwn} <group>' to add groups."
    fi
    local tgt_path; tgt_path=$(scst_target_path "$wwn")
    if [[ -d "$tgt_path" ]]; then
        local idx=0
        while IFS= read -r pwwn; do
            [[ "$pwwn" == "$wwn" ]] && break
            idx=$((idx + 1))
        done < <(get_port_wwns_sorted)
        scst_enable_target "$wwn" "$idx"
        ok "Port ${wwn} enabled"
    else
        warn "SCST target not yet live - port saved to config. Run 'sync --restart' to activate now, or it will take effect at next boot."
    fi
}

cmd_port_disable() {
    local wwn_arg="${1:-}" port_idx="${2:-}"
    local wwn; wwn=$(resolve_port "$wwn_arg" "$port_idx")
    [[ -z "$wwn" ]] && { err "Usage: port disable <wwn>|--port N"; return 1; }
    wwn=$(echo "$wwn" | tr '[:upper:]' '[:lower:]')
    warn "Disabling port ${wwn}"
    cfg_list_remove "enabled_ports" "$wwn"
    py_json "
import json
d = json.load(open('${CONFIG}'))
d.get('port_groups', {}).pop('${wwn}', None)
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
    local tgt_path; tgt_path=$(scst_target_path "$wwn")
    if [[ -d "$tgt_path" ]]; then
        sysfs_write_if_changed "${tgt_path}/enabled" "0"
        ok "Port ${wwn} disabled"
    else
        warn "SCST target not yet live - port removed from config. Run 'sync --restart' to deactivate now, or it will take effect at next boot."
    fi
}

cmd_open() {
    local ext_arg="${1:-}" ext_idx="${2:-}"
    local extent; extent=$(resolve_extent "$ext_arg" "$ext_idx")
    [[ -z "$extent" ]] && { err "Usage: open <extent>|--ext N"; return 1; }
    get_extents_sorted | grep -q "^${extent}$" || { err "Extent '${extent}' not found. Run 'list-extents'"; return 1; }

    info "Opening ${extent} to all initiators"
    cfg_list_add "open_extents" "$extent"

    local lun=0
    while IFS= read -r e; do
        [[ "$e" == "$extent" ]] && break
        lun=$((lun + 1))
    done < <(cfg_get_list "open_extents")

    while IFS= read -r wwn; do
        [[ -z "$wwn" ]] && continue
        local tgt_path; tgt_path=$(scst_target_path "$wwn")
        [[ -d "$tgt_path" ]] || continue
        [[ ! -d "${tgt_path}/luns/${lun}" ]] && \
            sysfs_write "${tgt_path}/luns/mgmt" "add ${extent} ${lun}" || true
    done < <(cfg_get_list "enabled_ports")

    ok "${extent} open to all initiators as LUN ${lun}"
}

cmd_close() {
    local ext_arg="${1:-}" ext_idx="${2:-}"
    local extent; extent=$(resolve_extent "$ext_arg" "$ext_idx")
    [[ -z "$extent" ]] && { err "Usage: close <extent>|--ext N"; return 1; }
    warn "Closing ${extent} from all initiators"
    cfg_list_remove "open_extents" "$extent"

    while IFS= read -r wwn; do
        [[ -z "$wwn" ]] && continue
        local tgt_path; tgt_path=$(scst_target_path "$wwn")
        [[ -d "$tgt_path" ]] || continue
        for lun_path in "${tgt_path}/luns"/*/; do
            [[ -d "$lun_path" ]] || continue
            local dev; dev=$(sysfs_read "${lun_path}/device/name" 2>/dev/null || echo "")
            if [[ "$dev" == "$extent" ]]; then
                local lun; lun=$(basename "$lun_path")
                sysfs_write "${tgt_path}/luns/mgmt" "del ${lun}" || true
                ok "Removed LUN ${lun} (${extent}) from ${wwn}"
            fi
        done
    done < <(cfg_get_list "enabled_ports")
}

cmd_assign() {
    # Retired in schema 3. Delegates to 'group map'.
    local ext_arg="${1:-}" ext_idx="${2:-}" grp_arg="${3:-}" grp_name="${4:-}" lun="${5:-auto}"
    local extent; extent=$(resolve_extent "$ext_arg" "$ext_idx")
    local group; group="${grp_name:-${grp_arg}}"
    [[ -z "$extent" || -z "$group" ]] && { err "Usage: assign <extent>|--ext N <group> [lun]  (use 'group map' in schema 3)"; return 1; }
    cmd_group map "$group" "$extent" "$lun"
}

cmd_unassign() {
    # Retired in schema 3. Delegates to 'group unmap'.
    local ext_arg="${1:-}" ext_idx="${2:-}" grp_arg="${3:-}" grp_name_arg="${4:-}"
    local extent; extent=$(resolve_extent "$ext_arg" "$ext_idx")
    local group; group="${grp_name_arg:-${grp_arg}}"
    [[ -z "$extent" || -z "$group" ]] && { err "Usage: unassign <extent>|--ext N <group>  (use 'group unmap' in schema 3)"; return 1; }
    cmd_group unmap "$group" "$extent"
}

cmd_reset() {
    local subcmd="${1:-}"; shift || true
    [[ -z "$subcmd" ]] && { err "Usage: reset <seen|ports|mappings|names|all>"; return 1; }

    _clear_seen() {
        py_json "
import json
d = json.load(open('${CONFIG}'))
count = len(d.get('seen_initiators', {}))
d['seen_initiators'] = {}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print(count)
"
    }

    _clear_ports() {
        # Disable all enabled ports in sysfs then clear config
        while IFS= read -r wwn; do
            [[ -z "$wwn" ]] && continue
            local tgt_path; tgt_path=$(scst_target_path "$wwn")
            [[ -d "$tgt_path" ]] && sysfs_write_if_changed "${tgt_path}/enabled" "0" || true
            info "Disabled port ${wwn}"
        done < <(cfg_get_list "enabled_ports")
        py_json "
import json
d = json.load(open('${CONFIG}'))
count = len(d.get('enabled_ports', []))
d['enabled_ports'] = []
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print(count)
"
    }

    _clear_mappings() {
        # Remove all LUNs from sysfs ini_groups and default luns group
        while IFS= read -r wwn; do
            [[ -z "$wwn" ]] && continue
            local tgt_path; tgt_path=$(scst_target_path "$wwn")
            [[ -d "$tgt_path" ]] || continue
            # Clear default luns group
            for lun_path in "${tgt_path}/luns"/*/; do
                [[ -d "$lun_path" ]] || continue
                local lun; lun=$(basename "$lun_path")
                [[ "$lun" == "mgmt" ]] && continue
                sysfs_write "${tgt_path}/luns/mgmt" "del ${lun}" || true
            done
            # Remove all ini_groups
            for grp_path in "${tgt_path}/ini_groups"/*/; do
                [[ -d "$grp_path" ]] || continue
                local grp; grp=$(basename "$grp_path")
                [[ "$grp" == "mgmt" ]] && continue
                sysfs_write "${tgt_path}/ini_groups/mgmt" "del ${grp}" || true
            done
        done < <(cfg_get_list "enabled_ports")
        py_json "
import json
d = json.load(open('${CONFIG}'))
oe = len(d.get('open_extents', []))
ai = len(d.get('groups', {}))
pi = sum(len(v) for v in d.get('port_groups', {}).values())
d['open_extents'] = []
d['groups'] = {}
for p in d.get('port_groups', {}):
    d['port_groups'][p] = []
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print(f'{oe} open extents, {ai} groups, {pi} port associations')
"
    }

    _clear_names() {
        py_json "
import json
d = json.load(open('${CONFIG}'))
count = len(d.get('wwn_names', {}))
d['wwn_names'] = {}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print(count)
"
    }

    case "$subcmd" in
        seen)
            local n; n=$(_clear_seen)
            ok "Cleared seen initiators (${n} removed)"
            ;;
        ports)
            local n; n=$(_clear_ports)
            ok "Cleared enabled ports (${n} removed)"
            ;;
        mappings)
            local detail; detail=$(_clear_mappings)
            ok "Cleared mappings (${detail} removed)"
            ;;
        names)
            local n; n=$(_clear_names)
            ok "Cleared WWN names (${n} removed)"
            ;;
        all)
            warn "Clearing all operational state (seen, ports, mappings, names)"
            [[ $YES -eq 0 ]] && {
                echo -e "${YLW}Proceed? [y/N]${NC} \c"
                read -r answer || true
                [[ "$answer" != "y" && "$answer" != "Y" ]] && { info "Aborted"; return 0; }
            }
            _clear_ports    >/dev/null
            _clear_mappings >/dev/null
            _clear_seen     >/dev/null
            _clear_names    >/dev/null
            ok "All operational state cleared"
            ok "ISP params, firmware store, and active profiles preserved"
            ;;
        *) err "Unknown reset target: ${subcmd}  (seen|ports|mappings|names|all)" ;;
    esac
}

cmd_stats() {
    local watch_mode=0 wide_mode=0
    for arg in "${@}"; do
        [[ "$arg" == "--watch" ]] && watch_mode=1
        [[ "$arg" == "--wide" ]]  && wide_mode=1
    done

    _show_stats_wide() {
        hdr "qle_adm Stats  $(date '+%Y-%m-%d %H:%M:%S')"
        printf "\n${WHT}%-25s %-8s %-10s %-8s  %-12s %-12s %-8s %-8s %-8s${NC}\n" \
            "WWN" "ISP" "State" "Speed" "TX Frames" "RX Frames" "LnkFail" "LossSig" "BadCRC"
        detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
            local stats_path="/sys/class/fc_host/${host}/statistics"
            local tx=0 rx=0 lf=0 ls=0 crc=0 speed
            speed=$(sysfs_read "/sys/class/fc_host/${host}/speed" 2>/dev/null | grep -oP '[0-9]+' | head -1 || echo "?")
            if [[ -d "$stats_path" ]]; then
                tx=$(hex_to_dec  "$(sysfs_read "${stats_path}/tx_frames")")
                rx=$(hex_to_dec  "$(sysfs_read "${stats_path}/rx_frames")")
                lf=$(hex_to_dec  "$(sysfs_read "${stats_path}/link_failure_count")")
                ls=$(hex_to_dec  "$(sysfs_read "${stats_path}/loss_of_signal_count")")
                crc=$(hex_to_dec "$(sysfs_read "${stats_path}/invalid_crc_count")")
            fi
            local state_col="$RED"; [[ "$state" == "Online" ]] && state_col="$GRN"
            local err_col="$NC"; [[ $lf -gt 0 || $ls -gt 0 ]] && err_col="$RED"
            printf "${state_col}%-25s${NC} %-8s ${state_col}%-10s${NC} %-8s  %-12s %-12s ${err_col}%-8s %-8s %-8s${NC}\n" \
                "$wwn" "$isp" "$state" "${speed}G" "$tx" "$rx" "$lf" "$ls" "$crc"
            local i=0
            for sess_path in "/sys/kernel/scst_tgt/targets/qla2x00t/${wwn}/sessions"/*/; do
                [[ -d "$sess_path" ]] || continue
                local init_wwn ac rc wc rk wk _ilbl
                init_wwn=$(basename "$sess_path")
                _ilbl=$(wwn_label "$init_wwn" "initiator")
                ac=$(hex_to_dec "$(sysfs_read "${sess_path}/active_commands")")
                rc=$(hex_to_dec "$(sysfs_read "${sess_path}/read_cmd_count")")
                wc=$(hex_to_dec "$(sysfs_read "${sess_path}/write_cmd_count")")
                rk=$(hex_to_dec "$(sysfs_read "${sess_path}/read_io_count_kb")")
                wk=$(hex_to_dec "$(sysfs_read "${sess_path}/write_io_count_kb")")
                printf "  ${GRN}[%d]${NC} %-23s ${CYN}(%-10s)${NC}  act:%-4s R:%-10s W:%-10s IO: R:%-8s W:%-8s\n" \
                    "$i" "$init_wwn" "$_ilbl" "${ac}" "${rc}cmd" "${wc}cmd" "${rk}KB" "${wk}KB"
                i=$((i + 1))
            done
        done
        divider
    }

    _show_stats_detail() {
        clear
        hdr "qle_adm Stats  $(date '+%Y-%m-%d %H:%M:%S')"
        detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
            local state_col="$RED"; [[ "$state" == "Online" ]] && state_col="$GRN"
            local ptype_short; ptype_short=$(echo "$ptype" | sed 's/Point-To-Point (direct nport connection)/P2P/')
            echo -e "\n[${idx}] ${WHT}${wwn}${NC}  ${isp}  ${state_col}${state}${NC}  ${ptype_short}"
            local stats_path="/sys/class/fc_host/${host}/statistics"
            if [[ -d "$stats_path" ]]; then
                local tx rx lf ls crc
                tx=$(hex_to_dec  "$(sysfs_read "${stats_path}/tx_frames")")
                rx=$(hex_to_dec  "$(sysfs_read "${stats_path}/rx_frames")")
                lf=$(hex_to_dec  "$(sysfs_read "${stats_path}/link_failure_count")")
                ls=$(hex_to_dec  "$(sysfs_read "${stats_path}/loss_of_signal_count")")
                crc=$(hex_to_dec "$(sysfs_read "${stats_path}/invalid_crc_count")")
                printf "  %-18s %d\n" "TX Frames:"    "$tx"
                printf "  %-18s %d\n" "RX Frames:"    "$rx"
                local err_col="$GRN"; [[ $lf -gt 0 || $ls -gt 0 ]] && err_col="$RED"
                printf "  ${err_col}%-18s %d${NC}\n" "Link Failures:"  "$lf"
                printf "  ${err_col}%-18s %d${NC}\n" "Loss of Signal:" "$ls"
                printf "  ${err_col}%-18s %d${NC}\n" "Invalid CRC:"    "$crc"
            fi
            local si=0
            for sess_path in "/sys/kernel/scst_tgt/targets/qla2x00t/${wwn}/sessions"/*/; do
                [[ -d "$sess_path" ]] || continue
                local init_wwn ac cmds rc wc rk wk
                init_wwn=$(basename "$sess_path")
                ac=$(hex_to_dec   "$(sysfs_read "${sess_path}/active_commands")")
                cmds=$(hex_to_dec "$(sysfs_read "${sess_path}/commands")")
                rc=$(hex_to_dec   "$(sysfs_read "${sess_path}/read_cmd_count")")
                wc=$(hex_to_dec   "$(sysfs_read "${sess_path}/write_cmd_count")")
                rk=$(hex_to_dec   "$(sysfs_read "${sess_path}/read_io_count_kb")")
                wk=$(hex_to_dec   "$(sysfs_read "${sess_path}/write_io_count_kb")")
                local _slbl; _slbl=$(wwn_label "$init_wwn" "initiator")
                echo -e "\n  ${GRN}[${si}] Session:${NC} ${init_wwn} (${CYN}${_slbl}${NC})"
                printf "    %-20s %d\n" "Active Commands:"  "$ac"
                printf "    %-20s %d\n" "Total Commands:"   "$cmds"
                printf "    %-20s %d cmds  /  %d KB\n" "Read:"  "$rc" "$rk"
                printf "    %-20s %d cmds  /  %d KB\n" "Write:" "$wc" "$wk"
                si=$((si + 1))
            done
        done
        [[ $watch_mode -eq 1 ]] && echo -e "\n${DIM}Refreshing every ${WATCH_INTERVAL}s - Ctrl+C to stop${NC}"
        divider
    }

    if [[ $wide_mode -eq 1 ]]; then
        _show_stats_wide
    elif [[ $watch_mode -eq 1 ]]; then
        while true; do _show_stats_detail; sleep "$WATCH_INTERVAL"; done
    else
        _show_stats_detail
    fi
}

cmd_fw() {
    local subcmd="${1:-list}"; shift || true
    case "$subcmd" in
        list)
            hdr "Firmware Store"
            local any=0
            for isp_dir in "${FIRMWARE_DIR}"/*/; do
                [[ -d "$isp_dir" ]] || continue
                local isp; isp=$(basename "$isp_dir")
                local fw_file="${ISP_FW_FILE[$isp]:-}"
                [[ -z "$fw_file" ]] && continue
                local selected; selected=$(fw_selected "$isp")
                echo -e "\n  ${WHT}${isp}${NC}  ${fw_file}  selected: ${CYN}${selected}${NC}"
                # Version subdirectories
                local found_ver=0
                for vdir in "${isp_dir}"/*/; do
                    [[ -d "$vdir" ]] || continue
                    local ver; ver=$(basename "$vdir")
                    local vfile="${vdir}${fw_file}"
                    [[ ! -f "$vfile" ]] && continue
                    local sz; sz=$(du -h "$vfile" 2>/dev/null | awk '{print $1}')
                    local marker; marker=$(find "$vdir" -maxdepth 1 -name "os_*" -printf "%f\n" 2>/dev/null | head -1)
                    local flags=""
                    [[ -n "$marker" ]] && flags+=" ${DIM}${marker}${NC}"
                    [[ "$selected" == "$ver" ]] && flags+=" ${GRN}[selected]${NC}"
                    echo -e "    ${ver}  ${sz}${flags}"
                    found_ver=$((found_ver + 1))
                done
                [[ $found_ver -eq 0 ]] && echo -e "    ${DIM}(no versions stored)${NC}"
                echo -e "    ${DIM}hba   use HBA flash firmware (ql2xfwloadbin=0)${NC}"
                echo -e "    ${DIM}dist  use dist-marked version (default if stored)${NC}"
                any=$((any + 1))
            done
            [[ $any -eq 0 ]] && echo -e "  ${DIM}(no firmware stored - run 'fw save-hba' or 'fw save-os')${NC}"
            divider
            ;;
        save-os)
            # Capture the OS distribution firmware from /usr/lib/firmware
            local port_idx=""
            [[ "${1:-}" == "--port" ]] && { port_idx="${2:-}"; shift 2 || true; }
            hdr "Save OS Distribution Firmware"
            local isp_type
            read -r _ _ _ isp_type _ <<< "$(detect_hbas | { [[ -n "$port_idx" ]] && sed -n "$((port_idx+1))p" || head -1; })"
            local fw_file="${ISP_FW_FILE[$isp_type]:-}"
            [[ -z "$fw_file" ]] && { err "Unknown ISP type: ${isp_type}"; return 1; }
            local src="/usr/lib/firmware/${fw_file}"
            [[ ! -f "$src" ]] && { err "OS firmware not found: ${src}"; return 1; }
            local ver; ver=$(fw_extract_version "$src")
            # Get TrueNAS version for marker
            local tn_ver; tn_ver=$(midclt call system.version 2>/dev/null | tr -d '"' || echo "unknown")
            local marker="os_${tn_ver}"
            info "Saving OS firmware ${isp_type} v${ver} from ${src}"
            info "TrueNAS version: ${tn_ver}"
            local stored_ver; fw_store_versioned "$isp_type" "$src" "$ver" "os"; stored_ver="$_FW_STORED_VER"
            if [[ $DRY_RUN -eq 0 && -d "${FIRMWARE_DIR}/${isp_type}/${stored_ver}" ]]; then
                # Place marker only if not already present
                local existing_marker; existing_marker=$(find "${FIRMWARE_DIR}/${isp_type}/${stored_ver}/" -maxdepth 1 -name "os_*" 2>/dev/null | head -1)
                if [[ -z "$existing_marker" ]]; then
                    touch "${FIRMWARE_DIR}/${isp_type}/${stored_ver}/${marker}"
                    ok "Marker: ${FIRMWARE_DIR}/${isp_type}/${stored_ver}/${marker}"
                fi
            fi
            divider
            ;;
        save-hba)
            # Read firmware from HBA optrom via sysfs
            local port_idx=""
            [[ "${1:-}" == "--port" ]] && { port_idx="${2:-}"; shift 2 || true; }
            hdr "Save HBA Optrom Firmware"
            local host isp_type
            read -r _ host _ isp_type _ <<< "$(detect_hbas | { [[ -n "$port_idx" ]] && sed -n "$((port_idx+1))p" || head -1; })"
            local fw_file="${ISP_FW_FILE[$isp_type]:-}"
            [[ -z "$fw_file" ]] && { err "Unknown ISP type: ${isp_type}"; return 1; }
            local optrom_path="/sys/class/scsi_host/${host}/device/optrom"
            local optrom_ctl="/sys/class/scsi_host/${host}/device/optrom_ctl"
            [[ ! -f "$optrom_ctl" ]] && { err "optrom_ctl sysfs not found: ${optrom_ctl}"; return 1; }
            info "Reading optrom from ${host} (${isp_type})..."
            local tmp; tmp=$(mktemp)
            if [[ $DRY_RUN -eq 0 ]]; then
                echo 1 > "$optrom_ctl" 2>/dev/null || { err "Failed to enable optrom read mode"; rm -f "$tmp"; return 1; }
                sleep 1
                dd if="$optrom_path" of="$tmp" bs=4096 2>/dev/null
                echo 0 > "$optrom_ctl" 2>/dev/null || true
                local sz; sz=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
                [[ "$sz" -eq 0 ]] && { err "Optrom read returned empty - driver may not support optrom extraction"; rm -f "$tmp"; return 1; }
                local ver; ver=$(fw_extract_version "$tmp")
                fw_store_versioned "$isp_type" "$tmp" "$ver" "hba"
                rm -f "$tmp"
            else
                info "[DRY-RUN] echo 1 > ${optrom_ctl} && dd ${optrom_path} -> versioned store && echo 0 > ${optrom_ctl}"
                rm -f "$tmp"
            fi
            divider
            ;;
        add)
            local isp_type="${1:-}" fw_path="${2:-}"
            [[ -z "$isp_type" || -z "$fw_path" ]] && { err "Usage: fw add <ISP_TYPE> <file>"; return 1; }
            [[ ! -f "$fw_path" ]] && { err "File not found: ${fw_path}"; return 1; }
            local fw_file="${ISP_FW_FILE[$isp_type]:-}"
            [[ -z "$fw_file" ]] && { err "Unknown ISP type: ${isp_type}. Known: ${!ISP_FW_FILE[*]}"; return 1; }
            local ver; ver=$(fw_extract_version "$fw_path")
            info "Adding ${isp_type} firmware v${ver}"
            fw_store_versioned "$isp_type" "$fw_path" "$ver" "imported"
            ;;
        remove)
            local isp_type="${1:-}" ver="${2:-}"
            [[ -z "$isp_type" || -z "$ver" ]] && { err "Usage: fw remove <ISP_TYPE> <version>"; return 1; }
            local dest_dir="${FIRMWARE_DIR}/${isp_type}/${ver}"
            [[ ! -d "$dest_dir" ]] && { err "Version not found: ${dest_dir}"; return 1; }
            local selected; selected=$(fw_selected "$isp_type")
            [[ "$selected" == "$ver" ]] && { err "Cannot remove currently selected version '${ver}' - run 'fw use hba' first"; return 1; }
            local marker; marker=$(find "$dest_dir" -maxdepth 1 -name "os_*" -printf "%f\n" 2>/dev/null | head -1)
            [[ -n "$marker" ]] && warn "Removing dist-marked version (${marker})"
            warn "Will remove ${dest_dir}"
            confirm_or_abort "Remove firmware version ${ver} for ${isp_type}?"
            if [[ $DRY_RUN -eq 0 ]]; then
                rm -rf "$dest_dir"
                ok "Removed ${isp_type} v${ver}"
            else
                info "[DRY-RUN] rm -rf ${dest_dir}"
            fi
            ;;
        use)
            local ver="${1:-}" port_idx=""
            [[ "${2:-}" == "--port" ]] && { port_idx="${3:-}"; shift 2 || true; }
            [[ -z "$ver" ]] && { err "Usage: fw use <version|hba|dist> [--port N]"; return 1; }
            local isp_type
            read -r _ _ _ isp_type _ <<< "$(detect_hbas | { [[ -n "$port_idx" ]] && sed -n "$((port_idx+1))p" || head -1; })"
            [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && { err "Could not detect ISP type"; return 1; }
            # Validate non-keyword versions exist
            if [[ "$ver" != "hba" && "$ver" != "dist" ]]; then
                local dest_dir="${FIRMWARE_DIR}/${isp_type}/${ver}"
                [[ ! -d "$dest_dir" ]] && { err "Version '${ver}' not found for ${isp_type} - run 'fw list'"; return 1; }
            fi
            if [[ $DRY_RUN -eq 0 ]]; then
                fw_set_selected "$isp_type" "$ver"
                ok "Selected firmware for ${isp_type}: ${ver}"
                info "Takes effect on next boot or 'sync --boot'"
            else
                info "[DRY-RUN] would set firmware.${isp_type}.selected=${ver} in config.json"
            fi
            ;;
        show)
            local port_idx=""
            [[ "${1:-}" == "--port" ]] && { port_idx="${2:-}"; shift 2 || true; }
            hdr "Firmware Details"
            detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
                [[ -n "$port_idx" && "$idx" != "$port_idx" ]] && continue
                local scsi_host="/sys/class/scsi_host/${host}"
                local optrom_ver; optrom_ver=$(cat "${scsi_host}/optrom_fw_version" 2>/dev/null | awk '{print $1}' || echo "n/a")
                local primary_ver; primary_ver=$(cat "${scsi_host}/optrom_gold_fw_version" 2>/dev/null | awk '{print $1}' || echo "not exposed")
                local lbl; lbl=$(wwn_label "$wwn" "target")
                local selected; selected=$(fw_selected "$isp")
                local fwbin_val; fwbin_val=$(cat /sys/module/qla2xxx_scst/parameters/ql2xfwloadbin 2>/dev/null || \
                    cat /sys/module/qla2xxx/parameters/ql2xfwloadbin 2>/dev/null || echo "?")
                local fwbin_label
                case "$fwbin_val" in
                    0) fwbin_label="HBA flash" ;;
                    1) fwbin_label="optrom" ;;
                    2) fwbin_label="filesystem (/usr/lib/firmware)" ;;
                    *) fwbin_label="unknown" ;;
                esac
                echo -e "\n  ${WHT}[${idx}] ${host}${NC} - ${isp}  ${wwn} (${CYN}${lbl}${NC})"
                echo -e "    Running  : ${fw}"
                echo -e "    Primary  : ${primary_ver}"
                echo -e "    Optrom   : ${optrom_ver}"
                echo -e "    Selected : ${selected}"
                echo -e "    Load src : ql2xfwloadbin=${fwbin_val} (${fwbin_label})"
                echo -e "    Stored versions:"
                local fw_file="${ISP_FW_FILE[$isp]:-}"
                for vdir in "${FIRMWARE_DIR}/${isp}/"/*/; do
                    [[ -d "$vdir" ]] || continue
                    local ver; ver=$(basename "$vdir")
                    local vfile="${vdir}${fw_file}"
                    [[ ! -f "$vfile" ]] && continue
                    local vver; vver=$(fw_extract_version "$vfile")
                    local marker; marker=$(find "$vdir" -maxdepth 1 -name "os_*" -printf "%f\n" 2>/dev/null | head -1)
                    local flags=""
                    [[ -n "$marker" ]] && flags+=" ${DIM}(${marker})${NC}"
                    [[ "$selected" == "$ver" ]] && flags+=" ${GRN}[selected]${NC}"
                    echo -e "      ${ver}  v${vver}${flags}"
                done
            done
            divider
            ;;
        status)
            hdr "Firmware Status"
            detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
                local scsi_host="/sys/class/scsi_host/${host}"
                local optrom_ver; optrom_ver=$(cat "${scsi_host}/optrom_fw_version" 2>/dev/null | awk '{print $1}' || echo "n/a")
                local lbl; lbl=$(wwn_label "$wwn" "target")
                local selected; selected=$(fw_selected "$isp")
                local fw_file="${ISP_FW_FILE[$isp]:-}"
                local stored_count; stored_count=$(find "${FIRMWARE_DIR}/${isp}/" -name "$fw_file" 2>/dev/null | wc -l || echo 0)
                local sync_ind
                # Check if running version matches selected stored version
                local sel_ver=""
                if [[ "$selected" != "hba" && "$selected" != "dist" ]]; then
                    local sel_file="${FIRMWARE_DIR}/${isp}/${selected}/${fw_file}"
                    [[ -f "$sel_file" ]] && sel_ver=$(fw_extract_version "$sel_file")
                fi
                if [[ "$selected" == "hba" ]]; then
                    sync_ind="${DIM}-${NC}"
                elif [[ -n "$sel_ver" && "$sel_ver" == "$fw" ]]; then
                    sync_ind="${GRN}${SYM_OK}${NC}"
                else
                    sync_ind="${YLW}${SYM_WARN}${NC}"
                fi
                echo -e "  ${sync_ind} ${host}  ${isp}  ${wwn} (${CYN}${lbl}${NC})  running=${fw}  optrom=${optrom_ver}  selected=${selected}  stored=${stored_count} version(s)"
            done
            divider
            ;;
        *) err "Unknown fw subcommand: ${subcmd}"
           err "Usage: fw list | save-os | save-hba | add | remove | use | show | status"
           return 1 ;;
    esac
}
cmd_lun() {
    local subcmd="${1:-}"; shift || true
    [[ -z "$subcmd" ]] && { err "Usage: lun <set|clear-pending|status> ..."; return 1; }

    # _lun_merged_map <wwn>
    # Returns the merged desired LUN map for an initiator:
    # current luns from config.json overlaid with pending_luns.
    # Prints "lun:extent" pairs one per line.
    _lun_merged_map() {
        local wwn="$1"
        py_json "
import json
d = json.load(open('${CONFIG}'))
a = d.get('groups', {}).get('${wwn}', {})
luns = dict(a.get('luns', {}))
pending = dict(a.get('pending_luns', {}))
merged = {}
for ext, n in luns.items():
    merged[ext] = pending.get(ext, n)
for ext, n in pending.items():
    if ext not in merged:
        merged[ext] = n
for ext, n in sorted(merged.items(), key=lambda x: x[1]):
    print(f'{n}:{ext}')
"
    }

    # _lun_merged_valid <wwn>
    # Returns 'ok' if the merged map is unique (no duplicate LUN numbers).
    # Returns 'conflict:<lun>:<ext1>:<ext2>' for the first conflict found.
    _lun_merged_valid() {
        local wwn="$1"
        py_json "
import json
d = json.load(open('${CONFIG}'))
a = d.get('groups', {}).get('${wwn}', {})
luns = dict(a.get('luns', {}))
pending = dict(a.get('pending_luns', {}))
merged = {}
for ext, n in luns.items():
    merged[ext] = pending.get(ext, n)
for ext, n in pending.items():
    if ext not in merged:
        merged[ext] = n
seen = {}
for ext, n in merged.items():
    if n in seen:
        print(f'conflict:{n}:{seen[n]}:{ext}')
        exit()
    seen[n] = ext
print('ok')
"
    }

    # _lun_show_pending <wwn>
    # Prints the current pending state and merged map for an initiator.
    _lun_show_pending() {
        local wwn="$1"
        local lbl; lbl=$(wwn_label "$wwn" "initiator")
        local pending
        pending=$(py_json "
import json
d = json.load(open('${CONFIG}'))
p = d.get('groups', {}).get('${wwn}', {}).get('pending_luns', {})
for ext, n in sorted(p.items(), key=lambda x: x[1]):
    cur = d.get('groups', {}).get('${wwn}', {}).get('luns', {}).get(ext, '?')
    print(f'{ext} {cur} {n}')
")
        if [[ -z "$pending" ]]; then
            echo -e "  ${DIM}No pending LUN changes for ${wwn} (${lbl})${NC}"
            return
        fi
        echo -e "\n  ${CYN}Pending LUN changes for ${WHT}${wwn}${CYN} (${lbl}):${NC}"
        while IFS=' ' read -r ext cur new; do
            echo -e "    ${WHT}${ext}:${NC}  LUN ${cur} -> LUN ${new}"
        done <<< "$pending"
        echo -e "\n  ${CYN}Merged desired state:${NC}"
        while IFS=: read -r n ext; do
            local cur_lun; cur_lun=$(py_json "
import json
d = json.load(open('${CONFIG}'))
print(d.get('groups',{}).get('${wwn}',{}).get('luns',{}).get('${ext}','?'))
")
            local tag=""
            [[ "$cur_lun" != "$n" ]] && tag="  ${YLW}(pending from LUN ${cur_lun})${NC}"
            echo -e "    LUN ${n}: ${ext}${tag}"
        done < <(_lun_merged_map "$wwn")
        local valid; valid=$(_lun_merged_valid "$wwn")
        if [[ "$valid" == "ok" ]]; then
            echo -e "\n  ${GRN}State: READY${NC} - no conflicts. Apply with 'sync --restart' or reboot."
        else
            local clun cext1 cext2
            IFS=: read -r _ clun cext1 cext2 <<< "$valid"
            echo -e "\n  ${YLW}State: NOT READY${NC} - conflict at LUN ${clun}: both '${cext1}' and '${cext2}' pending."
            echo -e "  Use 'lun set' to resolve before applying."
        fi
    }

    case "$subcmd" in

        set)
            # lun set <extent> <group> <new-lun>
            local ext="${1:-}" wwn="${2:-}" new_lun="${3:-}"
            [[ -z "$ext" || -z "$wwn" || -z "$new_lun" ]] && {
                err "Usage: lun set <extent> <group> <new-lun>"
                return 1
            }
            [[ "$new_lun" =~ ^[0-9]+$ ]] || { err "LUN must be a non-negative integer"; return 1; }

            # Verify extent is assigned to this initiator
            local assigned
            assigned=$(py_json "
import json
d = json.load(open('${CONFIG}'))
exts = list(d.get('groups', {}).get('${wwn}', {}).get('luns', {}).keys())
print('yes' if '${ext}' in exts else 'no')
")
            [[ "$assigned" == "yes" ]] || {
                err "Extent '${ext}' is not assigned to ${wwn}"
                err "Use 'list-mapping' to see current group and port assignments"
                return 1
            }

            # Get current live LUN for this extent
            local cur_lun
            cur_lun=$(py_json "
import json
d = json.load(open('${CONFIG}'))
print(d.get('groups', {}).get('${wwn}', {}).get('luns', {}).get('${ext}', '?'))
")

            if [[ "$new_lun" == "$cur_lun" ]]; then
                # Cancels any pending change for this extent
                py_json "
import json
d = json.load(open('${CONFIG}'))
p = d.get('groups', {}).get('${wwn}', {}).get('pending_luns', {})
if '${ext}' in p:
    del p['${ext}']
    d['groups']['${wwn}']['pending_luns'] = p
    json.dump(d, open('${CONFIG}', 'w'), indent=2)
    print('cancelled')
else:
    print('noop')
" | grep -q "cancelled" \
                    && ok "Pending change for '${ext}' cancelled - already at LUN ${cur_lun}" \
                    || info "'${ext}' is already at LUN ${cur_lun} - no change"
            else
                # Write to pending_luns (no validation - validated at apply time)
                py_json "
import json
d = json.load(open('${CONFIG}'))
if 'pending_luns' not in d['groups']['${wwn}']:
    d['groups']['${wwn}']['pending_luns'] = {}
d['groups']['${wwn}']['pending_luns']['${ext}'] = int('${new_lun}')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
                ok "Pending: '${ext}' LUN ${cur_lun} -> LUN ${new_lun} for ${wwn}"
                log "lun set: ${ext} LUN ${cur_lun} -> ${new_lun} for ${wwn} [pending]"
            fi
            echo ""
            _lun_show_pending "$wwn"
            ;;

        clear-pending)
            # lun clear-pending <group> | --all
            local target="${1:-}"
            [[ -z "$target" ]] && { err "Usage: lun clear-pending <wwn>|--all"; return 1; }
            if [[ "$target" == "--all" ]]; then
                local count
                count=$(py_json "
import json
d = json.load(open('${CONFIG}'))
total = 0
for wwn, data in d.get('groups', {}).items():
    total += len(data.get('pending_luns', {}))
    data['pending_luns'] = {}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print(total)
")
                ok "All pending LUN changes cleared (${count} entries removed)"
                log "lun clear-pending --all: ${count} entries cleared"
            else
                local count
                count=$(py_json "
import json
d = json.load(open('${CONFIG}'))
p = d.get('groups', {}).get('${target}', {}).get('pending_luns', {})
count = len(p)
if '${target}' in d.get('groups', {}):
    d['groups']['${target}']['pending_luns'] = {}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print(count)
")
                ok "Pending LUN changes cleared for ${target} (${count} entries removed)"
                log "lun clear-pending ${target}: ${count} entries cleared"
            fi
            ;;

        status)
            # lun status [<group>]
            local target="${1:-}"
            hdr "LUN Pending Changes"
            if [[ -n "$target" ]]; then
                _lun_show_pending "$target"
            else
                # Show all initiators that have pending changes
                local wwns
                wwns=$(py_json "
import json
d = json.load(open('${CONFIG}'))
for wwn, data in d.get('groups', {}).items():
    if data.get('pending_luns'):
        print(wwn)
")
                if [[ -z "$wwns" ]]; then
                    echo -e "  ${DIM}No pending LUN changes${NC}"
                else
                    while IFS= read -r wwn; do
                        _lun_show_pending "$wwn"
                        echo ""
                    done <<< "$wwns"
                fi
            fi
            divider
            ;;

        *)
            err "Unknown lun subcommand: ${subcmd}"
            err "Usage: lun <set|clear-pending|status>"
            err "  lun set <extent> <group> <new-lun>"
            err "  lun clear-pending <group>|--all"
            err "  lun status [<group>]"
            return 1
            ;;
    esac
}

cmd_isp_params() {
    local subcmd="${1:-list}"; shift || true
    case "$subcmd" in
        list)
            hdr "ISP Module Parameters"
            local loaded_isp; loaded_isp=$(get_isp_type_dominant 2>/dev/null || echo "")
            local applied; applied=$(get_applied_params)
            local configured; configured=$(get_module_params "$loaded_isp" 2>/dev/null || echo "")
            local active_profile; active_profile=$(py_json "
import json
d = json.load(open('${CONFIG}'))
print(d.get('isp_active_profile', {}).get('${loaded_isp}', 'default'))
")
            py_json "
import json
d = json.load(open('${CONFIG}'))
active_profiles = d.get('isp_active_profile', {})
loaded = '${loaded_isp}'
applied = '${applied}'
configured = '${configured}'
active_profile = '${active_profile}'
for isp, entry in d.get('isp_params', {}).items():
    active = active_profiles.get(isp, 'default')
    detected = ' (detected)' if isp == loaded else ''
    print(f'  {isp}{detected}:')
    for profile, params in entry.items():
        marker = ' *' if profile == active else ''
        print(f'    {profile}{marker}: {params}')
    if isp == loaded:
        default_params = entry.get('default', '')
        print(f'    ──')
        # Configured line: profile name if default, name+params if non-default
        if active_profile == 'default':
            print(f'    Configured : default')
        else:
            print(f'    Configured : {active_profile}  →  {configured}')
        # Applied line: match to profile name if possible, else show params
        if not applied:
            print(f'    Applied    : (module not loaded)')
        else:
            # Find which profile matches applied params
            matched = next((p for p,v in entry.items() if v.strip() == applied.strip()), None)
            if matched:
                drift = '' if matched == active_profile else '  ⚠ drift'
                print(f'    Applied    : {matched}{drift}')
            else:
                print(f'    Applied    : {applied}  ⚠ drift')
"
            divider
            ;;
        set)
            # isp-params set <ISP> [--profile <name>] <params>|default
            local isp_type="${1:-}"; shift || true
            local profile="default"
            [[ "${1:-}" == "--profile" ]] && { profile="${2:-default}"; shift 2 || true; }
            local params="${*}"
            [[ -z "$isp_type" || -z "$params" ]] && {
                err "Usage: isp-params set <ISP_TYPE> [--profile <name>] '<params>'"
                err "       Use 'default' as params to restore the built-in default for that ISP type."
                return 1
            }
            # If the user passes the literal word "default" as params, restore the
            # built-in param string for that ISP type rather than storing the word.
            if [[ "$params" == "default" ]]; then
                params=$(py_json "
import json
DEFAULTS = {
    'ISP2432': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
    'ISP2532': 'qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
    'ISP2322': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
    'DEFAULT': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=0',
}
print(DEFAULTS.get('${isp_type}', DEFAULTS['DEFAULT']))
")
                info "Restoring built-in default params for ${isp_type}: ${params}"
            fi
            py_json "
import json
d = json.load(open('${CONFIG}'))
entry = d.setdefault('isp_params', {}).setdefault('${isp_type}', {})
entry['${profile}'] = '${params}'
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Set ${isp_type} profile '${profile}': ${params}"
            ;;
        use)
            # isp-params use <ISP> --profile <name>
            local isp_type="${1:-}"; shift || true
            local profile="default"
            [[ "${1:-}" == "--profile" ]] && { profile="${2:-default}"; shift 2 || true; }
            [[ -z "$isp_type" ]] && { err "Usage: isp-params use <ISP_TYPE> --profile <name>"; return 1; }
            py_json "
import json
d = json.load(open('${CONFIG}'))
# Verify profile exists
entry = d.get('isp_params', {}).get('${isp_type}', {})
if isinstance(entry, str):
    entry = {'default': entry}
if '${profile}' not in entry:
    print('ERROR: profile not found')
else:
    d.setdefault('isp_active_profile', {})['${isp_type}'] = '${profile}'
    json.dump(d, open('${CONFIG}', 'w'), indent=2)
    print('OK')
" | grep -q "ERROR" && { err "Profile '${profile}' not found for ${isp_type}"; return 1; }
            ok "Active profile for ${isp_type} set to '${profile}'"
            ;;
        del)
            # isp-params del <ISP> [--profile <name>]
            local isp_type="${1:-}"; shift || true
            local profile=""
            [[ "${1:-}" == "--profile" ]] && { profile="${2:-}"; shift 2 || true; }
            [[ -z "$isp_type" ]] && { err "Usage: isp-params del <ISP_TYPE> [--profile <name>]"; return 1; }
            if [[ -z "$profile" ]]; then
                # Remove entire ISP entry
                py_json "
import json
d = json.load(open('${CONFIG}'))
d.get('isp_params', {}).pop('${isp_type}', None)
d.get('isp_active_profile', {}).pop('${isp_type}', None)
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
                ok "Removed all params for ${isp_type}"
            else
                [[ "$profile" == "default" ]] && { err "Cannot delete the 'default' profile"; return 1; }
                py_json "
import json
d = json.load(open('${CONFIG}'))
entry = d.get('isp_params', {}).get('${isp_type}', {})
if '${profile}' in entry:
    del entry['${profile}']
    d['isp_params']['${isp_type}'] = entry
    if d.get('isp_active_profile', {}).get('${isp_type}') == '${profile}':
        d['isp_active_profile']['${isp_type}'] = 'default'
    json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
                ok "Deleted profile '${profile}' from ${isp_type}"
            fi
            ;;
        *) err "Unknown subcommand: ${subcmd}" ;;
    esac
}

# ─── Group management ─────────────────────────────────────────────────────────
cmd_group() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in

        create)
            local name="${1:-}"
            [[ -z "$name" ]] && { err "Usage: group create <name>"; return 1; }
            local exists
            exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${name}' in d.get('groups', {}) else 'no')
except: pass
")
            [[ "$exists" == "yes" ]] && { err "Group '${name}' already exists"; return 1; }
            py_json "
import json
d = json.load(open('${CONFIG}'))
d.setdefault('groups', {})['${name}'] = {'initiators': [], 'luns': {}, 'pending_luns': {}}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Group '${name}' created. Use 'group add', 'group map', and 'port attach' to configure it."
            ;;

        delete)
            local name="${1:-}"
            [[ -z "$name" ]] && { err "Usage: group delete <name>"; return 1; }
            local exists
            exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${name}' in d.get('groups', {}) else 'no')
except: pass
")
            [[ "$exists" != "yes" ]] && { err "Group '${name}' not found"; return 1; }
            warn "Deleting group '${name}', its LUN mappings, and all port associations"
            confirm_or_abort "Proceed?"
            py_json "
import json
d = json.load(open('${CONFIG}'))
d.get('groups', {}).pop('${name}', None)
for pg in d.get('port_groups', {}).values():
    if '${name}' in pg:
        pg.remove('${name}')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Group '${name}' deleted. Run 'sync' to update scst.conf."
            ;;

        add)
            local name="${1:-}" wwn="${2:-}"
            [[ -z "$name" || -z "$wwn" ]] && { err "Usage: group add <name> <wwn>"; return 1; }
            if [[ ! "$wwn" =~ ^([0-9a-fA-F]{2}:){7}[0-9a-fA-F]{2}$ ]]; then
                err "Invalid WWN format: ${wwn} (expected xx:xx:xx:xx:xx:xx:xx:xx)"
                return 1
            fi
            wwn=$(echo "$wwn" | tr '[:upper:]' '[:lower:]')
            local exists
            exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${name}' in d.get('groups', {}) else 'no')
except: pass
")
            [[ "$exists" != "yes" ]] && { err "Group '${name}' not found. Use 'group create' first."; return 1; }
            py_json "
import json
d = json.load(open('${CONFIG}'))
grp = d['groups'].setdefault('${name}', {'initiators': [], 'luns': {}, 'pending_luns': {}})
if '${wwn}' not in grp.setdefault('initiators', []):
    grp['initiators'].append('${wwn}')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Added ${wwn} to group '${name}'. Run 'sync' to update scst.conf."
            ;;

        remove)
            local name="${1:-}" wwn="${2:-}"
            [[ -z "$name" || -z "$wwn" ]] && { err "Usage: group remove <name> <wwn>"; return 1; }
            wwn=$(echo "$wwn" | tr '[:upper:]' '[:lower:]')
            py_json "
import json
d = json.load(open('${CONFIG}'))
grp = d.get('groups', {}).get('${name}', {})
inits = grp.get('initiators', [])
if '${wwn}' in inits:
    inits.remove('${wwn}')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Removed ${wwn} from group '${name}'. Run 'sync' to update scst.conf."
            ;;

        map)
            # group map <name> <extent> [lun]
            local name="${1:-}" extent="${2:-}" lun="${3:-auto}"
            [[ -z "$name" || -z "$extent" ]] && { err "Usage: group map <name> <extent> [lun]"; return 1; }
            local exists
            exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${name}' in d.get('groups', {}) else 'no')
except: pass
")
            [[ "$exists" != "yes" ]] && { err "Group '${name}' not found. Use 'group create' first."; return 1; }
            get_extents_sorted | grep -q "^${extent}$" || { err "Extent '${extent}' not found. Run 'list-extents'"; return 1; }

            # Warn if extent already mapped in another group
            local existing_grps
            existing_grps=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    others = [g for g,data in d.get('groups',{}).items()
              if '${extent}' in data.get('luns',{}) and g != '${name}']
    if others: print(' '.join(others))
except: pass
")
            if [[ -n "$existing_grps" ]]; then
                warn "Extent '${extent}' is already mapped in: ${existing_grps}"
                confirm_or_abort "Map to '${name}' as well?"
            fi

            info "Mapping ${extent} to group '${name}'"
            py_json "
import json
d = json.load(open('${CONFIG}'))
grp = d['groups'].setdefault('${name}', {'initiators': [], 'luns': {}, 'pending_luns': {}})
luns = grp.setdefault('luns', {})
if '${extent}' not in luns:
    if '${lun}' == 'auto':
        next_lun = max(luns.values(), default=-1) + 1
    else:
        next_lun = int('${lun}')
    luns['${extent}'] = next_lun
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            # Apply live to sysfs on all ports this group is attached to
            local port_list
            port_list=$(py_json "
import json
d = json.load(open('${CONFIG}'))
for port, grps in d.get('port_groups', {}).items():
    if '${name}' in grps:
        print(port)
")
            while IFS= read -r wwn; do
                [[ -z "$wwn" ]] && continue
                local tgt_path; tgt_path=$(scst_target_path "$wwn")
                [[ -d "$tgt_path" ]] || continue
                local grp_path="${tgt_path}/ini_groups/${name}"
                [[ -d "$grp_path" ]] || continue
                local lun_id
                lun_id=$(py_json "
import json
d = json.load(open('${CONFIG}'))
print(d.get('groups',{}).get('${name}',{}).get('luns',{}).get('${extent}',''))
")
                [[ -n "$lun_id" && ! -d "${grp_path}/luns/${lun_id}" ]] && \
                    sysfs_write "${grp_path}/luns/mgmt" "add ${extent} ${lun_id}" || true
            done <<< "$port_list"
            ok "Mapped ${extent} to group '${name}'"
            ;;

        unmap)
            # group unmap <name> <extent>
            local name="${1:-}" extent="${2:-}"
            [[ -z "$name" || -z "$extent" ]] && { err "Usage: group unmap <name> <extent>"; return 1; }
            warn "Removing ${extent} from group '${name}'"
            py_json "
import json
d = json.load(open('${CONFIG}'))
grp = d.get('groups', {}).get('${name}', {})
grp.get('luns', {}).pop('${extent}', None)
grp.get('pending_luns', {}).pop('${extent}', None)
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            # Remove from sysfs on all ports this group is attached to
            local port_list
            port_list=$(py_json "
import json
d = json.load(open('${CONFIG}'))
for port, grps in d.get('port_groups', {}).items():
    if '${name}' in grps:
        print(port)
")
            while IFS= read -r wwn; do
                [[ -z "$wwn" ]] && continue
                local grp_path; grp_path="$(scst_target_path "$wwn")/ini_groups/${name}"
                [[ -d "$grp_path" ]] || continue
                for lun_path in "${grp_path}/luns"/*/; do
                    [[ -d "$lun_path" ]] || continue
                    local dev; dev=$(sysfs_read "${lun_path}/device/name" 2>/dev/null || echo "")
                    if [[ "$dev" == "$extent" ]]; then
                        local lun; lun=$(basename "$lun_path")
                        sysfs_write "${grp_path}/luns/mgmt" "del ${lun}" || true
                    fi
                done
            done <<< "$port_list"
            ok "Unmapped ${extent} from group '${name}'"
            ;;

        rename)
            local old_name="${1:-}" new_name="${2:-}"
            [[ -z "$old_name" || -z "$new_name" ]] && { err "Usage: group rename <old> <new>"; return 1; }
            local exists new_exists
            exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${old_name}' in d.get('groups', {}) else 'no')
except: pass
")
            [[ "$exists" != "yes" ]] && { err "Group '${old_name}' not found"; return 1; }
            new_exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${new_name}' in d.get('groups', {}) else 'no')
except: pass
")
            [[ "$new_exists" == "yes" ]] && { err "Group '${new_name}' already exists"; return 1; }
            py_json "
import json
d = json.load(open('${CONFIG}'))
groups = d.get('groups', {})
groups['${new_name}'] = groups.pop('${old_name}')
for pg in d.get('port_groups', {}).values():
    if '${old_name}' in pg:
        pg[pg.index('${old_name}')] = '${new_name}'
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            ok "Group renamed '${old_name}' -> '${new_name}'. Run 'sync' to update scst.conf."
            ;;

        show)
            local name="${1:-}"
            [[ -z "$name" ]] && { err "Usage: group show <name>"; return 1; }
            hdr "Group: ${name}"
            python3 - "${CONFIG}" "${name}" << 'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    grp = d.get('groups', {}).get(sys.argv[2])
    if not grp:
        print('Group not found')
        sys.exit(0)
    inits = grp.get('initiators', [])
    luns  = grp.get('luns', {})
    pending = grp.get('pending_luns', {})
    # Which ports is this group attached to?
    ports = [p for p, gs in d.get('port_groups', {}).items() if sys.argv[2] in gs]
    print('Initiators:')
    for i in inits:
        print(f'  {i}')
    if not inits:
        print('  (none)')
    print('LUN Mappings:')
    for ext, lun_id in luns.items():
        tag = f'  [pending -> {pending[ext]}]' if ext in pending else ''
        print(f'  LUN {lun_id}: {ext}{tag}')
    if not luns:
        print('  (none)')
    print('Active on ports:')
    for p in ports:
        print(f'  {p}')
    if not ports:
        print('  (none - use "port attach <port> ${name}")')
except Exception as e:
    print(f'error: {e}')
PYEOF
            divider
            ;;

        *)
            err "Usage: group <create|delete|add|remove|map|unmap|rename|show>"
            err "  group create <name>           Create an empty named group"
            err "  group delete <name>           Delete group, LUN mappings, and port associations"
            err "  group add    <name> <wwn>     Add an initiator WWN to a group"
            err "  group remove <name> <wwn>     Remove an initiator WWN from a group"
            err "  group map    <name> <extent> [lun]  Map an extent into a group"
            err "  group unmap  <name> <extent>  Remove an extent from a group"
            err "  group rename <old>  <new>     Rename group; updates port associations"
            err "  group show   <name>           Show members, LUN mappings, and active ports"
            return 1
            ;;
    esac
}


# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    hdr "qle_adm.sh v${VERSION} - QLogic FC Target Manager for TrueNAS SCALE"
    printf "%b\n" "$(cat << USAGE_EOF
Status       : status
               stats  [--watch] [--wide]
               list-hba  list-ports  list-initiators  list-extents  list-mapping  list-all
               shortcuts: st  sw  si  lh  lp  li  le  lm  la

Port         : port  enable [--attach-all] | disable | attach | detach | show  <wwn> | --port N

LUN Mapping  : open   <extent> | --ext N
               close  <extent> | --ext N

Group Mgmt   : group  create | delete | add | remove | map | unmap | rename | show

LUN Staging  : lun  set | clear-pending | status

WWN Names    : name  list | set | get | del

Operation    : sync [--apply] [--restart] [--boot]
               hba  swap [--force]
               reset  seen | ports | mappings | names | all
               module  load | unload | reload | status
               teardown

Config       : isp-params  list | set | use | del

Firmware     : fw  list | save-os | save-hba | add | remove | use | show | status

Deployment   : deploy  install | uninstall | reconfigure | status | migrate

Log          : log  show [--tail N] | boot | last [N] | clear | trim [N]
                    grep <pattern> | path | status

Global       : examples  help  version
               --port N   --ext N
               --dry-run  --yes  --verbose  --home <path>
USAGE_EOF
)"
    printf "%b\n" "${DIM}Config: ${QLE_ADM_HOME}/config.json  |  Log: ${LOG}${NC}"
    divider
}
cmd_help() {
    hdr "qle_adm.sh v${VERSION} - QLogic FC Target Manager for TrueNAS SCALE"
    printf "%b\n" "$(cat << HELP_EOF

${WHT}IMPORTANT:${NC} Set QLE_ADM_HOME to a persistent dataset under /mnt before use:
  QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes deploy install

${CYN}Status:${NC}
  stats [--watch] [--wide]       Live IO counters; --watch refreshes every 2s    (sw / si)
  status                         Full state: modules, ports, sessions, gap analysis.  (st)
                                 Passively captures seen_initiators from active sessions.
  list-hba                       Per-port detail: ISP type, firmware, PCI link, WWN    (lh)
  list-ports                     FC ports with managed/unmanaged state and index [N]    (lp)
  list-initiators                Connected initiators with IO stats; seen history always shown  (li)
  list-extents                   SCST extents. Column order: [idx] name  size  s/n  (le)
                                 config:[...]  sysfs:[...]
                                 config:[UNMAPPED]  config:[OPEN]  config:[group]  config:[OPEN,group]
                                 sysfs:[no sysfs]  sysfs:[mapped]  sysfs:[connected]  sysfs:[active]
  list-mapping                   Full LUN mapping topology: groups with initiators,
                                 LUN mappings, and port associations. Groups with no
                                 mappings shown as unconfigured. Port-centric summary
                                 at the end shows the group matrix per enabled port.
                                 (lm)
  list-all                       Runs all list commands in sequence    (la)

${CYN}Port Management:${NC}
  port enable  <wwn>|--port N [--attach-all]
                                 Enable FC target port. Creates empty port_groups
                                 entry by default. --attach-all attaches all
                                 currently defined groups immediately.
  port disable <wwn>|--port N    Disable port and remove its port_groups entry
  port attach  <wwn>|--port N <group>
                                 Associate a group with a port. Applies live to
                                 SCST sysfs if the target is running.
  port detach  <wwn>|--port N <group>
                                 Remove a group from a port. Removes ini_group
                                 from live sysfs if target is running.
  port show    <wwn>|--port N    Show port state and its active groups

${CYN}LUN Mapping:${NC}
  open  <extent>|--ext N         Map extent to all initiators (SCST default luns),
                                 LUN number assigned automatically
  close <extent>|--ext N         Remove from open access

${CYN}Group Management:${NC}
  group create <name>            Create an empty named group
  group delete <name>            Delete group, LUN mappings, and port associations
  group add    <name> <wwn>      Add an initiator WWN to a group
  group remove <name> <wwn>      Remove an initiator WWN from a group
  group map    <name> <extent> [lun]  Map an extent into a group at a LUN number
  group unmap  <name> <extent>   Remove an extent from a group
  group rename <old>  <new>      Rename group; updates all port associations
  group show   <name>            Show members, LUN mappings, and active ports

${CYN}LUN Staging:${NC}
  lun set <extent> <group> <lun> Stage a deferred LUN number change. Writes to pending_luns
                                 in config.json; does not touch live sysfs. Multiple lun set
                                 calls can be staged; validated as a unit at apply time.
                                 Setting the current live LUN number cancels any pending change.
  lun clear-pending <group>|--all Clear all staged pending LUN changes for a group or all.
  lun status [<group>]          Show pending LUN changes and merged desired state with
                                 conflict detection. Prints READY or NOT READY.

${CYN}WWN Names:${NC}
  name list                      All named WWNs with role and port index
  name set <wwn> <name> [--port N]
                                 Assign friendly name; port auto-detected for local HBA ports
  name get <wwn>                 Show name entry for a WWN
  name del <wwn>                 Remove name entry

${CYN}Operation:${NC}
  sync [--apply] [--restart] [--boot]
                                 Rebuild scst.conf from config.json.
                                 --apply  : rebuild scst.conf then apply to live
                                            SCST via scstadmin. Non-disruptive
                                            for LUN mapping changes within
                                            stable groups. Not suitable for
                                            group structural changes (add/remove
                                            groups, initiator membership, port
                                            attach/detach) — use --restart for
                                            those. Use when extents show sysfs:[no sysfs].
                                 --restart: rebuilds scst.conf then restarts
                                            scst.service. All active sessions
                                            dropped. Use after a BE change.
                                 --boot   : full boot-context sync. Writes /etc
                                            files, rebuilds scst.conf, manages
                                            module per boot_mode. Never prompts.
                                            Used by the boot entry.
                                            (--preinit/--system are aliases)
                                 (no flag): scst.conf only - always safe.
  hba swap                       Auto-migrate port config to new card (same ISP, new
                                 port count >= old). Remaps enabled_ports and target
                                 wwn_names to new WWNs by port index; applies live if
                                 SCST is running. Writes hba_identity on completion.
  hba swap --force               Cross-ISP or port count reduction: clears enabled_ports,
                                 preserves assignments, extents, groups, and initiator names. Run
                                 'port enable' to re-activate targets after force-swap.
  reset <seen|ports|mappings|names|all>
                                 Clear accumulated state from config.json and live sysfs
  module <load|unload|reload|status>
                                 Manual module management for initial setup and
                                 recovery. Under normal operation the boot entry
                                 handles the module lifecycle automatically.
                                 load  : modprobe qla2xxx_scst with configured params.
                                         Use for initial setup or after unload.
                                 unload: modprobe -r qla2xxx_scst, revert to qla2xxx.
                                 reload: unload then load (applies param changes).
                                 status: show loaded module, applied vs configured params.
  teardown                       Deactivate targets, unload qla2xxx_scst, revert to initiator

${CYN}Configuration:${NC}
  isp-params list                Show all ISP profiles; marks active (*) and detected
  isp-params set <ISP> [--profile <name>] '<params>'
                                 Create or update a named parameter profile
  isp-params use <ISP> --profile <name>
                                 Set active profile (used on next module load/reload)
  isp-params del <ISP> [--profile <name>]
                                 Delete a profile, or entire ISP entry if no --profile

${CYN}Firmware:${NC}
  fw list                        All stored versions per ISP type with selection marker
  fw save-os [--port N]          Capture OS dist firmware from /usr/lib/firmware into
                                 versioned store with os_<TrueNAS-version> marker.
                                 SHA256 checked - skips if identical already stored.
  fw save-hba [--port N]         Read HBA optrom via sysfs into versioned directory.
                                 SHA256 checked - disambiguates as <ver>-hba on mismatch.
  fw add <ISP> <file>            Import external firmware file. SHA256 checked -
                                 disambiguates as <ver>-imported on mismatch.
  fw remove <ISP> <version>      Remove a specific stored version (not if selected)
  fw use <version|hba|dist> [--port N]
                                 Set active firmware source in config.json.
                                 hba=HBA flash (default), dist=os-marked version,
                                 takes effect on next boot or reboot.
  fw show [--port N]             Per-port detail: running, optrom, stored versions,
                                 selection, ql2xfwloadbin source
  fw status                      One-line summary per port with sync indicator

${CYN}Deployment:${NC}
  deploy install [--mode M]      Install: register boot entry, write /etc artefacts,
                                 copy script to QLE_ADM_HOME. Modes: grub (default),
                                 blacklist, reload. Prompts if --mode not given.
  deploy uninstall               Remove all installed components and kernel cmdline tokens
  deploy reconfigure [--mode M]  Switch boot mode. Tears down old artefacts, installs new.
                                 Offers reboot / sync --restart / defer after change.
  deploy status                  Show active mode and artefact state with gap analysis
  deploy migrate [--apply]       Migrate config.json to the current schema.
                                 Defaults to dry-run preview; use --apply to write.
                                 Backs up config before writing
                                 (config.json.bak, .bak.1, .bak.2 ...).

${CYN}Log Management:${NC}
  log show [--tail N]            Full log (paged); --tail N shows last N lines
  log boot                       Current boot session (from last boot marker)
  log last [N]                   Previous N boot sessions (default 1)
  log clear                      Truncate log file (confirms before clearing)
  log trim [N]                   Keep last N boot sessions, discard older (default 10)
  log grep <pattern>             Filter log by pattern
  log path                       Print log file path
  log status                     Size, line count, session count, oldest/newest entry

${CYN}Subcommands:${NC}
  examples                       Common workflow examples
  help                           This detailed help
  version                        Print version string and exit

${CYN}Global Options:${NC}
  --dry-run                      Print actions without executing any writes
  --yes                          Skip all interactive confirmations
  --verbose                      Extra diagnostic output
  --home <path>                  Override QLE_ADM_HOME for this invocation

${CYN}Index Selection:${NC}
  --port N     FC port by index from list-ports
  --ext N      Extent by index from list-extents
HELP_EOF
)"
    divider
}


cmd_examples() {
    local _LIST_ALL_MODE=1
    hdr "qle_adm.sh v${VERSION} - Examples"

    hdr "Monitoring and status"
    cat << 'EX'

  # Full status with gap analysis
  qle_adm.sh status

  # Live IO stats (refreshes every 2s)
  qle_adm.sh stats --watch

  # See all ports, initiators, extents, and assignments
  qle_adm.sh list-all

EX

    hdr "Enable a port and map LUNs"
    cat << 'EX'

  # Enable port 0 as FC target
  qle_adm.sh port enable --port 0

  # Expose an extent to all initiators (open access)
  qle_adm.sh open --ext 0

  # Create a named group, add initiators, map extents
  qle_adm.sh group create esxi_side_a
  qle_adm.sh group add esxi_side_a 20:00:00:25:b5:c0:a0:1f
  qle_adm.sh group add esxi_side_a 20:00:00:25:b5:c0:a0:7f
  qle_adm.sh group map esxi_side_a cmesxi_vms_lun1 1
  qle_adm.sh group map esxi_side_a cmesxi_vms_lun10 10

  # Attach the group to specific ports
  qle_adm.sh port attach --port 0 esxi_side_a
  qle_adm.sh port attach --port 1 esxi_side_a

  # Or enable a port and attach all groups at once
  qle_adm.sh port enable --port 0 --attach-all

  # Remove a LUN mapping
  qle_adm.sh group unmap esxi_side_a cmesxi_vms_lun10

  # Detach a group from a port
  qle_adm.sh port detach --port 1 esxi_side_a

EX

    hdr "Deferred LUN renumbering"
    cat << 'EX'

  # Stage a LUN number change (does not touch live sessions)
  qle_adm.sh lun set g1ed2-debian esxi_side_a 3

  # Review pending changes and conflict status
  qle_adm.sh lun status

  # Apply - validated as a unit, SCST restarted (drops sessions)
  qle_adm.sh sync --restart

  # Cancel all pending changes for an initiator
  qle_adm.sh lun clear-pending esxi_side_a

EX

    hdr "Name your ports and initiators"
    cat << 'EX'

  # Name local target ports (port index auto-detected from PCI function)
  qle_adm.sh name set 51:40:2e:c0:01:7b:cf:a8 nas0
  qle_adm.sh name set 51:40:2e:c0:01:7b:cf:aa nas0

  # Name remote initiator ports
  qle_adm.sh name set 51:40:2e:c0:01:7b:cf:60 vostro
  qle_adm.sh name set 51:40:2e:c0:01:7b:cf:62 vostro

  # Verify
  qle_adm.sh name list
  qle_adm.sh list-initiators

EX

    hdr "Sync config.json to scst.conf"
    cat << 'EX'

  # After a WUI iSCSI save that wiped the FC target block:
  qle_adm.sh sync

  # Apply scst.conf to live SCST non-disruptively (no session drops):
  qle_adm.sh sync --apply

  # Rebuild scst.conf and restart SCST:
  qle_adm.sh sync --restart

  # After a BE change or upgrade - restore /etc files and restart SCST:
  qle_adm.sh sync --boot && qle_adm.sh sync --restart

EX

    hdr "Module management"
    cat << 'EX'

  # Load qla2xxx_scst with configured params
  qle_adm.sh module load

  # Check loaded vs configured params
  qle_adm.sh module status

  # Reload after an isp-params change
  qle_adm.sh isp-params use ISP2532 --profile optrom
  qle_adm.sh module reload

  # Revert to initiator mode
  qle_adm.sh module unload

EX

    hdr "ISP parameter profiles"
    cat << 'EX'

  # View current profiles and applied vs configured state
  qle_adm.sh isp-params list

  # Add an optrom-firmware profile
  qle_adm.sh isp-params set ISP2532 --profile optrom \
    "qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=1"

  # Switch active profile then reload module to apply
  qle_adm.sh isp-params use ISP2532 --profile optrom
  qle_adm.sh module reload

EX

    hdr "Firmware management"
    cat << 'EX'

  # Capture OS dist firmware (one-time per OS version)
  qle_adm.sh fw save-os

  # Save optrom firmware from HBA to versioned store
  qle_adm.sh fw save-hba

  # See all stored versions and current selection
  qle_adm.sh fw list

  # Show per-port detail including running version and load source
  qle_adm.sh fw show

  # Switch to a stored version (takes effect on next reboot)
  qle_adm.sh fw use 8.08.207

  # Switch back to HBA flash firmware
  qle_adm.sh fw use hba

  # Import a firmware file manually
  qle_adm.sh fw add ISP2532 ~/ql2500_fw_8.08.207.bin

  # Remove a stored version (cannot remove currently selected)
  qle_adm.sh fw remove ISP2532 8.07.00

EX

    hdr "Deployment"
    cat << 'EX'

  # Install with default mode (grub)
  QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes deploy install

  # Install with explicit mode
  QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh deploy install --mode blacklist

  # Check deployment state and artefacts
  qle_adm.sh deploy status

  # Switch boot mode
  qle_adm.sh deploy reconfigure --mode grub

  # Uninstall
  qle_adm.sh deploy uninstall

  # Migrate config.json from an older schema (dry-run first, then apply)
  qle_adm.sh deploy migrate
  qle_adm.sh deploy migrate --apply

EX

    hdr "Dry-run any operation"
    cat << 'EX'

  qle_adm.sh --dry-run sync
  qle_adm.sh --dry-run fw save-os
  qle_adm.sh --dry-run group map esxi_side_a cmesxi_vms_lun1 1

EX
    _divider_force
}


# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    local args=()
    local opt_port="" opt_ext=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=1; shift ;;
            --yes)      YES=1; shift ;;
            --verbose)  VERBOSE=1; shift ;;
            --home)     QLE_ADM_HOME="$2"; CONFIG="${QLE_ADM_HOME}/config.json"
                        FIRMWARE_DIR="${QLE_ADM_HOME}/firmware"
                        LOG="${QLE_ADM_HOME}/qle_adm.log"
                        shift 2 ;;
            --port)     opt_port="$2"; shift 2 ;;
            --ext)      opt_ext="$2"; shift 2 ;;
            --watch)    args+=("--watch"); shift ;;
            --wide)     args+=("--wide"); shift ;;
            --boot)     args+=("--boot"); shift ;;
            --restart)  args+=("--restart"); shift ;;
            --preinit)  args+=("--boot"); shift ;;    # backward compat
            --system)   args+=("--boot"); shift ;;    # backward compat
            *)          args+=("$1"); shift ;;
        esac
    done

    [[ ${#args[@]} -eq 0 ]] && { usage; exit 0; }

    local cmd="${args[0]}"
    local rest=("${args[@]:1}")

    case "$cmd" in
        help|--help|-h) cmd_help; exit 0 ;;
        examples)       cmd_examples; exit 0 ;;
        version)        echo "qle_adm.sh v${VERSION}"; exit 0 ;;
    esac

    [[ $EUID -ne 0 ]] && { err "qle_adm.sh must be run as root"; exit 1; }

    # All commands except deploy install require QLE_ADM_HOME to be set
    if [[ -z "${QLE_ADM_HOME}" && ! ( "$cmd" == "deploy" && "${rest[0]:-}" == "install" ) ]]; then
        err "QLE_ADM_HOME is not set."
        err "Set it to the directory containing config.json before running:"
        err "  QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm ./qle_adm.sh ${cmd}"
        err "  QLE_ADM_HOME=. ./qle_adm.sh ${cmd}   (uninstalled, current directory)"
        exit 1
    fi

    # Verify the script is actually present at QLE_ADM_HOME for commands
    # that require a functioning install (skip for self-contained commands)
    case "$cmd" in
        deploy|version|help|examples) ;;
        *)
            if [[ -n "${QLE_ADM_HOME}" && ! -f "${QLE_ADM_HOME}/qle_adm.sh" ]]; then
                warn "QLE_ADM_HOME is set to '${QLE_ADM_HOME}' but qle_adm.sh was not found there."
                warn "Re-run 'deploy install' or correct QLE_ADM_HOME."
            fi
            ;;
    esac

    case "$cmd" in
        deploy)          cmd_deploy "${rest[@]}" ;;
        sync)            cmd_sync "${rest[@]}" ;;
        hba)             cmd_hba "${rest[@]}" ;;
        lun)            cmd_lun         "${rest[@]}" ;;
        reset)          cmd_reset       "${rest[@]}" ;;
        module)          cmd_module "${rest[@]}" ;;
        teardown)        cmd_teardown ;;
        status|st)       cmd_status ;;
        stats)           cmd_stats "${rest[@]}" ;;
        sw)              cmd_stats "--watch" ;;
        si)              cmd_stats "--wide" ;;
        log)             cmd_log "${rest[@]}" ;;
        list-hba|lh)     cmd_list_hba ;;
        list-ports|lp)   cmd_list_ports ;;
        list-extents|le) cmd_list_extents ;;
        list-initiators|li) cmd_list_initiators "${rest[@]}" ;;
        list-mapping|lm) cmd_list_mapping ;;
        group)           cmd_group "${rest[@]}" ;;
        list-all|la)     cmd_list_all ;;
        port)
            local sub="${rest[0]:-}"
            case "$sub" in
                enable)
                    cmd_port_enable "${rest[1]:-}" "${rest[2]:-}" "$opt_port"
                    ;;
                disable)
                    cmd_port_disable "${rest[1]:-}" "$opt_port"
                    ;;
                attach)
            # port attach <wwn>|--port N <group>
                    local port_arg="${rest[1]:-}" grp_name="${rest[2]:-}"
                    local port_wwn; port_wwn=$(resolve_port "$port_arg" "$opt_port")
                    [[ -z "$port_wwn" || -z "$grp_name" ]] && {
                err "Usage: port attach <wwn>|--port N <group>"
                return 1
                    }
                    port_wwn=$(echo "$port_wwn" | tr '[:upper:]' '[:lower:]')
                    local grp_exists
                    grp_exists=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    print('yes' if '${grp_name}' in d.get('groups', {}) else 'no')
except: pass
")
                    [[ "$grp_exists" != "yes" ]] && { err "Group '${grp_name}' not found"; return 1; }
                    py_json "
import json
d = json.load(open('${CONFIG}'))
pg = d.setdefault('port_groups', {})
port_list = pg.setdefault('${port_wwn}', [])
if '${grp_name}' not in port_list:
    port_list.append('${grp_name}')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            # Apply live: create ini_group on this port if SCST is running
                    local tgt_path; tgt_path=$(scst_target_path "$port_wwn")
                    if [[ -d "$tgt_path" ]]; then
                local grp_path="${tgt_path}/ini_groups/${grp_name}"
                if [[ ! -d "$grp_path" ]]; then
                    sysfs_write "${tgt_path}/ini_groups/mgmt" "create ${grp_name}" || true
                    # Add initiators
                    py_json "
import json
d = json.load(open('${CONFIG}'))
for i in d.get('groups',{}).get('${grp_name}',{}).get('initiators',[]):
    print(i)
" | while IFS= read -r init_wwn; do
                        [[ -n "$init_wwn" ]] && \
                            sysfs_write "${grp_path}/initiators/mgmt" "add ${init_wwn}" || true
                    done
                    # Add LUN mappings
                    py_json "
import json
d = json.load(open('${CONFIG}'))
for ext, lun_id in d.get('groups',{}).get('${grp_name}',{}).get('luns',{}).items():
    print(f'{lun_id} {ext}')
" | while read -r lun_id ext_name; do
                        [[ ! -d "${grp_path}/luns/${lun_id}" ]] && \
                            sysfs_write "${grp_path}/luns/mgmt" "add ${ext_name} ${lun_id}" || true
                    done
                fi
                    fi
                    ok "Group '${grp_name}' attached to port ${port_wwn}. Run 'sync' to persist."
                    ;;

                detach)
            # port detach <wwn>|--port N <group>
                    local port_arg="${rest[1]:-}" grp_name="${rest[2]:-}"
                    local port_wwn; port_wwn=$(resolve_port "$port_arg" "$opt_port")
                    [[ -z "$port_wwn" || -z "$grp_name" ]] && {
                err "Usage: port detach <wwn>|--port N <group>"
                return 1
                    }
                    port_wwn=$(echo "$port_wwn" | tr '[:upper:]' '[:lower:]')
                    warn "Detaching group '${grp_name}' from port ${port_wwn}"
                    py_json "
import json
d = json.load(open('${CONFIG}'))
pg = d.get('port_groups', {}).get('${port_wwn}', [])
if '${grp_name}' in pg:
    pg.remove('${grp_name}')
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
            # Remove ini_group from live sysfs if present
                    local tgt_path; tgt_path=$(scst_target_path "$port_wwn")
                    if [[ -d "$tgt_path" ]]; then
                local grp_path="${tgt_path}/ini_groups/${grp_name}"
                [[ -d "$grp_path" ]] && \
                    sysfs_write "${tgt_path}/ini_groups/mgmt" "del ${grp_name}" || true
                    fi
                    ok "Group '${grp_name}' detached from port ${port_wwn}. Run 'sync' to persist."
                    ;;

                show)
            # port show <wwn>|--port N
                    local port_arg="${rest[1]:-}"
                    local port_wwn; port_wwn=$(resolve_port "$port_arg" "$opt_port")
                    [[ -z "$port_wwn" ]] && { err "Usage: port show <wwn>|--port N"; return 1; }
                    port_wwn=$(echo "$port_wwn" | tr '[:upper:]' '[:lower:]')
                    hdr "Port: ${port_wwn}"
                    python3 - "${CONFIG}" "${port_wwn}" << 'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    port = sys.argv[2]
    enabled = port in d.get('enabled_ports', [])
    groups = d.get('port_groups', {}).get(port, [])
    all_groups = d.get('groups', {})
    print(f'Status:  {"enabled" if enabled else "disabled"}')
    print(f'Groups ({len(groups)}):')
    for g in groups:
                grp = all_groups.get(g, {})
                n_inits = len(grp.get('initiators', []))
                n_luns  = len(grp.get('luns', {}))
                print(f'  {g}  ({n_inits} initiator(s), {n_luns} LUN mapping(s))')
    if not groups:
                print('  (none - use "port attach <wwn> <group>")')
except Exception as e:
    print(f'error: {e}')
PYEOF
                    divider
                    ;;

                *)
                    err "Usage: port <enable|disable|attach|detach|show>"
                    ;;
                    esac
                    ;;
        open)    cmd_open    "${rest[0]:-}" "$opt_ext" ;;
        close)   cmd_close   "${rest[0]:-}" "$opt_ext" ;;
        fw)         cmd_fw         "${rest[@]}" ;;
        isp-params) cmd_isp_params "${rest[@]}" ;;
        name)       cmd_name       "${rest[@]}" ;;
        # Unknown command
        *) err "Unknown command: ${cmd}"; usage; exit 1 ;;
    esac
}

main "$@"
