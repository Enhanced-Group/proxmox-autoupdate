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

# Paths are overridable purely so the test suite can exercise apply/remove
# against a throwaway copy. Nothing in normal operation sets these.
TARGET="${PAU_TARGET:-/usr/share/pve-manager/js/pvemanagerlib.js}"
BACKUP="${PAU_BACKUP:-/var/lib/proxmox-autoupdate/pvemanagerlib.js.orig}"
CONFIG_FILE="${PAU_CONFIG:-/etc/proxmox-autoupdate.conf}"
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

file_size() { wc -c < "$1" 2>/dev/null || echo 0; }

# Does TARGET look like a complete pvemanagerlib.js rather than a fragment?
# A truncated file is the one failure mode that must never be propagated into
# the backup, because the backup is the only way back.
target_looks_sane() {
    grep -qF "${SENTINEL}" "${TARGET}" 2>/dev/null || return 1
    [ "$(file_size "${TARGET}")" -ge 65536 ] || return 1
    return 0
}

# Snapshot the shipped file, but only when it is worth snapshotting.
#
# pve-manager upgrades legitimately change this file, so the backup cannot be
# write-once. It must, however, refuse to overwrite a good copy with a damaged
# one: previously the copy was taken unconditionally, so once TARGET was
# truncated the truncated version replaced the last good backup on the very next
# apt transaction.
backup_target() {
    if ! target_looks_sane; then
        warn "${TARGET} does not look intact — keeping the existing reference copy"
        return 1
    fi
    if [ -f "${BACKUP}" ]; then
        local new old
        new=$(file_size "${TARGET}")
        old=$(file_size "${BACKUP}")
        # Allow growth and modest shrinkage between releases; reject a collapse.
        if [ "${old}" -gt 0 ] && [ "$(( new * 10 ))" -lt "$(( old * 9 ))" ]; then
            warn "${TARGET} is much smaller than the reference copy — not replacing it"
            return 1
        fi
    fi
    mkdir -p "$(dirname "${BACKUP}")" 2>/dev/null || true
    cp -f "${TARGET}" "${BACKUP}" 2>/dev/null || {
        warn "Could not write the reference copy at ${BACKUP}"
        return 1
    }
    return 0
}

is_patched() {
    grep -qF "${BEGIN_MARKER}" "${TARGET}" 2>/dev/null
}

# A fingerprint of the exact block this version of the script would emit. It is
# written into the file directly after the begin marker, so `apply` can tell
# "patched with this block" from "patched with an older one" and skip the
# rewrite entirely. This is what makes the apt hook cheap: pve-manager is a 5 MB
# file and the hook fires after *every* dpkg transaction, so re-writing it each
# time is both wasteful and an unnecessary corruption window.
_BLOCK_STAMP=""
block_stamp() {
    if [ -z "${_BLOCK_STAMP}" ]; then
        local h
        h=$(emit_block | sha256sum 2>/dev/null | cut -c1-16)
        [ -n "${h}" ] || h="nohash"
        _BLOCK_STAMP="/* pau-block: ${h} */"
    fi
    printf '%s' "${_BLOCK_STAMP}"
}

is_current() {
    grep -qF "$(block_stamp)" "${TARGET}" 2>/dev/null
}

# Replace TARGET with the contents of a staging file, atomically.
#
# The staging file is created in TARGET's own directory so that rename(2) stays
# within one filesystem and is therefore atomic: readers see either the whole
# old file or the whole new one, never a fragment. The previous implementation
# used `cat tmp > TARGET`, which truncates the live file to zero and streams
# 5 MB back into it — any interruption there (power loss, OOM, ENOSPC) leaves a
# partial pvemanagerlib.js, and because that file is a single script a truncated
# tail is a syntax error for the whole thing, so the entire Proxmox web UI loads
# blank until pve-manager is reinstalled.
atomic_replace() {
    local src="$1" dst="$2"
    chmod --reference="${dst}" "${src}" 2>/dev/null || chmod 644 "${src}"
    chown --reference="${dst}" "${src}" 2>/dev/null || true
    mv -f "${src}" "${dst}"
}

