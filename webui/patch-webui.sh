#!/usr/bin/env bash
# ==============================================================================
# Adds an "Auto-Update" button to the Proxmox web UI toolbar, immediately to the
# left of the Documentation button.
#
# The patch is *append-only*. Rather than splicing into pve-manager's toolbar
# array literal — which differs between releases and is easy to corrupt — this
# appends a self-contained block that waits for the UI to render and then
# inserts the button through the ExtJS component API. Appending to the end of a
# JS file cannot break the code above it, and removal is an exact delete between
# two markers.
#
# pve-manager upgrades replace pvemanagerlib.js wholesale, so the button
# disappears until this is re-applied. install.sh registers an apt hook that
# re-runs `apply` automatically after any pve-manager upgrade.
#
# Usage: patch-webui.sh apply|remove|status
# ==============================================================================

set -uo pipefail

TARGET="/usr/share/pve-manager/js/pvemanagerlib.js"
BACKUP="/var/lib/proxmox-autoupdate/pvemanagerlib.js.orig"
CONFIG_FILE="/etc/proxmox-autoupdate.conf"
BEGIN_MARKER="/* ==== BEGIN proxmox-autoupdate button ==== */"
END_MARKER="/* ==== END proxmox-autoupdate button ==== */"

# The port the control panel listens on. Read from the config so the button and
# the service can never disagree; falls back to the default.
UI_PORT="8007"
if [ -r "${CONFIG_FILE}" ]; then
    CONFIGURED_PORT=$(sed -n 's/^[[:space:]]*WEB_UI_PORT[[:space:]]*=[[:space:]]*"\{0,1\}\([0-9]\{1,\}\)"\{0,1\}.*/\1/p' \
        "${CONFIG_FILE}" | tail -1)
    [ -n "${CONFIGURED_PORT}" ] && UI_PORT="${CONFIGURED_PORT}"
fi

