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

# --- Subscription notice ------------------------------------------------------
# Proxmox shows a "No valid subscription" dialog on every login when the node
# has no subscription key. Suppressing it is opt-in and off by default.
#
# To be explicit about what this does and does not do: it stops one dialog
# rendering. It does not create, alter or fake a subscription, it does not
# change which repositories the node can reach, and it does not touch
# /etc/subscription or the subscription API. `pvesubscription get` reports
# exactly what it did before. If you run Proxmox commercially, buy a
# subscription — it is what funds the thing you are updating.
NAG_TARGET="${PAU_NAG_TARGET:-/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js}"
NAG_SENTINEL="checked_command"
NAG_BEGIN="/* ==== BEGIN proxmox-autoupdate subscription-notice ==== */"
NAG_END="/* ==== END proxmox-autoupdate subscription-notice ==== */"

# Read the opt-in from the same config file everything else uses.
SUPPRESS_NAG="false"
if [ -r "${CONFIG_FILE}" ]; then
    _nag=$(sed -n 's/^[[:space:]]*SUPPRESS_SUBSCRIPTION_NOTICE[[:space:]]*=[[:space:]]*['"'"'"]\{0,1\}\([A-Za-z]*\).*/\1/p' \
        "${CONFIG_FILE}" | tail -1)
    [ "${_nag}" = "true" ] && SUPPRESS_NAG="true"
fi

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