# Staging file next to the target, cleaned up on any exit path.
_STAGE=""
stage_file() {
    _STAGE=$(mktemp "${TARGET}.pau.XXXXXX" 2>/dev/null) || return 1
    printf '%s' "${_STAGE}"
}
cleanup_stage() {
    [ -n "${_STAGE}" ] && rm -f "${_STAGE}"
    _STAGE=""
}
trap cleanup_stage EXIT INT TERM

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
            /* box-sizing matters: without it the border below is added on top
               of the width ExtJS measured at layout time, and the button
               overflows into its neighbour. */
            '.pau-btn, .pau-btn * { box-sizing: border-box !important; }',
            '.pau-btn {',
            '  background: #e57000 !important;',
            '  background-image: none !important;',
            '  border: 1px solid #b35700 !important;',
            '  border-radius: 3px !important;',
            '  overflow: visible !important;',
            '}',
            '.pau-btn .x-btn-button {',
            '  background: transparent !important;',
            '  background-image: none !important;',
            '}',
            '.pau-btn .x-btn-inner {',
            '  color: #ffffff !important;',
            '  font-weight: 600 !important;',
            '}',
            '.pau-btn.x-btn-over, .pau-btn.x-btn-focus, .pau-btn:hover {',
            '  background: #ff8c1a !important;',
            '  border-color: #c96200 !important;',
            '}',
            '.pau-btn.x-btn-pressed, .pau-btn.x-btn-menu-active {',
            '  background: #c96200 !important;',
            '}',
            /* The status indicator *is* the icon — a coloured dot in the icon
               slot, rather than a second badge tacked onto the right. */
            '.pau-btn .x-btn-icon-el.pau-ico {',
            '  background-image: none !important;',
            '  position: relative;',
            '}',
            '.pau-btn .x-btn-icon-el.pau-ico::before {',
            '  content: ""; position: absolute; top: 50%; left: 50%;',
            '  width: 10px; height: 10px; margin: -5px 0 0 -5px;',
            '  border-radius: 50%; background: #d9d9d9;',
            '  box-shadow: 0 0 0 1px rgba(0,0,0,.25);',
            '}',
            '.pau-btn.pau-ok      .x-btn-icon-el.pau-ico::before { background: #46c46b; }',
            '.pau-btn.pau-error   .x-btn-icon-el.pau-ico::before { background: #ff4d4d; }',
            '.pau-btn.pau-running .x-btn-icon-el.pau-ico::before {',
            '  background: #ffd24d; animation: pau-pulse 1.2s ease-in-out infinite;',
            '}',
            '@keyframes pau-pulse { 0%,100% { opacity: 1 } 50% { opacity: .35 } }'
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
        /* Poll hard while something is happening so the label keeps up, and
           back off to once every 25s when idle. */
        var busy = statusCache.value &&
                   (statusCache.value.running ||
                    statusCache.value.pending ||
                    statusCache.value.self_update === 'active' ||
                    statusCache.value.self_update === 'activating');
        var ttl = busy ? 3000 : 25000;
        if (statusCache.value && (now - statusCache.fetched) < ttl) {
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

    /* Whether the tool is updating *itself* is deliberately distinct from a
       guest update: a self-update swaps out this very file, so every open
       Proxmox tab is left running stale JavaScript until it is reloaded. */
    var selfUpdateSeen = false;

    function applyStatus(btn) {
        if (!btn || btn.destroyed) { return; }
        fetchStatus().then(function (state) {
            if (!state || !btn.getEl || btn.destroyed) { return; }
            var el = btn.getEl();
            if (!el) { return; }

            var result = (state.last_run && state.last_run.result) || '';
            var updatingSelf = state.self_update === 'active' ||
                               state.self_update === 'activating' ||
                               !!state.pending;

            var cls = '', label = 'Update Everything';
            var tip = 'Update this node and all its guests';

            if (updatingSelf) {
                cls = 'pau-running';
                label = 'Updating Auto-Update…';
                tip = 'Proxmox Auto-Update is updating itself' +
                      (state.pending ? ' to ' + state.pending : '') +
                      '.\nReload this page once it finishes.';
                selfUpdateSeen = true;
            } else if (state.running) {
                cls = 'pau-running';
                label = 'Updating…';
                tip = 'An update run is in progress';
            } else {
                if (result.indexOf('error') === 0) {
                    cls = 'pau-error'; tip = 'Last run reported errors';
                } else if (result.indexOf('ok') === 0) {
                    cls = 'pau-ok'; tip = 'Last run completed cleanly';
                }
                if (state.last_run && state.last_run.finished) {
                    tip += ' (' + state.last_run.finished + ')';
                }
                if (state.repeat_offenders) {
                    tip += '\nRepeatedly failing: ' + state.repeat_offenders;
                }
                /* The self-update finished while this tab was open, so the UI
                   it is running came from the previous version. */
                if (selfUpdateSeen) {
                    selfUpdateSeen = false;
                    promptReload(state.version);
                }
            }

            ['pau-ok', 'pau-error', 'pau-running'].forEach(function (c) {
                el.removeCls ? el.removeCls(c) : el.dom.classList.remove(c);
            });
            if (cls) { el.addCls ? el.addCls(cls) : el.dom.classList.add(cls); }
            if (btn.getText() !== label) { btn.setText(label); }
            btn.setTooltip(tip);
        });
    }

    function promptReload(version) {
        Ext.Msg.show({
            title: 'Auto-Update updated',
            message:
                'Now running version <b>' + (version || 'the latest release') +
                '</b>.<br><br>' +
                'This tab is still showing the previous version\'s interface — ' +
                'reloading picks up the new one.',
            buttons: Ext.Msg.OKCANCEL,
            buttonText: {ok: 'Reload now', cancel: 'Later'},
            fn: function (choice) {
                if (choice === 'ok') { window.location.reload(); }
            }
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
                        /* The icon slot holds the status dot. */
                        iconCls: 'pau-ico',
                        cls: 'pau-btn',
                        scale: 'medium',
                        minWidth: 170,
                        margin: '0 8 0 0',
                        handler: function () {
                            openPanel('Proxmox Auto-Update', panelBase() + '/');
                        }
                    });

                    /* Lay out twice: the first pass can measure before the
                       injected stylesheet has been applied, which is what left
                       the button overlapping its neighbour. */
                    tb.updateLayout();
                    Ext.defer(function () {
                        if (!btn.destroyed && tb.updateLayout) { tb.updateLayout(); }
                    }, 250);

                    applyStatus(btn);
                    /* Ticks every 3s; fetchStatus decides whether that turns
                       into an actual request or a cached answer. */
                    Ext.TaskManager.start({
                        interval: 3000,
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

    # Fast path. The apt hook runs this after every dpkg transaction, so when the
    # exact block we would write is already in place there is nothing to do —
    # and nothing should touch a 5 MB file that the whole web UI depends on.
    if is_current; then
        [ "${1:-}" = "--quiet" ] || ok "Toolbar button already up to date"
        return 0
    fi

    # Refuse to build on top of a file that is already damaged, and say exactly
    # how to get back. Appending to a truncated pvemanagerlib.js would produce a
    # file that passes the size check while still being broken JavaScript.
    if ! target_looks_sane; then
        fail "${TARGET} does not look like a complete pvemanagerlib.js."
        if [ -f "${BACKUP}" ]; then
            fail "Restore it with:  $0 restore"
        fi
        fail "Or reinstall it with:  apt-get install --reinstall pve-manager"
        return 1
    fi

    if is_patched; then
        act "Existing patch is from a different version — replacing it"
        do_remove --quiet || return 1
    else
        # Only snapshot a file that is genuinely unpatched and intact.
        backup_target || true
    fi

    local tmp
    tmp=$(stage_file) || { fail "Could not create a staging file next to ${TARGET}"; return 1; }

    if ! cat "${TARGET}" > "${tmp}"; then
        fail "Could not stage a copy of ${TARGET} (out of space?)"
        cleanup_stage
        return 1
    fi
    # Ensure the file ends with a newline so the block starts on its own line —
    # but do not add a blank one, or removing the block would not restore the
    # file byte for byte.
    if [ -s "${tmp}" ] && [ "$(tail -c 1 "${tmp}" | od -An -c | tr -d ' ')" != '\n' ]; then
        printf '\n' >> "${tmp}"
    fi
    # The stamp rides on the end of the BEGIN marker line, so it is inside the
    # block and gets removed with it, and both is_patched and the removal awk
    # still match the marker as a substring.
    if ! emit_block | sed "1s|\$| $(block_stamp)|" >> "${tmp}"; then
        fail "Could not append the button block (out of space?)"
        cleanup_stage
        return 1
    fi

    # Sanity-check before swapping it in.
    if ! grep -qF "${SENTINEL}" "${tmp}"; then
        fail "Refusing to install: result no longer contains ${SENTINEL}"
        cleanup_stage
        return 1
    fi
    if ! grep -qF "${END_MARKER}" "${tmp}"; then
        fail "Refusing to install: the appended block is incomplete"
        cleanup_stage
        return 1
    fi
    if [ "$(wc -c < "${tmp}")" -lt "$(wc -c < "${TARGET}")" ]; then
        fail "Refusing to install: result is smaller than the original"
        cleanup_stage
        return 1
    fi

    atomic_replace "${tmp}" "${TARGET}" || { fail "Could not replace ${TARGET}"; cleanup_stage; return 1; }
    _STAGE=""
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
    tmp=$(stage_file) || { fail "Could not create a staging file next to ${TARGET}"; return 1; }

    # Delete strictly between the markers, inclusive.
    if ! awk -v b="${BEGIN_MARKER}" -v e="${END_MARKER}" '
        index($0, b) { skip = 1 }
        !skip        { print }
        index($0, e) { skip = 0 }
    ' "${TARGET}" > "${tmp}"; then
        fail "Could not stage the unpatched file (out of space?)"
        cleanup_stage
        return 1
    fi

    if grep -qF "${BEGIN_MARKER}" "${tmp}" || grep -qF "${END_MARKER}" "${tmp}"; then
        fail "Removal left marker text behind — leaving the file untouched"
        cleanup_stage
        return 1
    fi
    if ! grep -qF "${SENTINEL}" "${tmp}"; then
        fail "Refusing to write: result no longer contains ${SENTINEL}"
        cleanup_stage
        return 1
    fi

    atomic_replace "${tmp}" "${TARGET}" || { fail "Could not replace ${TARGET}"; cleanup_stage; return 1; }
    _STAGE=""
    [ "${quiet}" = "--quiet" ] || ok "Button removed from the Proxmox toolbar"
    return 0
}

# Put the reference copy back. This is the manual recovery path for a
# pvemanagerlib.js that has been damaged — by an interrupted write from an older
# version of this script, or by anything else that left it truncated.
do_restore() {
    if [ ! -f "${BACKUP}" ]; then
        fail "No reference copy at ${BACKUP}"
        fail "Reinstall the shipped file with:  apt-get install --reinstall pve-manager"
        return 1
    fi
    if ! grep -qF "${SENTINEL}" "${BACKUP}" 2>/dev/null; then
        fail "The reference copy at ${BACKUP} does not look intact either."
        fail "Reinstall the shipped file with:  apt-get install --reinstall pve-manager"
        return 1
    fi
    if [ ! -f "${TARGET}" ]; then
        fail "Not found: ${TARGET}"
        return 1
    fi

    local tmp
    tmp=$(stage_file) || { fail "Could not create a staging file next to ${TARGET}"; return 1; }
    if ! cat "${BACKUP}" > "${tmp}"; then
        fail "Could not stage the reference copy (out of space?)"
        cleanup_stage
        return 1
    fi
    atomic_replace "${tmp}" "${TARGET}" || { fail "Could not replace ${TARGET}"; cleanup_stage; return 1; }
    _STAGE=""
    ok "Restored ${TARGET} from the reference copy"
    echo -e "     ${C_DIM}Hard-refresh the Proxmox UI (Ctrl+Shift+R).${C_NC}"
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
    apply)   do_apply "${2:-}" ;;
    remove)  do_remove "${2:-}" ;;
    restore) do_restore ;;
    status)  do_status ;;
    *)
        echo "Usage: $0 apply|remove|status|restore [--quiet]"
        echo ""
        echo "  apply    add the Auto-Update buttons to the Proxmox web UI"
        echo "  remove   take them out again"
        echo "  status   report whether they are installed"
        echo "  restore  put back the reference copy of pvemanagerlib.js"
        exit 2
        ;;
esac
