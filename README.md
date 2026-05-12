# TrueNAS SCALE CE QLogic FC Target Manager

`qle_adm.sh` manages QLogic Fibre Channel HBAs as SCST targets on
TrueNAS SCALE Community Edition. It manages the configuration files
and boot sequencing that SCST and the kernel need to operate FC targets
correctly, and handles LUN mapping and persistent configuration across
reboots and boot environment changes.

---

## What it does

TrueNAS SCALE CE includes SCST and the `qla2xxx_scst` kernel module,
but the web UI only manages iSCSI - there is no FC target configuration
in the WUI. `qle_adm.sh` fills that gap:

- Manages `qla2xxx_scst` boot-time loading via one of three selectable
  boot modes (see below), ensuring correct module parameters are always
  in place before SCST starts
- Reconstructs the full FC target configuration in `/etc/scst.conf` before
  SCST starts - SCST reads it at startup to initialize all FC target state
- Maps ZFS volumes (extents) to initiators as FC LUNs via sysfs at runtime
- Persists all configuration in `config.json` across reboots and TrueNAS
  upgrades
- Provides status, diagnostics, and firmware management

---

## Boot modes

`qle_adm.sh` supports three boot modes, selectable at install time or
changed later with `deploy reconfigure`. The active mode is stored in
`config.json`.

| Mode | How params are applied | Module reload at boot | Firmware sources |
|------|------------------------|----------------------|-----------------|
| `reload` | PREINIT unloads and reloads `qla2xxx_scst` with correct params | Yes | HBA flash, OS dist, user-stored |
| `blacklist` | Module blacklisted at boot; PREINIT performs the first clean load | No | HBA flash, OS dist, user-stored |
| `grub` | Params delivered as `qla2xxx_scst.<param>=<val>` kernel cmdline tokens via TrueNAS middleware | No | HBA flash or OS dist only |

**`reload`** is the default and matches the behaviour of all previous releases.
If you are upgrading from an earlier version, no action is required.

**`blacklist`** and **`grub`** modes manage `kernel_extra_options` in TrueNAS
via `midclt`. Foreign tokens (unrelated to `qle_adm`) are always preserved
verbatim - `qle_adm` takes non-exclusive ownership of only its own tokens.
A before/after diff is shown and confirmed before any middleware write.

All three modes register a boot entry (TrueNAS Init/Shutdown Script) that
runs `sync --boot` before SCST starts - writing `/etc/scst.conf`, the
modprobe conf (where applicable), and the SCST ordering drop-in. The boot
entry survives boot environment changes and upgrades.

---

## Configuration model

`config.json` on `/mnt` is the single source of truth and survives all
TrueNAS lifecycle events. Two representations are derived from it:

**`/etc/scst.conf`** - rebuilt at boot and on `sync`. SCST reads this file
at startup to initialize all FC target state: enabled ports, rel_tgt_ids,
LUN mappings, and initiator groups.

**Live sysfs** - all runtime changes (port enable/disable, open, close,
assign, unassign) write directly to both sysfs and `config.json` atomically.
Active sessions are never disrupted by configuration changes to other targets.

The TrueNAS WUI rewrites `/etc/scst.conf` on every iSCSI save. Running
`sync` after a WUI save rebuilds the FC target block from `config.json`
without touching live sysfs state or active sessions.

> **Note:** At least one iSCSI target must exist in the WUI (Sharing →
> iSCSI → Targets) for TrueNAS to create `/etc/scst.conf`. The target
> name does not matter - its existence triggers file creation. Without it,
> `sync` will fail with "scst.conf not found" even if SCST is running.

---

## What you need

- **TrueNAS SCALE CE** (tested on 25.10.x, kernel 6.12)
- **QLogic ISP2532 or newer HBA** for confirmed target mode support. ISP2432
  target mode has not been achieved on kernel 6.12 - root cause unknown.
  ISP2432 works as an initiator.
- **SCST running**: verify with `systemctl is-active scst`
- **A ZFS zvol** registered as an SCST block device in `/etc/scst.conf`
- **A dataset under `/mnt`** for persistent storage of the script and config

