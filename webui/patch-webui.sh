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
       unreachable). A definite answer rather than a guess based on a timer. */
    function probePanel() {
        return fetch(panelBase() + '/healthz', {mode: 'no-cors', cache: 'no-store'})
            .then(function () { return true; })
            .catch(function () { return false; });
    }

    function showCertHelp(url) {
        Ext.Msg.show({
            title: 'One-time certificate step',
            message:
                'The control panel runs on port ' + OPEN_PORT + ', which your browser ' +
                'treats as a separate site from the Proxmox UI.<br><br>' +
                'Your node uses a self-signed certificate, so that site has to be ' +
                'approved once.<br><br>' +
                '<b>Click OK</b> to open it in a new tab, accept the warning, then ' +
                'close the tab and try again.<br><br>' +
                '<span style="opacity:.75">To remove this step permanently, set up ACME ' +
                'under Datacenter &rarr; ACME, or install the Proxmox root CA on this ' +
                'computer. Either also removes the warning on the Proxmox UI itself.</span>',
            buttons: Ext.Msg.OKCANCEL,
            fn: function (btn) {
                if (btn === 'ok') { window.open(url, '_blank', 'noopener'); }
            }
        });
    }

    function openWindow(title, url) {
        var win = Ext.create('Ext.window.Window', {
            title: title,
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

    function openPanel(title, url) {
        probePanel().then(function (reachable) {
            if (reachable) { openWindow(title, url); } else { showCertHelp(url); }
        });
    }

    /* ---- Last-run status, used to colour the node button ----
       Requires credentials, so the panel returns CORS headers scoped to this
       exact host. A failure here is silent: a missing status dot must never
       interfere with the Proxmox UI. */
    var statusCache = {value: null, fetched: 0};

    function fetchStatus() {
        var now = Date.now();
        if (statusCache.value && (now - statusCache.fetched) < 25000) {
            return Promise.resolve(statusCache.value);
        }
        return fetch(panelBase() + '/api/state', {
            credentials: 'include', cache: 'no-store'
        }).then(function (r) {
            return r.ok ? r.json() : null;
        }).then(function (data) {
            statusCache = {value: data, fetched: Date.now()};
            return data;
        }).catch(function () { return null; });
    }

    function applyStatus(btn) {
        if (!btn || btn.destroyed) { return; }
        fetchStatus().then(function (state) {
            if (!state || !btn.getEl || btn.destroyed) { return; }
            var el = btn.getEl();
            if (!el) { return; }
            var result = (state.last_run && state.last_run.result) || '';
            var colour = '', tip = 'Never run';
            if (state.running) {
                colour = '#ffb300'; tip = 'Update running now';
            } else if (result.indexOf('error') === 0) {
                colour = '#f44336';
                tip = 'Last run reported errors' +
                      (state.last_run.finished ? ' (' + state.last_run.finished + ')' : '');
            } else if (result.indexOf('ok') === 0) {
                colour = '#4caf50';
                tip = 'Last run OK' +
                      (state.last_run.finished ? ' (' + state.last_run.finished + ')' : '');
            }
            if (state.repeat_offenders) {
                tip += '\nRepeatedly failing: ' + state.repeat_offenders;
            }
            var dom = el.dom.querySelector('.pau-dot');
            if (!dom && colour) {
                var span = document.createElement('span');
                span.className = 'pau-dot';
                span.style.cssText = 'display:inline-block;width:8px;height:8px;' +
                    'border-radius:50%;margin-left:6px;vertical-align:middle';
                var label = el.dom.querySelector('.x-btn-inner');
                (label || el.dom).appendChild(span);
                dom = span;
            }
            if (dom) { dom.style.background = colour || 'transparent'; }
            btn.setTooltip(tip);
        });
    }

    /* ---- Toolbar buttons ----
       The button is added to the toolbar of whichever Config panel is on screen:
       the node's (Reboot / Shutdown / Shell ...) or a guest's (Start / Shutdown /
       Console ...). It is styled by copying ui/scale/baseCls off a button already
       in that toolbar, so it matches its neighbours instead of rendering as flat
       text the way a bare xtype:'button' does. */
    function siblingStyle(tb) {
        var items = tb.query('button');
        for (var i = 0; i < items.length; i++) {
            var b = items[i];
            if (b.itemId === 'pauBtn') { continue; }
            return {
                ui: b.ui,
                scale: b.scale,
                baseCls: b.baseCls,
                cls: b.cls
            };
        }
        return {};
    }

    /* Windows guests are updated by the scheduled run only, so no button. The
       tree record does not carry ostype, so ask the API once per vmid and
       remember the answer. */
    var ostypeCache = {};

    function withOsType(node, vmid, cb) {
        var key = node + '/' + vmid;
        if (ostypeCache[key] !== undefined) { cb(ostypeCache[key]); return; }
        Proxmox.Utils.API2Request({
            url: '/nodes/' + node + '/qemu/' + vmid + '/config',
            method: 'GET',
            success: function (resp) {
                var t = (resp.result && resp.result.data && resp.result.data.ostype) || '';
                ostypeCache[key] = t;
                cb(t);
            },
            failure: function () { ostypeCache[key] = ''; cb(''); }
        });
    }

    function addButton(tb, cfg) {
        var style = siblingStyle(tb);
        var btn = tb.insert(0, Ext.apply({
            xtype: 'button',
            itemId: 'pauBtn',
            text: cfg.text,
            iconCls: 'fa fa-refresh',
            tooltip: cfg.tooltip,
            handler: function () { openPanel(cfg.title, cfg.url); }
        }, style));
        tb.updateLayout();
        if (cfg.status) {
            applyStatus(btn);
            var task = Ext.TaskManager.start({
                interval: 30000,
                run: function () {
                    if (btn.destroyed) { return false; }
                    applyStatus(btn);
                    return true;
                }
            });
            btn.on('destroy', function () { Ext.TaskManager.stop(task); });
        }
        return btn;
    }

    /* Both the outer Config panel and the content panel inside it carry
       pveSelNode, so decorating everything that matches produced two buttons —
       one stranded up in the breadcrumb bar. Take the outermost match only. */
    function outermostConfig() {
        var panels = Ext.ComponentQuery.query('panel[pveSelNode]');
        var visible = [];
        for (var i = 0; i < panels.length; i++) {
            if (panels[i].rendered && panels[i].isVisible()) { visible.push(panels[i]); }
        }
        for (var a = 0; a < visible.length; a++) {
            var nested = false;
            for (var b = 0; b < visible.length; b++) {
                if (a !== b && visible[a].isDescendantOf &&
                    visible[a].isDescendantOf(visible[b])) { nested = true; break; }
            }
            if (!nested) { return visible[a]; }
        }
        return null;
    }

    /* Where the button belongs: the toolbar of the content panel currently on
       screen — the row inside the viewport, below the breadcrumb. The Config
       panel's own tbar is the breadcrumb row (title on the left, Reboot /
       Shutdown / Shell on the right), which is not where it was wanted.

       Falls back to that outer bar only when the selected view has no toolbar
       of its own, so there is always a button somewhere rather than none. */
    function chooseToolbar(cfg) {
        var inner = (typeof cfg.getActiveTab === 'function') ? cfg.getActiveTab() : null;
        if (inner && inner.rendered && inner.getDockedItems) {
            var bars = inner.getDockedItems('toolbar[dock="top"]');
            for (var i = 0; i < bars.length; i++) {
                if (bars[i].rendered) { return bars[i]; }
            }
        }
        var outer = cfg.getDockedItems ? cfg.getDockedItems('toolbar[dock="top"]') : [];
        for (var j = 0; j < outer.length; j++) {
            if (outer[j].rendered &&
                outer[j].query('button').length - outer[j].query('#pauBtn').length > 0) {
                return outer[j];
            }
        }
        return null;
    }

    /* One button, application-wide. Anything of ours outside the chosen toolbar
       is removed, which also cleans up buttons left by an earlier version. */
    function dedupe(keep) {
        var all = Ext.ComponentQuery.query('#pauBtn');
        for (var i = 0; i < all.length; i++) {
            var btn = all[i];
            if (btn.ownerCt === keep) { continue; }
            if (btn.ownerCt && btn.ownerCt.remove) {
                btn.ownerCt.remove(btn, true);
            } else if (btn.destroy) {
                btn.destroy();
            }
        }
    }

    function decorate(panel) {
        var rec = panel.pveSelNode;
        if (!rec || !rec.data) { return; }

        var tb = chooseToolbar(panel);
        if (!tb) { return; }
        dedupe(tb);
        if (tb.query('#pauBtn').length) { return; }

        var type = rec.data.type;
        var node = rec.data.node;
        var vmid = rec.data.vmid;

        if (type === 'node') {
            addButton(tb, {
                text: 'Update Everything',
                tooltip: 'Update this node and all its guests',
                title: 'Proxmox Auto-Update — ' + (rec.data.text || node),
                url: panelBase() + '/',
                status: true
            });
            return;
        }

        if (type !== 'lxc' && type !== 'qemu') { return; }
        if (!vmid) { return; }

        var name = rec.data.name || rec.data.text || ('guest ' + vmid);
        var add = function () {
            /* Re-check: the panel may have been swapped out while the ostype
               lookup was in flight. */
            if (!tb.rendered || tb.destroyed || tb.query('#pauBtn').length) { return; }
            addButton(tb, {
                text: 'Update Now',
                tooltip: 'Update only this guest. The host is not touched and no ' +
                         'reboot is scheduled.',
                title: 'Auto-Update — ' + name + ' (' + vmid + ')',
                url: panelBase() + '/guest?vmid=' + encodeURIComponent(vmid) +
                     '&name=' + encodeURIComponent(name),
                status: false
            });
        };

        if (type === 'qemu') {
            withOsType(node, vmid, function (ostype) {
                if (/^w/i.test(ostype)) { return; }   /* win*, wvista, w2k... */
                add();
            });
        } else {
            add();
        }
    }

    /* Config panels are created and destroyed as you click around the tree, so
       a one-shot override is not enough. A cheap periodic sweep is used instead:
       it works regardless of how or when Proxmox builds those panels, which
       matters because that construction differs between releases. */
    function install() {
        Ext.TaskManager.start({
            interval: 800,
            run: function () {
                try {
                    var cfg = outermostConfig();
                    if (cfg) {
                        decorate(cfg);
                    } else {
                        dedupe(null);   /* nothing selected — drop any leftovers */
                    }
                } catch (e) {
                    if (window.console) {
                        console.warn('proxmox-autoupdate: toolbar sweep failed', e);
                    }
                }
                return true;
            }
        });
    }

    Ext.onReady(function () { Ext.defer(install, 1200); });
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
