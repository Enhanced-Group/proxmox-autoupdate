#!/usr/bin/env bash
# ==============================================================================
# Cross-file invariants that no single-file linter can see.
#
# Each of these encodes a real regression: something that passed `bash -n` and
# shellcheck, shipped, and broke on users' machines.
# ==============================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
ok()   { echo "  [ ok ] $1"; }
fail() { echo "  [FAIL] $1"; FAILED=1; }

# --- 1. The notifier slice the panel lifts out of the update script ----------
# The panel's "send a test notification" button extracts the block between these
# markers and sources it on its own. Moving a helper out of that range leaves
# both the test button and real reports calling an undefined function — which is
# exactly what shipped as v3.5.0 and had to be fixed in v3.5.1. Nothing in
# either file's syntax catches it.
echo "== notifier marker slice =="
BEGIN_LINE=$(grep -n '# >>> PAU-NOTIFIER-BEGIN' update-everything.sh | head -1 | cut -d: -f1)
END_LINE=$(grep -n '# <<< PAU-NOTIFIER-END' update-everything.sh | head -1 | cut -d: -f1)
if [ -z "${BEGIN_LINE}" ] || [ -z "${END_LINE}" ]; then
    fail "PAU-NOTIFIER-BEGIN/END markers not found in update-everything.sh"
else
    ok "markers at lines ${BEGIN_LINE}-${END_LINE}"
    SLICE=$(sed -n "${BEGIN_LINE},${END_LINE}p" update-everything.sh)

    # Read the required names out of the panel itself rather than repeating them
    # here, so the two can never drift apart. The panel asserts on this exact
    # tuple before it sources the slice.
    # Read to the line that actually closes the tuple. A sed range ending on
    # /)/ stops at the first ")" — which is inside "cfg_escape()" on the very
    # first line, so three of the ten names were never checked.
    REQUIRED=$(awk '/^[[:space:]]*required = \(/ {f=1}
                    f {print}
                    f && /\)[[:space:]]*$/ {exit}' webui/pve-autoupdate-ui \
               | grep -oE '"[a-z_]+\(\)"' | tr -d '"()' | sort -u)
    if [ -z "${REQUIRED}" ]; then
        fail "could not read the required-function list from the panel"
    fi
    # The panel's own list, plus the two the markers' comment implies but which
    # sat outside them until this was written.
    for fn in ${REQUIRED} build_text_summary notify_all; do
        if echo "${SLICE}" | grep -qE "^${fn}\(\)"; then
            ok "${fn}() is inside the notifier block"
        else
            fail "${fn}() is NOT inside the notifier block — the panel's test-notification button will break"
        fi
    done

    # The slice must also be independently sourceable: the panel runs it in a
    # fresh shell, so a syntax error inside it fails at test time rather than at
    # build time.
    if echo "${SLICE}" | bash -n 2>/dev/null; then
        ok "notifier block parses standalone"
    else
        fail "notifier block does not parse on its own"
    fi
fi

# --- 2. Version and changelog agree ------------------------------------------
# The panel compares the PAU_VERSION in the published script against the local
# one to decide whether an update is available. If a release bumps one and not
# the other, every installation is told it is out of date forever, or never.
echo "== version / changelog =="
PAU_VERSION=$(grep -m1 '^PAU_VERSION=' update-everything.sh | cut -d'"' -f2)
CHANGELOG_TOP=$(grep -m1 '^## ' CHANGELOG.md | sed 's/^## *//' | awk '{print $1}' | tr -d 'v[]')
if [ -z "${PAU_VERSION}" ]; then
    fail "no PAU_VERSION in update-everything.sh"
elif [ "${PAU_VERSION}" = "${CHANGELOG_TOP}" ]; then
    ok "PAU_VERSION ${PAU_VERSION} matches the newest CHANGELOG entry"
else
    fail "PAU_VERSION is ${PAU_VERSION} but the newest CHANGELOG entry is ${CHANGELOG_TOP}"
fi

# --- 3. Every setting the panel writes is a setting the script reads ---------
# The panel writing a key the updater never reads is a control that silently
# does nothing; the updater reading a key the panel cannot write is a setting
# with no UI. LOG_DIR was both at once for a while.
echo "== config key parity =="
# Settings that are deliberately consumed by the panel or the installer rather
# than by the update script: the schedule lives in the crontab, and the
# confirmation prompt is a UI behaviour.
PANEL_ONLY="UPDATE_SCHEDULE_CRON CONFIRM_UPDATES SUPPRESS_SUBSCRIPTION_NOTICE"

PANEL_KEYS=$(sed -n '/^EDITABLE_KEYS = {/,/^}/p' webui/pve-autoupdate-ui \
             | grep -oE '"[A-Z_]+"' | tr -d '"' | sort -u)