> **Why `/mnt`?** TrueNAS `/etc` is a separate ZFS dataset that is
> BE-specific - it is replaced when you switch or upgrade a boot environment.
> Only datasets under `/mnt/<pool>/` survive all lifecycle events.

---

## Quick Start

Expose an existing ZFS extent to FC initiators without installing
`qle_adm.sh`. SCST must already be active - verify under System >
Services in the TrueNAS WUI.

```bash
git clone https://github.com/royasutton/tnsce-qle-adm.git

cd tnsce-qle-adm
export QLE_ADM_HOME=$(pwd)

chmod +x ./qle_adm.sh

# Inject FC target block into scst.conf
./qle_adm.sh sync

# If qla2xxx_scst is not yet loaded, load it now for this session.
# On subsequent boots the boot entry handles this automatically.
./qle_adm.sh module load

# Verify SCST, module, ports, and scst.conf block are all good
./qle_adm.sh status

# Map (open access) extent on a port for initiator access by index
./qle_adm.sh list-extents
./qle_adm.sh list-ports

./qle_adm.sh open --ext 0
./qle_adm.sh port enable --port 0

# Verify the mapping and confirm the initiator session is active
./qle_adm.sh list-assignments
./qle_adm.sh list-initiators
```

The initiator can now scan for and mount the block device. When you are
ready to make this configuration persistent across reboots, see
[Quick Install](#quick-install) below.

---

## Quick Install

```bash
# 1. Install to a persistent dataset.
#    Omit --yes to be prompted for boot mode (default: reload).
#    Use --mode to select a specific mode without prompting.
QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm ./qle_adm.sh --yes deploy install

# Or select a boot mode explicitly:
QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm ./qle_adm.sh deploy install --mode grub
QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm ./qle_adm.sh deploy install --mode blacklist
QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm ./qle_adm.sh deploy install --mode reload

# 2. Add to your shell startup script (~/.bashrc or ~/.zshrc) so
#    qle_adm.sh is available by name from any directory
export QLE_ADM_HOME=/mnt/<pool>/admin/qle_adm
PATH="${PATH}:${QLE_ADM_HOME}"

# 3. Inject FC target block into scst.conf
qle_adm.sh sync

# 4. If qla2xxx_scst is not yet loaded for this session, load it now.
#    On subsequent boots the boot entry handles the module lifecycle.
qle_adm.sh module load

# 5. Verify - confirm no gaps before proceeding
qle_adm.sh status

# 6. Identify the P2P port index
qle_adm.sh list-hba
qle_adm.sh list-ports

# 7. Enable the P2P target port (use index from list-ports)
qle_adm.sh port enable --port 1

# 8a. Expose a ZFS volume to all initiators
qle_adm.sh open --ext 0

# 8b. Or assign to a specific initiator only
qle_adm.sh assign --ext 0 --init 0

# 9. Verify
qle_adm.sh status
```

From this point the configuration is persistent. On every boot, a single
entry registered in the TrueNAS middleware database runs `sync --boot`
before SCST starts - writing `/etc/scst.conf`, the modprobe conf (where
applicable), and the SCST ordering drop-in. Module management at boot
depends on the selected mode. The boot entry survives BE changes and upgrades.

To switch boot modes at any time:

```bash
qle_adm.sh deploy reconfigure --mode grub
qle_adm.sh deploy status
```

---

## After an upgrade or boot environment change

```bash
qle_adm.sh sync --restart
```

Rebuilds scst.conf and restarts SCST. The boot entry survives upgrades
automatically - no reinstall needed. On the second and all subsequent
boots after a BE change, the boot entry restores everything before SCST
starts and the boot is fully automatic.

---

## When things break

**Link won't come up:**
```bash
qle_adm.sh status
qle_adm.sh list-hba
qle_adm.sh isp-params list
qle_adm.sh deploy status
```

**Block device not appearing on initiator:**
```bash
qle_adm.sh list-assignments
qle_adm.sh list-initiators
```

**After upgrade - targets not active:**
```bash
qle_adm.sh sync --restart
```

---

## Further reading

See **[GUIDE.md](GUIDE.md)** for complete documentation including full
command reference, boot mode selection, firmware management, ISP parameter
profiles, initiator setup, troubleshooting, and FAQ.

