#!/usr/bin/env bash
# ==============================================================================
# Adds Auto-Update buttons to the Proxmox web UI: "Update Everything" in the top
# toolbar beside Documentation, and "Update Now" between Start and Shutdown on
# each container and Linux VM.
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

    /* ---- Styling ----
       A bare xtype:'button' inherits whatever `ui` the surrounding toolbar
       implies and can render as flat text. The node button is deliberately
       Proxmox orange so it reads as an action rather than a label; the guest
       button copies its neighbours so it sits naturally beside Start. */
    function injectStyles() {
        if (document.getElementById('pau-style')) { return; }
        var el = document.createElement('style');
        el.id = 'pau-style';
        el.textContent = [
            '.pau-btn, .pau-btn .x-btn-button {',
            '  background-color: #e57000 !important;',
            '  background-image: none !important;',
            '}',
            '.pau-btn {',
            '  border: 1px solid #b35700 !important;',
            '  border-radius: 3px !important;',
            '}',
            '.pau-btn .x-btn-inner, .pau-btn .x-btn-icon-el {',
            '  color: #ffffff !important;',
            '  font-weight: 600 !important;',
            '}',
            '.pau-btn.x-btn-over, .pau-btn.x-btn-over .x-btn-button,',
            '.pau-btn:hover, .pau-btn:hover .x-btn-button {',
            '  background-color: #ff8c1a !important;',
            '}',
            '.pau-btn.x-btn-pressed, .pau-btn.x-btn-pressed .x-btn-button {',
            '  background-color: #c96200 !important;',
            '}',
            '.pau-dot {',
            '  display: inline-block; width: 8px; height: 8px;',
            '  border-radius: 50%; margin-left: 6px; vertical-align: middle;',
            '}'
        ].join('\n');
        document.head.appendChild(el);
    }

    /* ---- Certificate probe ----
       /healthz needs no authentication, so a no-cors fetch either resolves
       (opaque response => the TLS handshake succeeded) or rejects. A definite
       answer rather than a guess based on a timer. */
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

    /* ---- Last-run status for the node button ----
       Needs credentials, so the panel returns CORS headers scoped to this exact
       host. Failure here is silent: a missing status dot must never interfere
       with the Proxmox UI. */
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
            var colour = '', tip = 'Update this node and all its guests';
            if (state.running) {
                colour = '#ffe08a'; tip = 'Update running now';
            } else if (result.indexOf('error') === 0) {
                colour = '#ff5c5c'; tip = 'Last run reported errors';
            } else if (result.indexOf('ok') === 0) {
                colour = '#7bd88f'; tip = 'Last run completed cleanly';
            }
            if (state.last_run && state.last_run.finished) {
                tip += ' (' + state.last_run.finished + ')';
            }
            if (state.repeat_offenders) {
                tip += '\nRepeatedly failing: ' + state.repeat_offenders;
            }
            var dot = el.dom.querySelector('.pau-dot');
            if (!dot && colour) {
                dot = document.createElement('span');
                dot.className = 'pau-dot';
                var label = el.dom.querySelector('.x-btn-inner');
                (label || el.dom).appendChild(dot);
            }
            if (dot) { dot.style.background = colour || 'transparent'; }
            btn.setTooltip(tip);
        });
    }

    /* ================= Node button: top toolbar, beside Documentation =======
       Global rather than per-node: it updates the host and every guest, so it
       does not belong to whatever happens to be selected in the tree. */
    function installNodeButton() {
        var attempts = 0;
        Ext.TaskManager.start({
            interval: 500,
            run: function () {
                attempts++;
                if (attempts > 240) { return false; }
                try {
                    var doc = Ext.ComponentQuery.query(
                        'button[onlineHelp=pve_documentation_index]')[0];
                    if (!doc) {
                        var all = Ext.ComponentQuery.query('toolbar button');
                        for (var i = 0; i < all.length; i++) {
                            if (all[i].text === 'Documentation') { doc = all[i]; break; }
                        }
                    }
                    if (!doc || !doc.ownerCt) { return true; }

                    var tb = doc.ownerCt;
                    if (tb.query('#pauNodeBtn').length) { return false; }

                    var idx = tb.items.indexOf(doc);
                    if (idx < 0) { idx = 0; }
                    var btn = tb.insert(idx, {
                        xtype: 'button',
                        itemId: 'pauNodeBtn',
                        text: 'Update Everything',
                        iconCls: 'fa fa-refresh',
                        cls: 'pau-btn',
                        margin: '0 5 0 0',
                        handler: function () {
                            openPanel('Proxmox Auto-Update', panelBase() + '/');
                        }
                    });
                    tb.updateLayout();

                    applyStatus(btn);
                    Ext.TaskManager.start({
                        interval: 30000,
                        run: function () {
                            if (btn.destroyed) { return false; }
                            applyStatus(btn);
                            return true;
                        }
                    });
                    return false;
                } catch (e) {
                    if (window.console) {
                        console.warn('proxmox-autoupdate: node button failed', e);
                    }
                    return false;
                }
            }
        });
    }

    /* ================= Guest button: between Start and Shutdown ============= */

    /* Windows guests are updated by the scheduled run only. ostype is not on
       the tree record, so ask the API once per guest and remember the answer. */
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

    /* The toolbar holding Start / Shutdown / Console / More. */
    function guestToolbar(cfg) {
        var bars = cfg.getDockedItems ? cfg.getDockedItems('toolbar[dock="top"]') : [];
        for (var i = 0; i < bars.length; i++) {
            if (!bars[i].rendered) { continue; }
            if (bars[i].query('button').length - bars[i].query('#pauGuestBtn').length > 0) {
                return bars[i];
            }
        }
        return null;
    }

    /* Slot the button between Start and Shutdown. Matching on the Start button
       and taking the next slot keeps it correct whether or not the guest is
       running, and whatever else the release puts in that group. */
    function guestIndex(tb) {
        var items = tb.items ? tb.items.getRange() : [];
        var firstButton = -1;
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            if (it.itemId === 'pauGuestBtn') { continue; }
            var isBtn = it.isXType ? it.isXType('button') : it.xtype === 'button';
            if (!isBtn) { continue; }
            if (firstButton < 0) { firstButton = i; }
            if (/^\s*start\s*$/i.test(it.text || '')) { return i + 1; }
            if (/^\s*shutdown\s*$/i.test(it.text || '')) { return i; }
        }
        return firstButton >= 0 ? firstButton + 1 : items.length;
    }

    function siblingStyle(tb) {
        var items = tb.query('button');
        for (var i = 0; i < items.length; i++) {
            if (items[i].itemId === 'pauGuestBtn') { continue; }
            return {ui: items[i].ui, scale: items[i].scale, baseCls: items[i].baseCls};
        }
        return {};
    }

    /* Both the outer Config panel and the content panel inside it carry
       pveSelNode; decorating everything that matches produced two buttons. */
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

    /* One guest button, application-wide, in the right slot. Anything of ours
       that is elsewhere — or in the right toolbar but the wrong position, as
       left by an earlier version — is removed so it can be re-added correctly. */
    function reconcile(tb, wantIndex) {
        var all = Ext.ComponentQuery.query('#pauGuestBtn');
        var keep = null;
        for (var i = 0; i < all.length; i++) {
            var btn = all[i];
            var here = tb && btn.ownerCt === tb;
            var atRightSlot = here && tb.items.indexOf(btn) === wantIndex;
            if (atRightSlot && !keep) { keep = btn; continue; }
            if (btn.ownerCt && btn.ownerCt.remove) { btn.ownerCt.remove(btn, true); }
            else if (btn.destroy) { btn.destroy(); }
        }
        return keep;
    }

    function decorateGuest(cfg) {
        var rec = cfg.pveSelNode;
        if (!rec || !rec.data) { reconcile(null, -1); return; }

        var type = rec.data.type;
        var node = rec.data.node;
        var vmid = rec.data.vmid;

        if ((type !== 'lxc' && type !== 'qemu') || !vmid) {
            reconcile(null, -1);
            return;
        }

        var tb = guestToolbar(cfg);
        if (!tb) { return; }

        var name = rec.data.name || rec.data.text || ('guest ' + vmid);
        var place = function () {
            if (reconcile(tb, guestIndex(tb))) { return; }   /* already correct */
            /* Recompute: removing a stale button shifts everything after it, so
               an index taken before reconcile would be off by one. */
            var want = guestIndex(tb);
            var btn = tb.insert(want, Ext.apply({
                xtype: 'button',
                itemId: 'pauGuestBtn',
                text: 'Update Now',
                iconCls: 'fa fa-refresh',
                tooltip: 'Update only this guest. The host is not touched and no ' +
                         'reboot is scheduled.',
                handler: function () {
                    openPanel('Auto-Update — ' + name + ' (' + vmid + ')',
                              panelBase() + '/guest?vmid=' + encodeURIComponent(vmid) +
                              '&name=' + encodeURIComponent(name));
                }
            }, siblingStyle(tb)));
            tb.updateLayout();
            return btn;
        };

        if (type === 'qemu') {
            withOsType(node, vmid, function (ostype) {
                if (/^w/i.test(ostype)) { reconcile(null, -1); return; }
                if (tb.rendered && !tb.destroyed) { place(); }
            });
        } else {
            place();
        }
    }

    /* Config panels are created and destroyed as you click around the tree, so
       a periodic sweep is used rather than a one-shot override: it works
       regardless of how or when Proxmox builds them, which differs by release. */
    function install() {
        injectStyles();
        installNodeButton();
        Ext.TaskManager.start({
            interval: 800,
            run: function () {
                try {
                    var cfg = outermostConfig();
                    if (cfg) { decorateGuest(cfg); } else { reconcile(null, -1); }
                } catch (e) {
                    if (window.console) {
                        console.warn('proxmox-autoupdate: guest sweep failed', e);
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