PARITY_OK=1
for key in ${PANEL_KEYS}; do
    case " ${PANEL_ONLY} " in *" ${key} "*) continue ;; esac
    # Either assigned with a default (KEY="${KEY:-x}") or simply referenced
    # (${KEY:-}). Only checking for an assignment missed the second form.
    if ! grep -qE "^\s*${key}=" update-everything.sh \
       && ! grep -qE "\\\$\{${key}[:}]" update-everything.sh; then
        fail "${key} is editable in the panel but never read by update-everything.sh"
        PARITY_OK=0
    fi
done
[ "${PARITY_OK}" -eq 1 ] && ok "$(echo "${PANEL_KEYS}" | wc -w) panel-editable keys all resolve"

# And the reverse: a documented panel-only key that the updater *did* start
# reading would mean the exclusion above is now wrong.
for key in ${PANEL_ONLY}; do
    if grep -qE "^\s*${key}=" update-everything.sh; then
        fail "${key} is listed as panel-only but update-everything.sh now reads it"
    fi
done

# --- 3b. Shared JS only touches elements both pages have ---------------------
# SHARED_JS is loaded by the main panel *and* by the per-guest page. An element
# lookup for something only the main page has throws on the guest page, and
# because it is usually inside a timer or an event handler it fails silently
# rather than at load. This caught exactly that: a run timer added to the main
# page, referenced from shared code, with no such element on the guest page.
echo "== shared JS element references =="
python3 - <<'PYCHECK'
import re, sys

src = open("webui/pve-autoupdate-ui", encoding="utf-8").read()

def block(name):
    i = src.index(name + ' = r"""')
    j = src.index('"""', i + len(name) + 8)
    return src[i:j]

shared = block("SHARED_JS")
refs = set(re.findall(r'\$\("([A-Za-z0-9_-]+)"\)', shared))

bad = False
for tpl in ("PAGE_TEMPLATE", "GUEST_TEMPLATE"):
    ids = set(re.findall(r'id="([A-Za-z0-9_-]+)"', block(tpl)))
    missing = sorted(r for r in refs if r not in ids)
    if missing:
        print("  [FAIL] SHARED_JS references %s, which %s does not contain"
              % (", ".join(missing), tpl))
        bad = True
    else:
        print("  [ ok ] every SHARED_JS lookup exists in %s" % tpl)
sys.exit(1 if bad else 0)
PYCHECK
[ $? -eq 0 ] || FAILED=1

# --- 4. No CR bytes ----------------------------------------------------------
# A CRLF in a shebang makes the kernel look for an interpreter literally named
# "bash\r". .gitattributes normalises this, but a file added without a matching
# rule would slip through.
echo "== line endings =="
CR_FILES=""
for f in update-everything.sh install.sh uninstall.sh \
         webui/pve-autoupdate-ui webui/patch-webui.sh \
         webui/pve-autoupdate-ui.service webui/99-proxmox-autoupdate-webui \
         ci/invariants.sh; do
    [ -f "${f}" ] || continue
    if LC_ALL=C grep -qU $'\r' "${f}" 2>/dev/null; then
        CR_FILES="${CR_FILES} ${f}"
    fi
done
if [ -n "${CR_FILES}" ]; then
    fail "carriage returns found in:${CR_FILES}"
else
    ok "no CR bytes in any shipped file"
fi

# --- 5. The in-guest payload is POSIX ----------------------------------------
# It is piped into /bin/sh, which is dash on Debian and BusyBox ash on Alpine.
# `bash -n` on the outer file does not validate the heredoc at all, so a bashism
# added here would only surface inside a user's container.
echo "== in-guest payload =="
if GUEST=$(APT_LOCK_TIMEOUT=600 DRY_RUN=false bash -c '
        eval "$(sed -n "/^build_guest_update_script() {/,/^GUESTSCRIPT\$/p" update-everything.sh; echo "}")"
        build_guest_update_script' 2>/dev/null) && [ -n "${GUEST}" ]; then
    if printf '%s' "${GUEST}" | sh -n 2>/dev/null; then
        ok "generated guest script parses under /bin/sh"
    else
        fail "generated guest script is NOT valid POSIX sh — Alpine and Debian guests will fail"
    fi
    if printf '%s' "${GUEST}" | grep -qE '\[\[|<<<|\blocal\b|\bdeclare\b'; then
        fail "generated guest script contains bashisms"
    else
        ok "no bashisms in the generated guest script"
    fi
else
    fail "could not extract the guest script from build_guest_update_script"
fi

# --- 6. Guests are never invoked with bash -----------------------------------
echo "== guest interpreter =="
if grep -nE 'pct exec .* -- /bin/bash|--command "/bin/bash"' update-everything.sh; then
    fail "guest exec still uses /bin/bash — Alpine has no bash"
else
    ok "guests are executed with /bin/sh"
fi

echo ""
if [ "${FAILED}" -ne 0 ]; then
    echo "invariants: FAILED"
    exit 1
fi
echo "invariants: all passed"
