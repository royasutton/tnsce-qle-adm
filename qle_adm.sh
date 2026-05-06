#!/usr/bin/env bash
# qle_adm.sh - TrueNAS SCALE QLogic FC Target Manager
# Manages qla2xxx_scst targets, LUN mapping, and firmware
# for QLogic ISP2xxx series HBAs on TrueNAS SCALE Community Edition.
#
# Persistent store: set QLE_ADM_HOME to a dataset under /mnt
# Example: QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes install
#
# Requires: bash, python3 (JSON only)
# Version: 1.9

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
VERSION="1.9"
QLE_ADM_HOME="${QLE_ADM_HOME:-}"
CONFIG="${QLE_ADM_HOME}/config.json"
MODPROBE_CONF="/etc/modprobe.d/qla2xxx_scst.conf"
SYSTEMD_DROP="/etc/systemd/system/scst.service.d"
FIRMWARE_DIR="${QLE_ADM_HOME}/firmware"
LOG="${QLE_ADM_HOME}/qle_adm.log"
FLASH_TOOL="qlflash"   # override if tool has different name or path

USE_COLOR=1    # 0 = no ANSI color codes in output
USE_UNICODE=1  # 0 = ASCII fallback for symbols (─ ● ✓ ⚠ ✗ →)

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
[[ $USE_COLOR -eq 0 ]] && RED="" && GRN="" && YLW="" && BLU="" && CYN="" && WHT="" && DIM="" && NC=""

# ─── Symbols ──────────────────────────────────────────────────────────────────
SYM_OK="✓"
SYM_WARN="⚠"
SYM_ERR="✗"
SYM_INFO="→"
SYM_BULLET="●"
SYM_HBAR="─"
[[ $USE_UNICODE -eq 0 ]] && SYM_OK="*" && SYM_WARN="!" && SYM_ERR="x" && SYM_INFO=">" && SYM_BULLET="*" && SYM_HBAR="-"

ok()   { echo -e "${GRN}${SYM_OK}${NC} $*"; }
warn() { echo -e "${YLW}${SYM_WARN}${NC}  $*"; }
err()  { echo -e "${RED}${SYM_ERR}${NC} $*" >&2; }
info() { echo -e "${BLU}${SYM_INFO}${NC} $*" >&2; }
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

hdr()  { echo -e "\n${WHT}$*${NC}"; echo -e "${DIM}$(hbar)${NC}"; }
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