# Staging file next to a target, cleaned up on any exit path.
_STAGE=""
stage_file() {
    local dest="${1:-${TARGET}}"
    _STAGE=$(mktemp "${dest}.pau.XXXXXX" 2>/dev/null) || return 1
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
            /* Colours come from CSS custom properties so the panel's chosen
               palette can be applied at runtime without re-patching this file.
               The fallbacks are the Proxmox orange, so the buttons look right
               before the first status fetch completes and stay right if the
               panel is unreachable. */
            ':root {',
            '  --pau-accent: #e57000;',
            '  --pau-accent-hover: #ff8c1a;',
            '  --pau-accent-pressed: #c96200;',
            '  --pau-accent-border: #b35700;',
            '  --pau-on-accent: #ffffff;',
            '  --pau-ok: #46c46b;',
            '  --pau-warn: #ffd24d;',
            '  --pau-err: #ff4d4d;',
            '}',
            '.pau-btn, .pau-btn * { box-sizing: border-box !important; }',
            '.pau-btn {',
            '  background: var(--pau-accent) !important;',
            '  background-image: none !important;',
            '  border: 1px solid var(--pau-accent-border) !important;',
            '  border-radius: 3px !important;',
            '  overflow: visible !important;',
            '}',
            '.pau-btn .x-btn-button {',
            '  background: transparent !important;',
            '  background-image: none !important;',
            '}',
            /* Deliberately no font-weight override. Bolding the label made it
               heavier than every other button in the toolbar, which is part of
               why it looked like it had been added by someone else. */
            '.pau-btn .x-btn-inner { color: var(--pau-on-accent) !important; }',
            '.pau-btn .x-btn-icon-el { color: var(--pau-on-accent) !important; }',
            '.pau-btn.x-btn-over, .pau-btn.x-btn-focus, .pau-btn:hover {',
            '  background: var(--pau-accent-hover) !important;',
            '  border-color: var(--pau-accent-pressed) !important;',
            '}',
            '.pau-btn.x-btn-pressed, .pau-btn.x-btn-menu-active {',
            '  background: var(--pau-accent-pressed) !important;',
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
            '.pau-btn.pau-ok      .x-btn-icon-el.pau-ico::before { background: var(--pau-ok); }',
            '.pau-btn.pau-error   .x-btn-icon-el.pau-ico::before { background: var(--pau-err); }',
            '.pau-btn.pau-running .x-btn-icon-el.pau-ico::before {',
            '  background: var(--pau-warn); animation: pau-pulse 1.2s ease-in-out infinite;',
            '}',
            '@keyframes pau-pulse { 0%,100% { opacity: 1 } 50% { opacity: .35 } }',
            /* The per-guest button. It used to copy its neighbours exactly so
               it looked native; it now carries the accent so that recolouring
               the panel recolours every button this tool adds, which is what
               people expect when they change a theme. */
            '.pau-guest-btn .x-btn-inner {',
            '  color: var(--pau-accent) !important;',
            '  font-weight: 600 !important;',
            '}',
            '.pau-guest-btn .x-btn-icon-el { color: var(--pau-accent) !important; }',
            '.pau-guest-btn.x-btn-over, .pau-guest-btn:hover {',
            '  background: var(--pau-accent) !important;',
            '  background-image: none !important;',
            '}',
            '.pau-guest-btn.x-btn-over .x-btn-inner, .pau-guest-btn:hover .x-btn-inner,',
            '.pau-guest-btn.x-btn-over .x-btn-icon-el, .pau-guest-btn:hover .x-btn-icon-el {',
            '  color: var(--pau-on-accent) !important;',
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
            }],
            /* While the panel is open it prompts for its own reload, and it is
               the reliable detector: it polls every two seconds and is driving
               the update, whereas this poll runs every 25 seconds when idle and
               fails outright while the panel service restarts. Two prompts for
               one event is worse than one, so this one stands down. */
            listeners: {
                show:  function () { panelWindowOpen = true; },
                close: function () { panelWindowOpen = false; }
            }
        });
        win.show();
    }

    /* Which theme is Proxmox actually showing?
       Not the same question as the operating system's preference: Proxmox has
       its own light/dark setting, and a dark Proxmox on a light desktop opened
       this panel in light mode inside a dark window.

       Measured from the rendered page rather than read from a cookie or a class
       name, so it keeps working when Proxmox renames or restructures its
       themes — which it has done before. */
    function proxmoxTheme() {
        try {
            var probe = document.querySelector('.x-panel-body') || document.body;
            var bg = window.getComputedStyle(probe).backgroundColor || '';
            var m = /rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/.exec(bg);
            if (!m) { return null; }
            /* Perceived brightness. Anything below the midpoint is a dark theme. */
            var lum = (0.2126 * +m[1] + 0.7152 * +m[2] + 0.0722 * +m[3]) / 255;
            return lum < 0.5 ? 'dark' : 'light';
        } catch (e) { return null; }
    }

    function withTheme(url) {
        var theme = proxmoxTheme();
        if (!theme) { return url; }
        return url + (url.indexOf('?') === -1 ? '?' : '&') + 'theme=' + theme;
    }

    function openPanel(title, url) {
        var themed = withTheme(url);
        probePanel().then(function (reachable) {
            if (reachable) { openWindow(title, themed); } else { showCertHelp(url); }
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
            applyTheme(data);
            return data;
        }).catch(function () { return null; });
    }

    /* Push the panel's palette onto the CSS variables the styles above read.
       Values are validated here as well as on the server: this runs inside the
       Proxmox origin, so anything written into a style property has to be
       known-safe regardless of where it came from. */
    var HEX = /^#[0-9a-fA-F]{6}$/;
    var THEME_VARS = {
        accent: '--pau-accent',
        accentHover: '--pau-accent-hover',
        accentPressed: '--pau-accent-pressed',
        accentBorder: '--pau-accent-border',
        onAccent: '--pau-on-accent',
        ok: '--pau-ok',
        warn: '--pau-warn',
        err: '--pau-err'
    };

    function applyTheme(state) {
        if (!state || !state.theme) { return; }
        var root = document.documentElement;
        Object.keys(THEME_VARS).forEach(function (key) {
            var value = state.theme[key];
            if (typeof value === 'string' && HEX.test(value)) {
                root.style.setProperty(THEME_VARS[key], value);
            }
        });
    }

    /* Whether the tool is updating *itself* is deliberately distinct from a
       guest update: a self-update swaps out this very file, so every open
       Proxmox tab is left running stale JavaScript until it is reloaded. */
    var selfUpdateSeen = false;
    /* True while the control panel is open in a window on this page. It prompts
       for its own reload, so this one must not also. */
    var panelWindowOpen = false;

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
                    /* The open panel has already offered this. Other Proxmox
                       tabs, which have no panel open, still need telling —
                       their injected code is the stale part. */
                    if (!panelWindowOpen) { promptReload(state.version); }
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
                    /* Copy the neighbours' ui/scale/baseCls, exactly as the
                       per-guest button already does.

                       This used to force scale:'medium' and minWidth:170 while
                       every other button in that toolbar is 'small' and sized
                       to its text. The result was a button noticeably taller
                       and wider than Documentation and Create VM sitting right
                       next to it — which is why it read as bolted on rather
                       than built in. Let ExtJS size it like its siblings and
                       express the accent through colour alone. */
                    var btn = tb.insert(idx, Ext.apply({
                        xtype: 'button',
                        itemId: 'pauNodeBtn',
                        text: 'Update Everything',
                        /* The icon slot holds the status dot. */
                        iconCls: 'pau-ico',
                        cls: 'pau-btn',
                        margin: '0 8 0 0',
                        handler: function () {
                            openPanel('Proxmox Auto-Update', panelBase() + '/');
                        }
                    }, siblingStyle(tb)));

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

    /* Adopt the geometry of whichever buttons are already in this toolbar, so
       ours sits at the same height and weight as its neighbours instead of
       imposing its own. Skips our own buttons, or a second call would copy the
       first one's style back onto itself. */
    function siblingStyle(tb) {
        var items = tb.query('button');
        for (var i = 0; i < items.length; i++) {
            if (items[i].itemId === 'pauGuestBtn' || items[i].itemId === 'pauNodeBtn') { continue; }
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
                cls: 'pau-guest-btn',
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

# ---- Subscription notice ----------------------------------------------------
#
# Same approach as the toolbar button: append a self-contained block rather than
# splice into Proxmox's own code. The widely-circulated one-liners for this use
# `sed` against the exact text of the dialog, which breaks silently whenever
# Proxmox rewords it and, worse, edits the file in place. Overriding the method
# after the file has loaded does not care how the dialog is worded, and appending
# cannot corrupt the code above it.

nag_emit_block() {
    cat <<'NAGBLOCK'
/* ==== BEGIN proxmox-autoupdate subscription-notice ==== */
/* Added by proxmox-autoupdate because SUPPRESS_SUBSCRIPTION_NOTICE=true.
   Removed cleanly by patch-webui.sh nag-remove.

   This suppresses one dialog. It does not create or modify a subscription,
   does not change repository access, and does not touch /etc/subscription.
   `pvesubscription get` reports exactly what it did before. */
(function () {
    if (typeof Proxmox === 'undefined' || !Proxmox.Utils) { return; }
    var original = Proxmox.Utils.checked_command;
    if (typeof original !== 'function') { return; }
    Proxmox.Utils.checked_command = function (orig_cmd) {
        try {
            if (typeof orig_cmd === 'function') { orig_cmd(); }
        } catch (e) {
            /* Fall back to Proxmox's own behaviour rather than swallowing a
               real error from the command we were asked to run. */
            try { original(orig_cmd); } catch (e2) { }
        }
    };
})();
/* ==== END proxmox-autoupdate subscription-notice ==== */
NAGBLOCK
}

nag_is_patched() {
    grep -qF "${NAG_BEGIN}" "${NAG_TARGET}" 2>/dev/null
}

nag_require_target() {
    if [ ! -f "${NAG_TARGET}" ]; then
        fail "Not found: ${NAG_TARGET}"
        fail "Is proxmox-widget-toolkit installed?"
        return 1
    fi
    if ! grep -qF "${NAG_SENTINEL}" "${NAG_TARGET}" 2>/dev/null; then
        fail "${NAG_TARGET} does not contain ${NAG_SENTINEL} — refusing to touch it."
        return 1
    fi
    return 0
}

do_nag_apply() {
    nag_require_target || return 1
    if nag_is_patched; then
        [ "${1:-}" = "--quiet" ] || ok "Subscription notice already suppressed"
        return 0
    fi

    local tmp
    tmp=$(stage_file "${NAG_TARGET}") || { fail "Could not stage next to ${NAG_TARGET}"; return 1; }
    if ! cat "${NAG_TARGET}" > "${tmp}"; then
        fail "Could not stage ${NAG_TARGET} (out of space?)"; cleanup_stage; return 1
    fi
    if [ -s "${tmp}" ] && [ "$(tail -c 1 "${tmp}" | od -An -c | tr -d ' ')" != '\n' ]; then
        printf '\n' >> "${tmp}"
    fi
    if ! nag_emit_block >> "${tmp}"; then
        fail "Could not append the block (out of space?)"; cleanup_stage; return 1
    fi
    if ! grep -qF "${NAG_END}" "${tmp}" || ! grep -qF "${NAG_SENTINEL}" "${tmp}"; then
        fail "Refusing to install: the result does not look right"; cleanup_stage; return 1
    fi
    if [ "$(wc -c < "${tmp}")" -lt "$(wc -c < "${NAG_TARGET}")" ]; then
        fail "Refusing to install: result is smaller than the original"; cleanup_stage; return 1
    fi

    atomic_replace "${tmp}" "${NAG_TARGET}" || { fail "Could not replace ${NAG_TARGET}"; cleanup_stage; return 1; }
    _STAGE=""
    [ "${1:-}" = "--quiet" ] || {
        ok "Subscription notice suppressed"
        echo -e "     ${C_DIM}Hard-refresh the Proxmox UI (Ctrl+Shift+R). This hides a dialog;${C_NC}"
        echo -e "     ${C_DIM}it does not change your subscription or repository access.${C_NC}"
    }
    return 0
}

do_nag_remove() {
    nag_require_target || return 1
    if ! nag_is_patched; then
        [ "${1:-}" = "--quiet" ] || warn "Subscription notice is not suppressed — nothing to do"
        return 0
    fi

    local tmp
    tmp=$(stage_file "${NAG_TARGET}") || { fail "Could not stage next to ${NAG_TARGET}"; return 1; }
    if ! awk -v b="${NAG_BEGIN}" -v e="${NAG_END}" '
        index($0, b) { skip = 1 }
        !skip        { print }
        index($0, e) { skip = 0 }
    ' "${NAG_TARGET}" > "${tmp}"; then
        fail "Could not stage the unpatched file"; cleanup_stage; return 1
    fi
    if grep -qF "${NAG_BEGIN}" "${tmp}" || grep -qF "${NAG_END}" "${tmp}"; then
        fail "Removal left marker text behind — leaving the file untouched"; cleanup_stage; return 1
    fi
    if ! grep -qF "${NAG_SENTINEL}" "${tmp}"; then
        fail "Refusing to write: result no longer contains ${NAG_SENTINEL}"; cleanup_stage; return 1
    fi

    atomic_replace "${tmp}" "${NAG_TARGET}" || { fail "Could not replace ${NAG_TARGET}"; cleanup_stage; return 1; }
    _STAGE=""
    [ "${1:-}" = "--quiet" ] || ok "Subscription notice restored"
    return 0
}

# Bring the notice into line with the config. Called by apply, so the apt hook
# re-applies it after a proxmox-widget-toolkit upgrade replaces the file.
nag_reconcile() {
    [ -f "${NAG_TARGET}" ] || return 0
    if [ "${SUPPRESS_NAG}" = "true" ]; then
        nag_is_patched || do_nag_apply "${1:-}"
    else
        ! nag_is_patched || do_nag_remove "${1:-}"
    fi
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
    apply)
        do_apply "${2:-}"
        _rc=$?
        # Reconcile the subscription notice on every apply, so the apt hook
        # restores it after proxmox-widget-toolkit is upgraded — that package
        # replaces proxmoxlib.js wholesale, exactly like pve-manager does to
        # pvemanagerlib.js.
        nag_reconcile "${2:-}" || true
        exit ${_rc}
        ;;
    remove)
        do_remove "${2:-}"
        _rc=$?
        do_nag_remove --quiet || true
        exit ${_rc}
        ;;
    restore)     do_restore ;;
    status)      do_status ;;
    nag-apply)   do_nag_apply "${2:-}" ;;
    nag-remove)  do_nag_remove "${2:-}" ;;
    *)
        echo "Usage: $0 apply|remove|status|restore|nag-apply|nag-remove [--quiet]"
        echo ""
        echo "  apply       add the Auto-Update buttons to the Proxmox web UI, and"
        echo "              bring the subscription notice into line with the config"
        echo "  remove      take them out again"
        echo "  status      report whether they are installed"
        echo "  restore     put back the reference copy of pvemanagerlib.js"
        echo "  nag-apply   suppress the 'No valid subscription' dialog"
        echo "  nag-remove  restore it"
        echo ""
        echo "  Suppressing the notice hides a dialog. It does not create or alter"
        echo "  a subscription, and does not change repository access."
        exit 2
        ;;
esac