# A string that must still be present after any edit, as a corruption canary.
SENTINEL="PVE.StdWorkspace"

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'; C_DIM='\033[2m'; C_NC='\033[0m'
ok()   { echo -e "  ${C_GREEN}✓${C_NC} $1"; }
fail() { echo -e "  ${C_RED}✗${C_NC} $1"; }
warn() { echo -e "  ${C_YELLOW}⚠${C_NC} $1"; }
act()  { echo -e "  ${C_CYAN}▶${C_NC} $1"; }

require_target() {
    if [ ! -f "${TARGET}" ]; then
        fail "Not found: ${TARGET}"
        fail "This does not look like a Proxmox VE node."
        exit 1
    fi
}

is_patched() {
    grep -qF "${BEGIN_MARKER}" "${TARGET}" 2>/dev/null
}

# The injected block. Kept in a function so both apply and the self-test can
# reach it without duplicating the source.
emit_block() {
    # Only the port is interpolated; the rest is literal.
    cat <<JSBLOCK_HEAD
/* ==== BEGIN proxmox-autoupdate button ==== */
/* Added by proxmox-autoupdate. Removed cleanly by patch-webui.sh remove.
   Re-applied automatically after pve-manager upgrades via an apt hook. */
(function () {
    if (typeof Ext === 'undefined') { return; }

    var OPEN_PORT = ${UI_PORT};
JSBLOCK_HEAD
    cat <<'JSBLOCK'

    function panelBase() {
        return 'https://' + window.location.hostname + ':' + OPEN_PORT;
    }

    /* Is the control panel's certificate already trusted by this browser?
       /healthz needs no authentication, so a no-cors fetch either resolves
       (opaque response => TLS handshake succeeded) or rejects (untrusted or
       unreachable). This is a definite answer rather than a guess based on a
       timer, and it costs one request. */
    function probePanel() {
        return fetch(panelBase() + '/healthz', {mode: 'no-cors', cache: 'no-store'})
            .then(function () { return true; })
            .catch(function () { return false; });
    }

    function showCertHelp() {
        var url = panelBase() + '/';
        Ext.Msg.show({
            title: 'One-time certificate step',
            message:
                'The control panel runs on port ' + OPEN_PORT + ', which your browser ' +
                'treats as a separate site from the Proxmox UI on this port.<br><br>' +
                'Your node is using a self-signed certificate, so that site has to be ' +
                'approved once.<br><br>' +
                '<b>Click OK</b> to open it in a new tab, accept the warning, then close ' +
                'the tab and click Auto-Update again.<br><br>' +
                '<span style="opacity:.75">To remove this step permanently, set up ACME ' +
                'under Datacenter &rarr; ACME, or install the Proxmox root CA on this ' +
                'computer. Either one also removes the warning on the Proxmox UI itself.</span>',
            buttons: Ext.Msg.OKCANCEL,
            fn: function (btn) {
                if (btn === 'ok') { window.open(url, '_blank', 'noopener'); }
            }
        });
    }

    function openPanel() {
        probePanel().then(function (reachable) {
            if (reachable) { openPanelWindow(); } else { showCertHelp(); }
        });
    }

    function openPanelWindow() {
        var url = panelBase() + '/';
        var win = Ext.create('Ext.window.Window', {
            title: 'Proxmox Auto-Update',
            width: Math.min(1100, Math.floor(window.innerWidth * 0.92)),
            height: Math.min(800, Math.floor(window.innerHeight * 0.9)),
            layout: 'fit',
            modal: true,
            maximizable: true,
            items: [{
                xtype: 'container',
                layout: 'fit',
                html: '<iframe src="' + url + '" style="width:100%;height:100%;border:0"' +
                      ' referrerpolicy="no-referrer"></iframe>'
            }],
            buttons: [{
                text: 'Open in new tab',
                handler: function () { window.open(url, '_blank', 'noopener'); }
            }, {
                text: 'Close',
                handler: function () { win.close(); }
            }]
        });
        win.show();
    }

    function buttonConfig() {
        return {
            xtype: 'button',
            itemId: 'pveAutoUpdateBtn',
            text: 'Auto-Update',
            iconCls: 'fa fa-refresh',
            margin: '0 5 0 0',
            handler: openPanel
        };
    }

    /* ---- Per-guest "Auto-Update" tab, added after Permissions ----
       PVE.qemu.Config and PVE.lxc.Config are already defined by the time this
       block is parsed (it is appended to the end of the same file), so they can
       be overridden directly. The item is added after callParent, once the
       panel's own items exist, so we never have to know how they were built.

       Everything is wrapped in try/catch: a Proxmox release that reshapes these
       panels should cost us the tab, not break the guest view entirely. */
    function addGuestTab(cfg, kind) {
        var rec = cfg.pveSelNode;
        if (!rec || !rec.data || !rec.data.vmid) { return; }
        var vmid = rec.data.vmid;
        var name = rec.data.name || '';
        var url = panelBase() + '/guest?vmid=' + encodeURIComponent(vmid) +
                  '&name=' + encodeURIComponent(name);

        cfg.add({
            xtype: 'panel',
            title: 'Auto-Update',
            itemId: 'pauGuestUpdate',
            iconCls: 'fa fa-refresh',
            border: false,
            layout: 'fit',
            bodyPadding: 0,
            html: '<div style="padding:12px;font:13px sans-serif">Checking control panel…</div>',
            listeners: {
                /* Probe on first activation rather than embedding blindly, so an
                   unaccepted certificate produces an explanation instead of a
                   blank panel. */
                activate: function (p) {
                    if (p.pauLoaded) { return; }
                    p.pauLoaded = true;
                    probePanel().then(function (reachable) {
                        if (reachable) {
                            p.update('<iframe src="' + url +
                                     '" style="width:100%;height:100%;border:0"' +
                                     ' referrerpolicy="no-referrer"></iframe>');
                        } else {
                            p.pauLoaded = false;   /* let them retry after accepting */
                            p.update(
                                '<div style="padding:16px;font:13px/1.6 sans-serif">' +
                                '<b>One-time certificate step</b><br><br>' +
                                'The control panel runs on port ' + OPEN_PORT + ', which ' +
                                'your browser treats as a separate site and has not yet ' +
                                'been approved.<br><br>' +
                                '<a href="' + url + '" target="_blank" rel="noopener">' +
                                'Open it in a new tab</a>, accept the warning, then come ' +
                                'back to this tab.<br><br>' +
                                '<span style="opacity:.75">To remove this step for good, ' +
                                'set up ACME under Datacenter &rarr; ACME, or install the ' +
                                'Proxmox root CA on this computer.</span></div>');
                        }
                    });
                }
            }
        });
    }

    function overrideGuestConfig(cls, kind) {
        if (!cls) { return; }
        Ext.override(cls, {
            initComponent: function () {
                this.callParent(arguments);
                try {
                    addGuestTab(this, kind);
                } catch (e) {
                    if (window.console) {
                        console.warn('proxmox-autoupdate: could not add guest tab', e);
                    }
                }
            }
        });
    }

    try {
        overrideGuestConfig(PVE.qemu && PVE.qemu.Config, 'qemu');
        overrideGuestConfig(PVE.lxc && PVE.lxc.Config, 'lxc');
    } catch (e) {
        if (window.console) {
            console.warn('proxmox-autoupdate: guest config override failed', e);
        }
    }

    /* The toolbar is built during workspace render, which happens after login.
       Poll briefly for the Documentation button and insert just before it. */
    function install() {
        var attempts = 0;
        var task = Ext.TaskManager.start({
            interval: 500,
            run: function () {
                attempts++;
                if (attempts > 120) { return false; }   /* give up after ~60s */

                var doc = Ext.ComponentQuery.query('button[onlineHelp=pve_documentation_index]')[0];
                if (!doc) {
                    var candidates = Ext.ComponentQuery.query('toolbar button');
                    for (var i = 0; i < candidates.length; i++) {
                        if (candidates[i].text === 'Documentation') { doc = candidates[i]; break; }
                    }
                }
                if (!doc || !doc.ownerCt) { return true; }

                var tb = doc.ownerCt;
                if (tb.down('#pveAutoUpdateBtn')) { return false; }

                var idx = tb.items.indexOf(doc);
                if (idx < 0) { idx = 0; }
                tb.insert(idx, buttonConfig());
                tb.updateLayout();
                return false;
            }
        });
        return task;
    }

    Ext.onReady(function () { Ext.defer(install, 800); });
})();
/* ==== END proxmox-autoupdate button ==== */
JSBLOCK
}

do_apply() {
    require_target

    # Keep a pristine copy of whatever pve-manager shipped, for reference and
    # for a worst-case manual restore.
    mkdir -p "$(dirname "${BACKUP}")"
    if is_patched; then
        act "Existing patch found — replacing it"
        do_remove --quiet || return 1
    fi
    cp -f "${TARGET}" "${BACKUP}"

    local tmp
    tmp=$(mktemp) || { fail "mktemp failed"; return 1; }
    cat "${TARGET}" > "${tmp}"
    # Ensure the file ends with a newline so the block starts on its own line —
    # but do not add a blank one, or removing the block would not restore the
    # file byte for byte.
    if [ -s "${tmp}" ] && [ "$(tail -c 1 "${tmp}" | od -An -c | tr -d ' ')" != '\n' ]; then
        printf '\n' >> "${tmp}"
    fi
    emit_block >> "${tmp}"

    # Sanity-check before swapping it in.
    if ! grep -qF "${SENTINEL}" "${tmp}"; then
        fail "Refusing to install: result no longer contains ${SENTINEL}"
        rm -f "${tmp}"
        return 1
    fi
    if [ "$(wc -c < "${tmp}")" -lt "$(wc -c < "${TARGET}")" ]; then
        fail "Refusing to install: result is smaller than the original"
        rm -f "${tmp}"
        return 1
    fi

    cat "${tmp}" > "${TARGET}"
    rm -f "${tmp}"
    ok "Button added to the Proxmox toolbar"
    echo -e "     ${C_DIM}Hard-refresh the Proxmox UI (Ctrl+Shift+R) to see it.${C_NC}"
    return 0
}

do_remove() {
    local quiet="${1:-}"
    require_target

    if ! is_patched; then
        [ "${quiet}" = "--quiet" ] || warn "Not patched — nothing to remove"
        return 0
    fi

    local tmp
    tmp=$(mktemp) || { fail "mktemp failed"; return 1; }

    # Delete strictly between the markers, inclusive.
    awk -v b="${BEGIN_MARKER}" -v e="${END_MARKER}" '
        index($0, b) { skip = 1 }
        !skip        { print }
        index($0, e) { skip = 0 }
    ' "${TARGET}" > "${tmp}"

    if grep -qF "${BEGIN_MARKER}" "${tmp}" || grep -qF "${END_MARKER}" "${tmp}"; then
        fail "Removal left marker text behind — leaving the file untouched"
        rm -f "${tmp}"
        return 1
    fi
    if ! grep -qF "${SENTINEL}" "${tmp}"; then
        fail "Refusing to write: result no longer contains ${SENTINEL}"
        rm -f "${tmp}"
        return 1
    fi

    cat "${tmp}" > "${TARGET}"
    rm -f "${tmp}"
    [ "${quiet}" = "--quiet" ] || ok "Button removed from the Proxmox toolbar"
    return 0
}

do_status() {
    require_target
    if is_patched; then
        ok "Toolbar button is installed"
        return 0
    fi
    warn "Toolbar button is NOT installed"
    echo -e "     ${C_DIM}A pve-manager upgrade removes it; run '$0 apply' to restore.${C_NC}"
    return 1
}

case "${1:-}" in
    apply)  do_apply ;;
    remove) do_remove ;;
    status) do_status ;;
    *)
        echo "Usage: $0 apply|remove|status"
        exit 2
        ;;
esac