cfg_init() {
    [[ -f "$CONFIG" ]] && return
    py_json "
import json
d = {
    'version': '${VERSION}',
    'mode': 'open',
    'enabled_ports': [],
    'open_extents': [],
    'assignments': {},
    'seen_initiators': {},
    'isp_params': {
        'ISP2432': {'default': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0'},
        'ISP2532': {'default': 'qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=1'},
        'ISP2322': {'default': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0'},
        'DEFAULT': {'default': 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0'}
    },
    'isp_active_profile': {},
    'wwn_names': {},
    'firmware': {}
}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print('Config initialized.')
"
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
    read -r reply
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
        local reply; read -r reply
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
            local reply; read -r reply
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
            local reply; read -r reply
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

sysfs_read() {
    local path="$1"
    [[ -r "$path" ]] && cat "$path" 2>/dev/null | tr -d '\n' || echo ""
}

hex_to_dec() {
    local val="${1:-0}"
    printf "%d" "$val" 2>/dev/null || echo "0"
}

# ─── WWN index resolution ─────────────────────────────────────────────────────
# Ports are indexed by sorted WWN order — stable across reboots (tied to HW)
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
    grep -E '^\s+DEVICE\s+' /etc/scst.conf 2>/dev/null | awk '{print $2}' | sort -u
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
        [[ -z "$wwn" ]] && { err "No port at index ${idx_arg}"; exit 1; }
        info "Port ${idx_arg} resolved to: ${wwn}"
        echo "$wwn"
    else
        echo "$arg"
    fi
}

resolve_initiator() {
    local arg="$1" idx_arg="$2"
    if [[ -n "$arg" && -n "$idx_arg" ]]; then
        err "Specify either a WWN or --init N, not both"
        exit 1
    fi
    if [[ -n "$idx_arg" ]]; then
        local wwn
        # First try active sessions, then fall back to seen_initiators
        wwn=$(get_initiator_wwn_by_index "$idx_arg")
        if [[ -z "$wwn" ]]; then
            wwn=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    seen = sorted(d.get('seen_initiators', {}).keys())
    if ${idx_arg} < len(seen):
        print(seen[${idx_arg}])
except: pass
")
        fi
        [[ -z "$wwn" ]] && { err "No initiator at index ${idx_arg} (active or seen)"; exit 1; }
        info "Initiator ${idx_arg} resolved to: ${wwn}"
        echo "$wwn"
    else
        # Validate WWN format if provided directly (xx:xx:xx:xx:xx:xx:xx:xx)
        if [[ -n "$arg" && ! "$arg" =~ ^([0-9a-fA-F]{2}:){7}[0-9a-fA-F]{2}$ ]]; then
            err "Invalid WWN format: ${arg} (expected xx:xx:xx:xx:xx:xx:xx:xx)"
            exit 1
        fi
        echo "$arg"
    fi
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
        isp_type=$(dmesg 2>/dev/null | grep "${pci_addr}" | grep -oP 'ISP\d+' | head -1 || echo "UNKNOWN")
        echo "${idx} ${host_num} ${pci_addr} ${isp_type} ${wwn} ${fw_ver} ${port_state} ${port_type}"
        idx=$((idx + 1))
    done
}

get_isp_type_dominant() {
    detect_hbas | awk '{print $4}' | sort | uniq -c | sort -rn | awk '{print $2}' | head -1
}

get_module_params() {
    local isp_type="$1" profile_override="${2:-}"
    py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    isp_map = d.get('isp_params', {})
    entry = isp_map.get('${isp_type}', isp_map.get('DEFAULT', {}))
    active = d.get('isp_active_profile', {}).get('${isp_type}', 'default')
    profile = '${profile_override}' if '${profile_override}' else active
    print(entry.get(profile, entry.get('default', 'qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0')))
except:
    print('qlini_mode=disabled ql2xfc2target=1 ql2xnvmeenable=0')
"
}

get_applied_params() {
    # Read actual running module parameters from sysfs.
    # Returns reconstructed param string, or empty if module not loaded.
    local mod="qla2xxx_scst"
    module_loaded "$mod" || { echo ""; return; }
    local base="/sys/module/${mod}/parameters"
    local result=""
    local qlini; qlini=$(cat "${base}/qlini_mode"     2>/dev/null || echo "")
    local fc2;   fc2=$(cat "${base}/ql2xfc2target"    2>/dev/null || echo "")
    local nvme;  nvme=$(cat "${base}/ql2xnvmeenable"  2>/dev/null || echo "")
    local fwbin; fwbin=$(cat "${base}/ql2xfwloadbin"  2>/dev/null || echo "")
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
    # Check sysfs for local HBA port — find fc_host whose port_name matches
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
        sysfs_write "$rel_path" "$rel_id" || true
    fi

    sysfs_write "${tgt_path}/enabled" "1"
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
firmware_overlay_active() { mount | grep -q "on /usr/lib/firmware"; }

setup_firmware_overlay() {
    local isp_type="$1"
    local fw_file="${ISP_FW_FILE[$isp_type]:-}"
    local stored="${FIRMWARE_DIR}/${isp_type}/${fw_file}"
    [[ -z "$fw_file" || ! -f "$stored" ]] && return 0
    local ver; ver=$(strings "$stored" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    info "Firmware overlay: ${isp_type} ${fw_file} version ${ver}"
    if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -pv /run/qle_adm_firmware
        cp -v "$stored" "/run/qle_adm_firmware/${fw_file}"
        if ! mount | grep -q "on /usr/lib/firmware"; then
            mount --bind /run/qle_adm_firmware /usr/lib/firmware
        else
            cp -v "$stored" "/usr/lib/firmware/${fw_file}"
        fi
        echo "/run/qle_adm_firmware" > /sys/module/firmware_class/parameters/path 2>/dev/null || true
    else
        info "[DRY-RUN] would bind-mount ${stored} over /usr/lib/firmware/${fw_file}"
    fi
}

teardown_firmware_overlay() {
    if mount | grep -q "on /usr/lib/firmware"; then
        [[ $DRY_RUN -eq 0 ]] && umount /usr/lib/firmware && info "Firmware overlay removed"
    fi
}

# ─── Module management ────────────────────────────────────────────────────────
module_loaded() { [[ -d "/sys/module/${1}" ]]; }

load_target_module() {
    local isp_type="$1"
    local params; params=$(get_module_params "$isp_type")
    local fw_file="${ISP_FW_FILE[$isp_type]:-}"
    local stored="${FIRMWARE_DIR}/${isp_type}/${fw_file:-}"
    if [[ -n "$fw_file" && -f "$stored" ]]; then
        params="${params} ql2xfwloadbin=2"
        setup_firmware_overlay "$isp_type"
    fi
    info "Loading qla2xxx_scst: ${params}"
    if [[ $DRY_RUN -eq 0 ]]; then
        modprobe -r qla2xxx 2>/dev/null || true
        modprobe -r qla2xxx_scst 2>/dev/null || true
        sleep 1
        modprobe qla2xxx_scst $params
        log "loaded qla2xxx_scst params=${params}"
    else
        info "[DRY-RUN] modprobe -r qla2xxx"
        info "[DRY-RUN] modprobe qla2xxx_scst ${params}"
    fi
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_install() {
    hdr "Installing qle_adm.sh v${VERSION}"

    # Validate QLE_ADM_HOME
    if [[ -z "${QLE_ADM_HOME}" ]]; then
        err "QLE_ADM_HOME is not set."
        err "qle_adm.sh must be installed on a data pool to survive boot environment changes."
        err ""
        err "Set QLE_ADM_HOME before installing:"
        err "  QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes install"
        return 1
    fi
    if [[ "${QLE_ADM_HOME}" == /root* ]]; then
        warn "QLE_ADM_HOME is ${QLE_ADM_HOME}"
        warn "/root is wiped on boot environment changes — use /mnt/<pool>/... instead"
        confirm_or_abort "Continue installing to /root anyway?"
    fi
    if [[ "${QLE_ADM_HOME}" != /mnt/* && "${QLE_ADM_HOME}" != /root* ]]; then
        warn "QLE_ADM_HOME (${QLE_ADM_HOME}) is not under /mnt — may not survive BE changes"
        confirm_or_abort "Continue anyway?"
    fi

    mkdir_v "${QLE_ADM_HOME}"
    mkdir_v "${FIRMWARE_DIR}"

    if [[ $DRY_RUN -eq 0 ]]; then
        touch "$LOG"
        cfg_init
    fi

    # modprobe config
    local isp_type; isp_type=$(get_isp_type_dominant)
    local params; params=$(get_module_params "$isp_type")
    info "Modprobe config for ${isp_type}: ${params}"
    file_write "$MODPROBE_CONF" "options qla2xxx_scst ${params}"

    # boot service
    file_write "/etc/systemd/system/qle_adm-boot.service" "[Unit]
Description=qle_adm FC Target Boot Setup
Before=scst.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=QLE_ADM_HOME=${QLE_ADM_HOME}
ExecStart=${QLE_ADM_HOME}/qle_adm.sh setup --boot

[Install]
WantedBy=multi-user.target"

    # Install self
    local src_real dst_real
    src_real=$(realpath "$0" 2>/dev/null || echo "$0")
    dst_real=$(realpath "${QLE_ADM_HOME}/qle_adm.sh" 2>/dev/null || echo "${QLE_ADM_HOME}/qle_adm.sh")
    if [[ "$src_real" == "$dst_real" ]]; then
        ok "Script already installed at ${QLE_ADM_HOME}/qle_adm.sh"
    else
        copy_v "$0" "${QLE_ADM_HOME}/qle_adm.sh"
        [[ $DRY_RUN -eq 0 && -f "${QLE_ADM_HOME}/qle_adm.sh" ]] && chmod +x "${QLE_ADM_HOME}/qle_adm.sh"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] systemctl daemon-reload && systemctl enable qle_adm-boot.service"
    else
        confirm "Enable qle_adm-boot.service at boot?" && {
            systemctl daemon-reload
            systemctl enable qle_adm-boot.service
            ok "Enabled: qle_adm-boot.service"
            log "systemctl enable qle_adm-boot.service"
        }
    fi

    ok "Installation complete"
    info "Invoke as: ${QLE_ADM_HOME}/qle_adm.sh <command>"
    info "Run 'qle_adm.sh status' to check state"
    info "Run 'qle_adm.sh list-extents' to see available devices"
    info "Run 'qle_adm.sh list-ports' to see FC ports"
}

cmd_uninstall() {
    hdr "Uninstalling qle_adm.sh"
    warn "This will remove all qle_adm-managed configuration files"
    confirm_or_abort "Proceed with uninstall?"

    cmd_teardown

    rm_f_v "$MODPROBE_CONF"
    rm_f_v "${SYSTEMD_DROP}/qle_adm-preload.conf"
    rm_f_v "/etc/systemd/system/qle_adm-boot.service"

    if [[ $DRY_RUN -eq 0 ]]; then
        confirm "Run systemctl daemon-reload?" && systemctl daemon-reload && ok "daemon-reload complete"
    else
        info "[DRY-RUN] systemctl daemon-reload"
    fi

    ok "Uninstall complete. Config preserved at ${QLE_ADM_HOME}"
    info "To fully remove: rm -rf ${QLE_ADM_HOME}"
}

# ─── scst.conf FC target block ────────────────────────────────────────────────
scst_conf_ensure_fc_target() {
    # Inject TARGET_DRIVER qla2x00t block into /etc/scst.conf if missing.
    # TrueNAS WUI regenerates scst.conf on every iSCSI change, wiping manual
    # edits. This function is called from setup --boot (which runs as
    # ExecStartPre before SCST starts) so the block is always present when
    # SCST reads the file.
    local conf="/etc/scst.conf"
    [[ -f "$conf" ]] || { warn "scst.conf not found — skipping FC target block injection"; return 0; }
    if grep -q "TARGET_DRIVER qla2x00t" "$conf"; then
        ok "scst.conf already contains TARGET_DRIVER qla2x00t block"
        return 0
    fi
    info "Injecting TARGET_DRIVER qla2x00t block into ${conf}"
    if [[ $DRY_RUN -eq 0 ]]; then
        cat >> "$conf" << 'EOF'

TARGET_DRIVER qla2x00t {
}
EOF
        ok "Injected TARGET_DRIVER qla2x00t block into ${conf}"
        log "injected TARGET_DRIVER qla2x00t into ${conf}"
    else
        info "[DRY-RUN] would append TARGET_DRIVER qla2x00t {} to ${conf}"
    fi
}


cmd_setup() {
    local boot_mode=0
    [[ "${1:-}" == "--boot" ]] && boot_mode=1
    hdr "Setting up FC targets"
    cfg_init

    local isp_type; isp_type=$(get_isp_type_dominant)
    [[ -z "$isp_type" || "$isp_type" == "UNKNOWN" ]] && isp_type="ISP2532"

    # Ensure scst.conf has FC target block before SCST starts
    scst_conf_ensure_fc_target

    if ! module_loaded "qla2xxx_scst"; then
        load_target_module "$isp_type"
        sleep 5
    else
        ok "qla2xxx_scst already loaded"
    fi

    cmd_apply
    ok "Setup complete"
}

cmd_teardown() {
    hdr "Tearing down FC targets"
    local sessions=0
    for sess_path in /sys/kernel/scst_tgt/targets/qla2x00t/*/sessions/*/; do
        [[ -d "$sess_path" ]] && sessions=$((sessions + 1))
    done
    if [[ $sessions -gt 0 ]]; then
        warn "${sessions} active session(s) will be disconnected"
        confirm_or_abort "Continue teardown? Active sessions will be dropped."
    fi
    teardown_firmware_overlay
    if module_loaded "qla2xxx_scst"; then
        run_cmd systemctl stop scst 2>/dev/null || true
        run_cmd modprobe -r qla2xxx_scst 2>/dev/null || true
        run_cmd modprobe qla2xxx qlini_mode=enabled ql2xnvmeenable=0
        ok "Reverted to initiator mode (plain qla2xxx)"
    else
        ok "qla2xxx_scst not loaded"
    fi
}

cmd_apply() {
    hdr "Applying configuration"
    cfg_init

    local enabled_ports; enabled_ports=$(cfg_get_list "enabled_ports")
    [[ -z "$enabled_ports" ]] && { warn "No ports enabled. Use 'qle_adm.sh port enable <wwn>'"; return; }

    while IFS= read -r wwn; do
        [[ -z "$wwn" ]] && continue
        local tgt_path; tgt_path=$(scst_target_path "$wwn")
        if [[ ! -d "$tgt_path" ]]; then
            warn "Target path not found for ${wwn} — SCST may not be running"
            continue
        fi

        # Get port index for rel_tgt_id
        local port_idx=0
        local i=0
        while IFS= read -r pwwn; do
            [[ "$pwwn" == "$wwn" ]] && port_idx=$i
            i=$((i + 1))
        done < <(get_port_wwns_sorted)

        # Enable target with unique rel_tgt_id
        scst_enable_target "$wwn" "$port_idx"
        ok "Target ${wwn} enabled (rel_tgt_id=$((port_idx + 1)))"

        # Apply open extents to default group
        local lun=0
        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            local lun_path="${tgt_path}/luns/${lun}"
            if [[ ! -d "$lun_path" ]]; then
                info "Adding LUN ${lun} -> ${ext} (open)"
                sysfs_write "${tgt_path}/luns/mgmt" "add ${ext} ${lun}" || true
            fi
            lun=$((lun + 1))
        done < <(cfg_get_list "open_extents")

        # Apply per-initiator assignments
        py_json "
import json, sys
try:
    d = json.load(open('${CONFIG}'))
    for init, data in d.get('assignments', {}).items():
        if data.get('extents'):
            print(init)
except:
    pass
" | while IFS= read -r initiator; do
            # Use WWN directly as group name — matches SCST auto-created group on session connect
            local grp_path="${tgt_path}/ini_groups/${initiator}"
            if [[ ! -d "$grp_path" ]]; then
                sysfs_write "${tgt_path}/ini_groups/mgmt" "create ${initiator}" || true
                sysfs_write "${grp_path}/initiators/mgmt" "add ${initiator}" || true
                info "Created ini_group ${initiator}"
            else
                # Ensure initiator is in the group
                grep -qr "$initiator" "${grp_path}/initiators/" 2>/dev/null || \
                    sysfs_write "${grp_path}/initiators/mgmt" "add ${initiator}" || true
            fi
            py_json "
import json
d = json.load(open('${CONFIG}'))
data = d.get('assignments', {}).get('${initiator}', {})
for i, ext in enumerate(data.get('extents', [])):
    lun = data.get('luns', {}).get(ext, i)
    print(f'{lun} {ext}')
" | while IFS= read -r lun ext; do
                [[ ! -d "${grp_path}/luns/${lun}" ]] && \
                    sysfs_write "${grp_path}/luns/mgmt" "add ${ext} ${lun}" || true
            done
        done

    done <<< "$enabled_ports"
    ok "Configuration applied"
}

cmd_save() {
    hdr "Saving configuration"
    scst_record_sessions
    ok "Configuration saved to ${CONFIG}"
}

cmd_repair() {
    hdr "Repair / Post-Upgrade Recovery"
    info "Checking for missing components..."

    if [[ ! -f "$MODPROBE_CONF" ]]; then
        warn "Reinstalling modprobe config"
        local isp_type; isp_type=$(get_isp_type_dominant)
        local params; params=$(get_module_params "$isp_type")
        file_write "$MODPROBE_CONF" "options qla2xxx_scst ${params}"
    else
        ok "modprobe config present"
    fi

    if [[ ! -f "/etc/systemd/system/qle_adm-boot.service" ]]; then
        warn "Reinstalling qle_adm-boot.service"
        file_write "/etc/systemd/system/qle_adm-boot.service" "[Unit]
Description=qle_adm FC Target Boot Setup
Before=scst.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=QLE_ADM_HOME=${QLE_ADM_HOME}
ExecStart=${QLE_ADM_HOME}/qle_adm.sh setup --boot

[Install]
WantedBy=multi-user.target"
        [[ $DRY_RUN -eq 0 ]] && systemctl daemon-reload && systemctl enable qle_adm-boot.service
    else
        ok "qle_adm-boot.service present"
    fi

    info "Shell rc files not modified. Invoke as: ${QLE_ADM_HOME}/qle_adm.sh <command>"
    ok "Repair complete"
    info "Run 'qle_adm.sh setup' to reload modules and apply config"
}

cmd_status() {
    hdr "qle_adm Status v${VERSION}"
    cfg_init

    local gaps=0

    # Module status
    echo -e "\n${CYN}Modules:${NC}"
    if [[ -d /sys/module/qla2xxx_scst ]]; then
        ok "qla2xxx_scst loaded (target mode)"
    elif [[ -d /sys/module/qla2xxx ]]; then
        warn "qla2xxx loaded (initiator mode) — not target mode"
        gap "qla2xxx_scst not loaded"
        gaps=$((gaps + 1))
    else
        gap "No QLogic FC module loaded"
        gaps=$((gaps + 1))
    fi

    # SCST service
    echo -e "\n${CYN}SCST Service:${NC}"
    if systemctl is-active scst &>/dev/null; then
        ok "scst.service active"
    else
        gap "scst.service not running"
        gaps=$((gaps + 1))
    fi

    # modprobe config
    echo -e "\n${CYN}Configuration:${NC}"
    if [[ -f "$MODPROBE_CONF" ]]; then
        ok "modprobe config present: ${MODPROBE_CONF}"
    else
        gap "modprobe config missing: ${MODPROBE_CONF}"
        gaps=$((gaps + 1))
    fi

    if [[ -f "/etc/systemd/system/qle_adm-boot.service" ]]; then
        ok "qle_adm-boot.service installed"
    else
        gap "qle_adm-boot.service missing — run 'qle_adm.sh install'"
        gaps=$((gaps + 1))
    fi

    # Param drift check
    local isp_type; isp_type=$(get_isp_type_dominant 2>/dev/null || echo "")
    if [[ -n "$isp_type" ]] && module_loaded "qla2xxx_scst"; then
        local applied configured
        applied=$(get_applied_params)
        configured=$(get_module_params "$isp_type")
        if [[ -n "$applied" && "$applied" != "$configured" ]]; then
            gap "Module params drift — applied differs from configured (run 'setup' to resync)"
            gaps=$((gaps + 1))
        fi
    fi

    # Firmware overlay
    echo -e "\n${CYN}Firmware:${NC}"
    if firmware_overlay_active; then
        ok "Custom firmware overlay active"
        strings /usr/lib/firmware/ql2400_fw.bin 2>/dev/null | grep -i version | head -1 | awk '{print "  └─ "$0}'
    else
        info "Using HBA flash firmware"
    fi

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
        ok "No gaps detected — system fully operational"
    else
        warn "${gaps} gap(s) detected — run 'qle_adm.sh repair' to fix"
    fi
}

cmd_hba_info() {
    hdr "HBA Information"
    detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
        local scsi_host="/sys/class/scsi_host/${host}"
        local fc_host="/sys/class/fc_host/${host}"

        local fw_raw fw_build
        fw_raw=$(sysfs_read "${scsi_host}/fw_version" 2>/dev/null || echo "unknown")
        fw_ver=$(echo "$fw_raw" | awk '{print $1}')
        fw_build=$(echo "$fw_raw" | grep -oP '(?<=\()\d+(?=\))' || echo "")

        local state_str ptype_short
        [[ "$state" == "Online" ]] && state_str="${GRN}${state}${NC}" || state_str="${RED}${state}${NC}"
        ptype_short=$(echo "$ptype" | sed 's/Point-To-Point (direct nport connection)/Point-To-Point/')

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
        echo "$lspci_out" | grep -q "downgraded" && pci_downgraded=" ${YLW}(downgraded)${NC}"

        local fw_file stored stored_ver
        fw_file="${ISP_FW_FILE[$isp]:-}"
        stored="${FIRMWARE_DIR}/${isp}/${fw_file}"
        [[ -n "$fw_file" && -f "$stored" ]] && \
            stored_ver=$(strings "$stored" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown") || \
            stored_ver=""

        echo -e "\n${WHT}[${idx}] ${host}${NC} — ${isp} @ ${pci}"
        echo -e "  WWN        : ${CYN}${wwn}${NC}"
        echo -e "  Running FW : ${fw_ver}${fw_build:+ (build ${fw_build})}"
        echo -e "  Primary FW : ${primary_fw:-${DIM}not exposed by driver${NC}}"
        echo -e "  Optrom FW  : ${optrom_fw:-n/a}"
        echo -e "  Stored FW  : ${stored_ver:-${DIM}none${NC}}"
        echo -e "  Port State : $(echo -e "${state_str}")"
        echo -e "  Port Type  : ${ptype_short}"
        echo -e "  Link Speed : ${speed} Gbps"
        echo -e "  Max Speed  : ${max_speed} Gbps"
        echo -e "  Model      : ${model}"
        echo -e "  Serial     : ${serial}"
        echo -e "  PCIe Cap   : ${pci_lnkcap_speed} ${pci_lnkcap_width}"
        echo -e "  PCIe Link  : ${pci_lnksta_speed} ${pci_lnksta_width}${pci_downgraded}"
    done
}

cmd_list_all() {
    cmd_list_ports
    cmd_list_extents
    cmd_list_initiators --seen
    cmd_list_assignments
}

cmd_list_ports() {
    hdr "FC Ports"
    cfg_init
    local enabled_ports; enabled_ports=$(cfg_get_list "enabled_ports")
    detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
        local managed state_col ptype_short
        echo "$enabled_ports" | grep -q "$wwn" && managed="${GRN}managed${NC}" || managed="${YLW}unmanaged${NC}"
        [[ "$state" == "Online" ]] && state_col="$GRN" || state_col="$RED"
        ptype_short=$(echo "$ptype" | sed 's/Point-To-Point (direct nport connection)/P2P/')
        local label; label=$(wwn_label "$wwn" "target")
        echo -e "  [${idx}] ${WHT}${wwn}${NC} (${CYN}${label}${NC})  ${isp}  ${host}  ${state_col}${state}${NC}  ${ptype_short}  [${managed}]"
    done
}

cmd_list_extents() {
    hdr "Available Extents"
    local open_extents; open_extents=$(cfg_get_list "open_extents")
    local idx=0
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        local status
        echo "$open_extents" | grep -q "^${ext}$" && status="${GRN}[open]${NC}" || status="${DIM}[unmapped]${NC}"
        local assigned
        assigned=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    inits = [i for i,data in d.get('assignments',{}).items() if '${ext}' in data.get('extents',[])]
    if inits: print('assigned to: ' + ', '.join(inits))
except: pass
")
        local dev_path="/sys/kernel/scst_tgt/devices/${ext}"
        local size=""
        [[ -d "$dev_path" ]] && size=$(sysfs_read "${dev_path}/size_mb" 2>/dev/null || echo "") && \
            [[ -n "$size" ]] && size="${size} MB"
        echo -e "  [${idx}] ${WHT}${ext}${NC}  ${size}  ${status}${assigned:+  ${CYN}${assigned}${NC}}"
        idx=$((idx + 1))
    done < <(get_extents_sorted)
    [[ $idx -eq 0 ]] && echo -e "  ${DIM}No extents found in /etc/scst.conf${NC}" || true
}

cmd_list_initiators() {
    local show_seen=0
    [[ "${1:-}" == "--seen" ]] && show_seen=1

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
        echo -e "  [${i}] ${GRN}${SYM_BULLET}${NC} ${init_wwn} (${CYN}${init_label}${NC}) ${SYM_INFO} ${tgt_wwn} (${CYN}${tgt_label}${NC})"
        echo -e "       Cmds: ${cmds}  R: ${rc} (${rk} KB)  W: ${wc} (${wk} KB)"
        cfg_record_seen_initiator "$init_wwn"
        i=$((i + 1))
        found=$((found + 1))
    done
    [[ $found -eq 0 ]] && echo -e "  ${DIM}(none)${NC}" || true

    if [[ $show_seen -eq 1 ]]; then
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
                echo -e "  ${wwn} (${CYN}${lbl}${NC})  last seen: ${ts}"
            done <<< "$seen_list"
        fi
    fi
}

cmd_list_assignments() {
    hdr "LUN Assignments"
    echo -e "\n${CYN}Open Access (all initiators):${NC}"
    local open_extents; open_extents=$(cfg_get_list "open_extents")
    if [[ -z "$open_extents" ]]; then
        echo -e "  ${DIM}(none)${NC}"
    else
        local lun=0
        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            echo -e "  LUN ${lun}: ${WHT}${ext}${NC}"
            lun=$((lun + 1))
        done <<< "$open_extents"
    fi
    echo -e "\n${CYN}Per-Initiator Assignments:${NC}"
    local init_list
    init_list=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    assignments = d.get('assignments', {})
    for init, data in assignments.items():
        luns = ' '.join(f'{data.get('luns',{}).get(ext,i)}:{ext}' for i,ext in enumerate(data.get('extents',[])))
        print(f'{init} {luns}')
except: pass
")
    if [[ -z "$init_list" ]]; then
        echo -e "  ${DIM}(none)${NC}"
    else
        while IFS=' ' read -r init rest; do
            local lbl; lbl=$(wwn_label "$init" "initiator")
            echo -e "  ${WHT}${init}${NC} (${CYN}${lbl}${NC})"
            for pair in $rest; do
                local lun ext
                lun="${pair%%:*}"
                ext="${pair#*:}"
                echo -e "    LUN ${lun}: ${ext}"
            done
        done <<< "$init_list"
    fi
}

cmd_port_enable() {
    local wwn_arg="${1:-}" port_idx="${2:-}"
    local wwn; wwn=$(resolve_port "$wwn_arg" "$port_idx")
    [[ -z "$wwn" ]] && { err "Usage: port enable <wwn>|--port N"; return 1; }
    wwn=$(echo "$wwn" | tr '[:upper:]' '[:lower:]')
    info "Enabling port ${wwn}"
    cfg_list_add "enabled_ports" "$wwn"
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
        warn "SCST target path not found — will apply on next 'qle_adm.sh apply'"
    fi
}

cmd_port_disable() {
    local wwn_arg="${1:-}" port_idx="${2:-}"
    local wwn; wwn=$(resolve_port "$wwn_arg" "$port_idx")
    [[ -z "$wwn" ]] && { err "Usage: port disable <wwn>|--port N"; return 1; }
    wwn=$(echo "$wwn" | tr '[:upper:]' '[:lower:]')
    warn "Disabling port ${wwn}"
    cfg_list_remove "enabled_ports" "$wwn"
    local tgt_path; tgt_path=$(scst_target_path "$wwn")
    [[ -d "$tgt_path" ]] && sysfs_write "${tgt_path}/enabled" "0" && ok "Port ${wwn} disabled"
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
    local ext_arg="${1:-}" ext_idx="${2:-}" init_arg="${3:-}" init_idx="${4:-}" lun="${5:-auto}"
    local extent; extent=$(resolve_extent "$ext_arg" "$ext_idx")
    local initiator; initiator=$(resolve_initiator "$init_arg" "$init_idx")
    [[ -z "$extent" || -z "$initiator" ]] && { err "Usage: assign <extent>|--ext N <wwn>|--init N [lun]"; return 1; }
    initiator=$(echo "$initiator" | tr '[:upper:]' '[:lower:]')
    get_extents_sorted | grep -q "^${extent}$" || { err "Extent '${extent}' not found"; return 1; }

    # Warn if extent already assigned to another initiator
    local existing
    existing=$(py_json "
import json
try:
    d = json.load(open('${CONFIG}'))
    others = [i for i,data in d.get('assignments',{}).items()
              if '${extent}' in data.get('extents',[]) and i != '${initiator}']
    if others: print(', '.join(others))
except: pass
")
    if [[ -n "$existing" ]]; then
        warn "Extent '${extent}' is already assigned to: ${existing}"
        confirm_or_abort "Assign to ${initiator} as well?"
    fi

    info "Assigning ${extent} to ${initiator}"
    py_json "
import json
d = json.load(open('${CONFIG}'))
assignments = d.setdefault('assignments', {})
init_data = assignments.setdefault('${initiator}', {'extents': [], 'luns': {}})
if '${extent}' not in init_data['extents']:
    init_data['extents'].append('${extent}')
    next_lun = len(init_data['extents']) - 1
    if '${lun}' != 'auto':
        next_lun = int('${lun}')
    init_data['luns']['${extent}'] = next_lun
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
    cmd_apply
    ok "Assigned ${extent} to ${initiator}"
}

cmd_unassign() {
    local ext_arg="${1:-}" ext_idx="${2:-}" init_arg="${3:-}" init_idx="${4:-}"
    local extent; extent=$(resolve_extent "$ext_arg" "$ext_idx")
    local initiator; initiator=$(resolve_initiator "$init_arg" "$init_idx")
    [[ -z "$extent" || -z "$initiator" ]] && { err "Usage: unassign <extent>|--ext N <wwn>|--init N"; return 1; }
    initiator=$(echo "$initiator" | tr '[:upper:]' '[:lower:]')
    warn "Removing ${extent} from ${initiator}"
    py_json "
import json
d = json.load(open('${CONFIG}'))
init_data = d.get('assignments', {}).get('${initiator}', {})
extents = init_data.get('extents', [])
if '${extent}' in extents:
    extents.remove('${extent}')
    init_data.get('luns', {}).pop('${extent}', None)
json.dump(d, open('${CONFIG}', 'w'), indent=2)
"
    while IFS= read -r wwn; do
        [[ -z "$wwn" ]] && continue
        local grp_name="grp_${initiator//:/_}"
        local grp_path; grp_path="$(scst_target_path "$wwn")/ini_groups/${grp_name}"
        [[ -d "$grp_path" ]] || continue
        for lun_path in "${grp_path}/luns"/*/; do
            [[ -d "$lun_path" ]] || continue
            local dev; dev=$(sysfs_read "${lun_path}/device/name" 2>/dev/null || echo "")
            if [[ "$dev" == "$extent" ]]; then
                local lun; lun=$(basename "$lun_path")
                sysfs_write "${grp_path}/luns/mgmt" "del ${lun}" || true
            fi
        done
    done < <(cfg_get_list "enabled_ports")
    ok "Unassigned ${extent} from ${initiator}"
}

cmd_clear() {
    local subcmd="${1:-}"; shift || true
    [[ -z "$subcmd" ]] && { err "Usage: clear <seen|ports|mappings|names|all>"; return 1; }

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
            [[ -d "$tgt_path" ]] && sysfs_write "${tgt_path}/enabled" "0" || true
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
ai = len(d.get('assignments', {}))
d['open_extents'] = []
d['assignments'] = {}
json.dump(d, open('${CONFIG}', 'w'), indent=2)
print(f'{oe} open extents, {ai} initiator assignments')
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
                read -r answer
                [[ "$answer" != "y" && "$answer" != "Y" ]] && { info "Aborted"; return 0; }
            }
            _clear_ports    >/dev/null
            _clear_mappings >/dev/null
            _clear_seen     >/dev/null
            _clear_names    >/dev/null
            ok "All operational state cleared"
            ok "ISP params, firmware store, and active profiles preserved"
            ;;
        *) err "Unknown clear target: ${subcmd}  (seen|ports|mappings|names|all)" ;;
    esac
}

cmd_stats() {
    local watch_mode=0 wide_mode=0
    for arg in "${@}"; do
        [[ "$arg" == "--watch" ]] && watch_mode=1
        [[ "$arg" == "--wide" ]]  && wide_mode=1
    done

    _show_stats_wide() {
        printf "\n${WHT}%-25s %-8s %-10s %-8s  %-12s %-12s %-8s %-8s %-8s${NC}\n" \
            "WWN" "ISP" "State" "Speed" "TX Frames" "RX Frames" "LnkFail" "LossSig" "BadCRC"
        printf "${DIM}%s${NC}\n" "$(printf '─%.0s' {1..110})"
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
                local init_wwn ac rc wc rk wk
                init_wwn=$(basename "$sess_path")
                ac=$(hex_to_dec "$(sysfs_read "${sess_path}/active_commands")")
                rc=$(hex_to_dec "$(sysfs_read "${sess_path}/read_cmd_count")")
                wc=$(hex_to_dec "$(sysfs_read "${sess_path}/write_cmd_count")")
                rk=$(hex_to_dec "$(sysfs_read "${sess_path}/read_io_count_kb")")
                wk=$(hex_to_dec "$(sysfs_read "${sess_path}/write_io_count_kb")")
                printf "  ${GRN}[%d]${NC} %-23s %8s %10s %8s  R:%-10s W:%-10s IO: R:%-8s W:%-8s\n" \
                    "$i" "$init_wwn" "" "sess" "act:${ac}" "${rc}cmd" "${wc}cmd" "${rk}KB" "${wk}KB"
                i=$((i + 1))
            done
        done
    }

    _show_stats_detail() {
        clear
        echo -e "${WHT}qle_adm stats${NC}  $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "${DIM}$(printf '─%.0s' {1..60})${NC}"
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
                echo -e "\n  ${GRN}[${si}] Session:${NC} ${init_wwn}"
                printf "    %-20s %d\n" "Active Commands:"  "$ac"
                printf "    %-20s %d\n" "Total Commands:"   "$cmds"
                printf "    %-20s %d cmds  /  %d KB\n" "Read:"  "$rc" "$rk"
                printf "    %-20s %d cmds  /  %d KB\n" "Write:" "$wc" "$wk"
                si=$((si + 1))
            done
        done
        [[ $watch_mode -eq 1 ]] && echo -e "\n${DIM}Refreshing every ${WATCH_INTERVAL}s — Ctrl+C to stop${NC}"
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
            hdr "Stored Firmware"
            local found=0
            for isp_dir in "${FIRMWARE_DIR}"/*/; do
                [[ -d "$isp_dir" ]] || continue
                local isp; isp=$(basename "$isp_dir")
                local fw_file="${ISP_FW_FILE[$isp]:-}"
                local stored="${isp_dir}/${fw_file}"
                if [[ -f "$stored" ]]; then
                    local ver; ver=$(strings "$stored" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
                    local sz; sz=$(du -h "$stored" | awk '{print $1}')
                    echo -e "  ${WHT}${isp}${NC}  ${fw_file}  version ${CYN}${ver}${NC}  ${sz}"
                    found=$((found + 1))
                fi
            done
            [[ $found -eq 0 ]] && echo -e "  ${DIM}(none stored)${NC}" || true
            ;;
        add)
            local isp_type="${1:-}" fw_path="${2:-}"
            [[ -z "$isp_type" || -z "$fw_path" ]] && { err "Usage: fw add <ISP_TYPE> <file>"; return 1; }
            [[ ! -f "$fw_path" ]] && { err "File not found: ${fw_path}"; return 1; }
            local fw_file="${ISP_FW_FILE[$isp_type]:-}"
            [[ -z "$fw_file" ]] && { err "Unknown ISP type: ${isp_type}. Known: ${!ISP_FW_FILE[*]}"; return 1; }
            local ver; ver=$(strings "$fw_path" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
            info "Adding ${isp_type} firmware version ${ver}"
            mkdir_v "${FIRMWARE_DIR}/${isp_type}"
            copy_v "$fw_path" "${FIRMWARE_DIR}/${isp_type}/${fw_file}"
            ok "Stored ${isp_type} firmware ${ver} ${SYM_INFO} ${FIRMWARE_DIR}/${isp_type}/${fw_file}"
            ;;
        remove)
            local isp_type="${1:-}"
            [[ -z "$isp_type" ]] && { err "Usage: fw remove <ISP_TYPE>"; return 1; }
            local fw_file="${ISP_FW_FILE[$isp_type]:-}"
            rm_f_v "${FIRMWARE_DIR}/${isp_type}/${fw_file}"
            ok "Removed stored firmware for ${isp_type}"
            ;;
        save)
            local port_idx=""
            [[ "${1:-}" == "--port" ]] && { port_idx="${2:-}"; shift 2 || true; }
            hdr "Save Card Firmware"
            read -r _ host _ isp_type _ <<< "$(detect_hbas | { [[ -n "$port_idx" ]] && sed -n "$((port_idx+1))p" || head -1; })"
            local fw_file="${ISP_FW_FILE[$isp_type]:-}"
            [[ -z "$fw_file" ]] && { err "Unknown ISP type: ${isp_type}"; return 1; }
            local dest="${FIRMWARE_DIR}/${isp_type}/${fw_file}"
            local optrom_path="/sys/class/scsi_host/${host}/device/optrom"
            local optrom_ctl="/sys/class/scsi_host/${host}/device/optrom_ctl"
            [[ ! -f "$optrom_ctl" ]] && { err "optrom_ctl sysfs not found: ${optrom_ctl}"; return 1; }
            info "Reading optrom from ${host} (${isp_type})..."
            mkdir_v "${FIRMWARE_DIR}/${isp_type}"
            if [[ $DRY_RUN -eq 0 ]]; then
                # Enable optrom read mode
                echo 1 > "$optrom_ctl" 2>/dev/null || { err "Failed to enable optrom read mode"; return 1; }
                sleep 1
                dd if="$optrom_path" of="$dest" bs=4096 2>/dev/null
                # Release optrom
                echo 0 > "$optrom_ctl" 2>/dev/null || true
                local sz; sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
                [[ "$sz" -eq 0 ]] && { err "Optrom read returned empty — driver may not support optrom extraction on this build"; rm -f "$dest"; return 1; }
                local ver; ver=$(strings "$dest" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
                ok "Saved ${isp_type} optrom firmware ${ver} ${SYM_INFO} ${dest}  (${sz} bytes)"
            else
                info "[DRY-RUN] would: echo 1 > ${optrom_ctl} && dd ${optrom_path} ${SYM_INFO} ${dest} && echo 0 > ${optrom_ctl}"
            fi
            ;;
        show)
            local port_idx=""
            [[ "${1:-}" == "--port" ]] && { port_idx="${2:-}"; shift 2 || true; }
            hdr "Card Firmware Versions"
            detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
                [[ -n "$port_idx" && "$idx" != "$port_idx" ]] && continue
                local scsi_host="/sys/class/scsi_host/${host}"
                local optrom_ver; optrom_ver=$(cat "${scsi_host}/optrom_fw_version" 2>/dev/null | awk '{print $1}' || echo "n/a")
                local primary_ver; primary_ver=$(cat "${scsi_host}/optrom_gold_fw_version" 2>/dev/null | awk '{print $1}' || echo "not exposed by driver")
                local fw_file="${ISP_FW_FILE[$isp]:-}"
                local stored="${FIRMWARE_DIR}/${isp}/${fw_file}"
                local stored_ver=""
                [[ -f "$stored" ]] && stored_ver=$(strings "$stored" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
                local lbl; lbl=$(wwn_label "$wwn" "target")
                local fwbin_val; fwbin_val=$(cat /sys/module/qla2xxx_scst/parameters/ql2xfwloadbin 2>/dev/null || \
                    cat /sys/module/qla2xxx/parameters/ql2xfwloadbin 2>/dev/null || echo "?")
                local fwbin_label
                case "$fwbin_val" in
                    0) fwbin_label="primary flash" ;;
                    1) fwbin_label="optrom" ;;
                    2) fwbin_label="filesystem" ;;
                    *) fwbin_label="unknown" ;;
                esac
                echo -e "\n  ${WHT}[${idx}] ${host}${NC} — ${isp}  ${wwn} (${CYN}${lbl}${NC})"
                echo -e "    Running  : ${fw}"
                echo -e "    Primary  : ${primary_ver}"
                echo -e "    Optrom   : ${optrom_ver}"
                if [[ -n "$stored_ver" ]]; then
                    local match_ind=""
                    [[ "$stored_ver" == "$optrom_ver" ]] && match_ind=" ${GRN}${SYM_OK} matches optrom${NC}"
                    echo -e "    Stored   : ${stored_ver}${match_ind}"
                else
                    echo -e "    Stored   : ${DIM}none${NC}"
                fi
                echo -e "    Load src : ql2xfwloadbin=${fwbin_val} (${fwbin_label})"
            done
            ;;
        status)
            hdr "Firmware Status"
            detect_hbas | while read -r idx host pci isp wwn fw state ptype; do
                local scsi_host="/sys/class/scsi_host/${host}"
                local optrom_ver; optrom_ver=$(cat "${scsi_host}/optrom_fw_version" 2>/dev/null | awk '{print $1}' || echo "n/a")
                local fw_file="${ISP_FW_FILE[$isp]:-}"
                local stored="${FIRMWARE_DIR}/${isp}/${fw_file}"
                local stored_ver=""
                [[ -f "$stored" ]] && stored_ver=$(strings "$stored" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
                local lbl; lbl=$(wwn_label "$wwn" "target")
                local sync_ind=""
                if [[ -n "$stored_ver" ]]; then
                    [[ "$stored_ver" == "$optrom_ver" ]] && sync_ind="${GRN}${SYM_OK}${NC}" || sync_ind="${YLW}${SYM_WARN}${NC}"
                else
                    sync_ind="${DIM}—${NC}"
                fi
                echo -e "  ${sync_ind} ${host}  ${isp}  ${wwn} (${CYN}${lbl}${NC})  running=${fw}  optrom=${optrom_ver}  stored=${stored_ver:-none}"
            done
            ;;
        flash)
            local slot="" port_idx="" fw_src="" do_yes=0
            while [[ $# -gt 0 ]]; do
                case "${1:-}" in
                    --slot)  slot="${2:-}";     shift 2 ;;
                    --port)  port_idx="${2:-}"; shift 2 ;;
                    --file)  fw_src="${2:-}";   shift 2 ;;
                    --yes)   do_yes=1;          shift ;;
                    *)       shift ;;
                esac
            done
            [[ -z "$slot" ]] && { err "Usage: fw flash --slot <primary|optrom> [--port N] [--file <path>] [--yes]"; return 1; }
            [[ "$slot" != "primary" && "$slot" != "optrom" ]] && { err "Slot must be 'primary' or 'optrom'"; return 1; }

            echo -e "\n${CYN}Preflight:${NC}"

            # 1 — flash tool
            local flash_bin; flash_bin=$(command -v "$FLASH_TOOL" 2>/dev/null || echo "")
            if [[ -z "$flash_bin" ]]; then
                err "Flash tool '${FLASH_TOOL}' not found in PATH"
                err "Install it or set FLASH_TOOL= at the top of qle_adm.sh"
                return 1
            fi
            ok "Flash tool: ${flash_bin}"

            # 2 — detect port
            read -r _ host _ isp_type _ <<< "$(detect_hbas | { [[ -n "$port_idx" ]] && sed -n "$((port_idx+1))p" || head -1; })"
            ok "Target port: ${host} (${isp_type})"

            # 3 — source file
            local fw_file="${ISP_FW_FILE[$isp_type]:-}"
            [[ -z "$fw_src" ]] && fw_src="${FIRMWARE_DIR}/${isp_type}/${fw_file}"
            [[ ! -f "$fw_src" ]] && { err "Firmware file not found: ${fw_src}  (run 'fw save' first or use --file)"; return 1; }
            ok "Source: ${fw_src}"

            # 4 — firmware version
            local ver; ver=$(strings "$fw_src" | grep -i 'Version' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
            ok "Firmware version: ${ver}"

            # 5 — primary slot warning
            if [[ "$slot" == "primary" ]]; then
                warn "Flashing PRIMARY slot modifies the base recovery image"
                warn "Ensure optrom contains a valid backup before proceeding"
            fi

            # Summary
            local scsi_host="/sys/class/scsi_host/${host}"
            local current_ver; current_ver=$(cat "${scsi_host}/optrom_fw_version" 2>/dev/null | awk '{print $1}' || echo "?")
            echo -e "\n  Card    : ${host} (${isp_type})"
            echo -e "  Slot    : ${slot}"
            echo -e "  Current : ${current_ver}"
            echo -e "  New     : ${ver}"

            # 6 — confirmation
            if [[ $do_yes -eq 0 ]]; then
                echo -e "\n${YLW}Proceed with flash? [y/N]${NC} \c"
                read -r answer
                [[ "$answer" != "y" && "$answer" != "Y" ]] && { info "Aborted"; return 0; }
            fi

            # Flash
            info "Flashing ${slot} on ${host}..."
            if [[ $DRY_RUN -eq 0 ]]; then
                "$flash_bin" --slot "$slot" --port "$host" "$fw_src"
                local rc=$?
                [[ $rc -ne 0 ]] && { err "Flash tool exited with code ${rc}"; return 1; }
                ok "Flash complete — reload module to verify new firmware"
            else
                info "[DRY-RUN] would run: ${flash_bin} --slot ${slot} --port ${host} ${fw_src}"
            fi
            ;;
        *) err "Unknown fw subcommand: ${subcmd}" ;;
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
            ;;
        set)
            # isp-params set <ISP> [--profile <name>] <params>
            local isp_type="${1:-}"; shift || true
            local profile="default"
            [[ "${1:-}" == "--profile" ]] && { profile="${2:-default}"; shift 2 || true; }
            local params="${*}"
            [[ -z "$isp_type" || -z "$params" ]] && {
                err "Usage: isp-params set <ISP_TYPE> [--profile <name>] '<params>'"
                return 1
            }
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

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    local w; w=$(terminal_width)
    local sep; sep=$(printf '─%.0s' $(seq 1 "$w"))
    printf "%b\n" "$(cat << USAGE_EOF

${WHT}qle_adm.sh${NC} v${VERSION} — QLogic FC Target Manager for TrueNAS SCALE
${DIM}${sep}${NC}
Deployment   : install  uninstall  repair
Operation    : setup [--boot]  teardown  apply  save
               clear <seen|ports|mappings|names|all>
Status       : status  hba-info  stats [--watch|--wide]  list-all
               list-ports  list-extents  list-initiators [--seen]  list-assignments
Port         : port enable|disable  <wwn>|--port N
LUN Mapping  : open  close  assign  unassign
Firmware     : fw list|add|remove|save|show|status|flash
Config       : isp-params list|set|use|del
WWN Names    : name list|set|get|del
Options      : help  examples  version
               --dry-run  --yes  --verbose  --home <path>
               --port N  --init N  --ext N
${DIM}${sep}${NC}
${DIM}Config: ${QLE_ADM_HOME}/config.json  |  Log: ${LOG}${NC}

USAGE_EOF
)"
}
cmd_help() {
    printf "%b\n" "$(cat << HELP_EOF

${WHT}qle_adm.sh${NC} v${VERSION} — QLogic FC Target Manager for TrueNAS SCALE

${WHT}IMPORTANT:${NC} Set QLE_ADM_HOME to a persistent dataset under /mnt before use:
  QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes install

${CYN}Deployment:${NC}
  install                        Deploy systemd units and modprobe config
  uninstall                      Remove all installed components
  repair                         Fix missing components after upgrade/BE change

${CYN}Operation:${NC}
  setup [--boot]                 Load modules, apply firmware overlay, activate targets
  teardown                       Deactivate targets, unload qla2xxx_scst, revert to initiator
  apply                          Re-apply config.json to running SCST without full reload
  save                           Record currently connected initiators to config.json
  clear <seen|ports|mappings|names|all>
                                 Clear accumulated operational state from config and sysfs

${CYN}Status:${NC}
  status                         Full state: modules, ports, sessions, gap analysis
  hba-info                       Per-port detail: ISP type, firmware, PCI link, WWN
  stats [--watch] [--wide]       Live IO counters; --watch refreshes every 2s
  list-ports                     FC ports with managed/unmanaged state and index [N]
  list-extents                   SCST extents with size, open/assigned state, index [N]
  list-initiators [--seen]       Connected initiators with IO stats; --seen adds history
  list-assignments               Per-initiator LUN mappings
  list-all                       Runs all four list commands in sequence

${CYN}Port Management:${NC}
  port enable  <wwn>|--port N    Write enabled=1 to SCST sysfs, save to config
  port disable <wwn>|--port N    Write enabled=0, remove from config

${CYN}LUN Mapping:${NC}
  open  <extent>|--ext N         Map extent to default group (all initiators), LUN auto
  close <extent>|--ext N         Remove from default group
  assign   <extent>|--ext N  <wwn>|--init N  [lun]
                                 Map extent to a specific initiator's group
  unassign <extent>|--ext N  <wwn>|--init N
                                 Remove per-initiator mapping

${CYN}Firmware:${NC}
  fw list                        List firmware files in ${FIRMWARE_DIR}
  fw add <ISP> <file>            Copy file into firmware store
  fw remove <ISP>                Remove stored file for ISP type
  fw save [--port N]             Read optrom via optrom_ctl sysfs → save to store
  fw show [--port N]             Per-port: running, primary, optrom, stored versions
  fw status                      One-line summary per port with sync indicator
  fw flash --slot <primary|optrom> [--port N] [--file <path>] [--yes]
                                 Flash stored (or --file) firmware to card slot
                                 Requires FLASH_TOOL (default: qlflash) in PATH

${CYN}Configuration:${NC}
  isp-params list                Show all ISP profiles; marks active (*) and detected
  isp-params set <ISP> [--profile <name>] '<params>'
                                 Create or update a named parameter profile
  isp-params use <ISP> --profile <name>
                                 Set active profile (used on next setup/reload)
  isp-params del <ISP> [--profile <name>]
                                 Delete a profile, or entire ISP entry if no --profile

${CYN}WWN Names:${NC}
  name list                      All named WWNs with role and port index
  name set <wwn> <name> [--port N]
                                 Assign friendly name; port auto-detected for local HBA ports
  name get <wwn>                 Show name entry for a WWN
  name del <wwn>                 Remove name entry

${CYN}Global Options:${NC}
  --dry-run                      Print actions without executing any writes
  --yes                          Skip all interactive confirmations
  --verbose                      Extra diagnostic output
  --home <path>                  Override QLE_ADM_HOME for this invocation

${CYN}Index Selection:${NC}
  --port N     FC port by index from list-ports
  --init N     Initiator by index from list-initiators (active or seen)
  --ext N      Extent by index from list-extents
  Mixing a positional WWN/name with --port/--init/--ext is an error.

${CYN}Subcommands:${NC}
  version                        Print version string and exit
  help                           This detailed help
  examples                       Common workflow examples

${DIM}Config: ${QLE_ADM_HOME}/config.json
Log:    ${LOG}
Flash:  ${FLASH_TOOL}${NC}

HELP_EOF
)"
}

cmd_examples() {
    # Full-width section heading helper
    exhdr() {
        local title=" $* "
        local w; w=$(terminal_width)
        local tlen=${#title}
        local remain=$(( w - tlen - 2 ))
        local left=$(( remain / 2 ))
        local right=$(( remain - left ))
        local lbar="" rbar="" i=0
        while [[ $i -lt $left  ]]; do lbar+="${SYM_HBAR}"; i=$((i+1)); done
        i=0
        while [[ $i -lt $right ]]; do rbar+="${SYM_HBAR}"; i=$((i+1)); done
        echo -e "${CYN}${lbar}${title}${rbar}${NC}"
    }

    echo ""
    echo -e "${WHT}qle_adm.sh${NC} v${VERSION} — Examples"
    echo ""

    exhdr "First-time install"
    cat << 'EX'

  # Deploy boot service and modprobe config
  QLE_ADM_HOME=/mnt/tank/admin/qle_adm ./qle_adm.sh --yes install

  # Verify state after install
  ./qle_adm.sh status
EX

    exhdr "Bring up a target port and map a LUN"
    cat << 'EX'

  # See available ports and extents
  ./qle_adm.sh list-all

  # Enable port 0 as FC target
  ./qle_adm.sh port enable --port 0

  # Expose an extent to all initiators (open access)
  ./qle_adm.sh open --ext 0

  # Or assign to a specific initiator only
  ./qle_adm.sh assign --ext 0 --init 0
EX

    exhdr "Name your ports and initiators"
    cat << 'EX'

  # Name local target ports (port index auto-detected from PCI function)
  ./qle_adm.sh name set 51:40:2e:c0:01:7b:cf:a8 nas0
  ./qle_adm.sh name set 51:40:2e:c0:01:7b:cf:aa nas0

  # Name remote initiator ports (first port defaults to :0, second :1)
  ./qle_adm.sh name set 51:40:2e:c0:01:7b:cf:60 vostro
  ./qle_adm.sh name set 51:40:2e:c0:01:7b:cf:62 vostro

  # Verify
  ./qle_adm.sh name list
  ./qle_adm.sh list-initiators
EX

    exhdr "Firmware management"
    cat << 'EX'

  # Save optrom firmware from card to store
  ./qle_adm.sh fw save

  # Verify what was saved
  ./qle_adm.sh fw list
  ./qle_adm.sh fw show

  # Add a firmware file manually
  ./qle_adm.sh fw add ISP2532 ~/ql2500_fw_8.08.207.bin

  # Flash stored firmware to card (requires qlflash)
  ./qle_adm.sh fw flash --slot primary --yes
EX

    exhdr "ISP parameter profiles"
    cat << 'EX'

  # View current profiles and applied vs configured state
  ./qle_adm.sh isp-params list

  # Add a filesystem-firmware profile
  ./qle_adm.sh isp-params set ISP2532 --profile fs \
    "qlini_mode=dual ql2xfc2target=1 ql2xnvmeenable=0 ql2xfwloadbin=2"

  # Switch active profile
  ./qle_adm.sh isp-params use ISP2532 --profile fs
EX

    exhdr "Monitoring"
    cat << 'EX'

  # Live IO stats (refreshes every 2s)
  ./qle_adm.sh stats --watch

  # Wide format (one line per port)
  ./qle_adm.sh stats --wide

  # Full status with gap analysis
  ./qle_adm.sh status
EX

    exhdr "Dry-run any operation"
    cat << 'EX'

  ./qle_adm.sh --dry-run setup
  ./qle_adm.sh --dry-run fw save
  ./qle_adm.sh --dry-run assign --ext 0 --init 0
EX
    echo ""
}
# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    local args=()
    local opt_port="" opt_init="" opt_ext=""

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
            --init)     opt_init="$2"; shift 2 ;;
            --ext)      opt_ext="$2"; shift 2 ;;
            --seen)     args+=("--seen"); shift ;;
            --watch)    args+=("--watch"); shift ;;
            --wide)     args+=("--wide"); shift ;;
            --boot)     args+=("--boot"); shift ;;
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

    case "$cmd" in
        install)         cmd_install ;;
        uninstall)       cmd_uninstall ;;
        repair)          cmd_repair ;;
        setup)           cmd_setup "${rest[@]}" ;;
        teardown)        cmd_teardown ;;
        apply)           cmd_apply ;;
        save)            cmd_save ;;
        clear)           cmd_clear "${rest[@]}" ;;
        status)          cmd_status ;;
        hba-info)        cmd_hba_info ;;
        stats)           cmd_stats "${rest[@]}" ;;
        list-ports)      cmd_list_ports ;;
        list-extents)    cmd_list_extents ;;
        list-initiators) cmd_list_initiators "${rest[@]}" ;;
        list-assignments) cmd_list_assignments ;;
        list-all)        cmd_list_all ;;
        port)
            local sub="${rest[0]:-}"
            local pos="${rest[1]:-}"
            [[ "$sub" == "enable" ]]  && cmd_port_enable  "$pos" "$opt_port"
            [[ "$sub" == "disable" ]] && cmd_port_disable "$pos" "$opt_port"
            ;;
        open)    cmd_open    "${rest[0]:-}" "$opt_ext" ;;
        close)   cmd_close   "${rest[0]:-}" "$opt_ext" ;;
        assign)  cmd_assign  "${rest[0]:-}" "$opt_ext" "${rest[1]:-}" "$opt_init" "${rest[2]:-auto}" ;;
        unassign) cmd_unassign "${rest[0]:-}" "$opt_ext" "${rest[1]:-}" "$opt_init" ;;
        fw)         cmd_fw         "${rest[@]}" ;;
        isp-params) cmd_isp_params "${rest[@]}" ;;
        name)       cmd_name       "${rest[@]}" ;;
        *) err "Unknown command: ${cmd}"; usage; exit 1 ;;
    esac
}

main "$@"
