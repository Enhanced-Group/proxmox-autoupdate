#!/usr/bin/env bash
# ==============================================================================
# Cross-file invariants that no single-file linter can see.
#
# Each of these encodes a real regression: something that passed both `bash -n`
# and the linter, shipped, and broke on users' machines.
#
# (Do not begin a comment line with the word "shellcheck" — it is read as a
# directive, and an unparseable one is an error, not a warning. That is exactly
# how this file first broke CI.)
# ==============================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
ok()   { echo "  [ ok ] $1"; }
fail() { echo "  [FAIL] $1"; FAILED=1; }
warn() { echo "  [warn] $1"; }

# Presence is not usability: Windows puts a python3 stub on PATH that exists,
# prints an advert for the Microsoft Store, and exits non-zero.
have_python3() { python3 -c 'pass' >/dev/null 2>&1; }

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
    # Herestrings, not pipes. `producer | grep -q` is a trap under
    # `set -o pipefail`: grep exits on its first match, the producer takes
    # SIGPIPE, and the pipeline reports failure even though the match
    # succeeded. Timing-dependent, so it passed for weeks and then began
    # failing once this block grew past a few hundred lines.
    for fn in ${REQUIRED} build_text_summary notify_all; do
        if grep -qE "^${fn}\(\)" <<<"${SLICE}"; then
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
# than by the update script: the schedules live in the crontab — each cron line
# already carries its own --no-reboot or not, so a run never has to consult the
# list to know what it is allowed to do — and the confirmation prompt is a UI
# behaviour. The update script reads UPDATE_SCHEDULES only in --doctor, through
# cfg_read, to check that the config and the crontab still agree.
# WEB_UI_PUBLIC_URL is read by patch-webui.sh, which bakes it into the button
# in pvemanagerlib.js. It is a browser-side address; a cron run has no use for
# it and never looks at it.
PANEL_ONLY="UPDATE_SCHEDULE_CRON UPDATE_SCHEDULES CONFIRM_UPDATES SUPPRESS_SUBSCRIPTION_NOTICE WEB_UI_PUBLIC_URL"

PANEL_KEYS=$(sed -n '/^EDITABLE_KEYS = {/,/^}/p' webui/pve-autoupdate-ui \
             | grep -oE '"[A-Z_]+"' | tr -d '"' | sort -u)
PARITY_OK=1
for key in ${PANEL_KEYS}; do
    case " ${PANEL_ONLY} " in *" ${key} "*) continue ;; esac
    # Either assigned with a default (KEY="${KEY:-x}") or simply referenced
    # (${KEY:-}). Only checking for an assignment missed the second form.
    # Either assigned with a default (KEY="${KEY:-x}"), simply referenced
    # (${KEY:-}), or pulled out with cfg_read. Checking only for an assignment
    # missed the second form; checking only those two missed the third, and
    # reported WEB_UI_PORT as unread when --doctor reads it on every run.
    if ! grep -qE "^[[:space:]]*${key}=" update-everything.sh \
       && ! grep -qE "[$]\{${key}[:}]" update-everything.sh \
       && ! grep -qE "cfg_read ${key}([^A-Z_]|$)" update-everything.sh; then
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

# A key excused from the parity check above still has to be read by *something*.
if grep -q 'WEB_UI_PUBLIC_URL' webui/patch-webui.sh; then
    ok "WEB_UI_PUBLIC_URL is consumed by the toolbar patcher"
else
    fail "WEB_UI_PUBLIC_URL is panel-only but nothing reads it"
fi

# The panel is used inside the Proxmox UI, in the iframe the toolbar button
# opens. A new tab is not a fallback for anything: a browser will not render a
# certificate interstitial inside a frame, so the tab was a bootstrap step for
# accepting a self-signed certificate. That is fixed by trusting the cluster CA
# instead, which covers every port at once, so nothing needs to leave Proxmox.
if grep -q 'window\.open' webui/patch-webui.sh; then
    fail "the injected block opens a new tab again"
else
    ok "the injected block never leaves the Proxmox UI"
fi

# --- 3b. Shared JS only touches elements both pages have ---------------------
# SHARED_JS is loaded by the main panel *and* by the per-guest page. An element
# lookup for something only the main page has throws on the guest page, and
# because it is usually inside a timer or an event handler it fails silently
# rather than at load. This caught exactly that: a run timer added to the main
# page, referenced from shared code, with no such element on the guest page.
echo "== shared JS element references =="
if ! have_python3; then
    ok "python3 not available — skipped (CI always has it)"
else
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
fi

# --- 3c. Panel defaults match the script's ----------------------------------
# The panel shows KEY_DEFAULTS when a setting is absent from the config file.
# If those drift from the ${KEY:-default} values in update-everything.sh, the
# UI confidently displays a number the script will not actually use.
echo "== default values agree =="
if ! have_python3; then
    ok "python3 not available — skipped (CI always has it)"
else
python3 - <<'PYCHECK'
import re, sys

panel = open("webui/pve-autoupdate-ui", encoding="utf-8").read()
script = open("update-everything.sh", encoding="utf-8").read()

m = re.search(r"KEY_DEFAULTS = \{(.*?)\n\}", panel, re.S)
if not m:
    print("  [FAIL] KEY_DEFAULTS not found in the panel")
    sys.exit(1)
defaults = dict(re.findall(r'"([A-Z_]+)":\s*"([^"]*)"', m.group(1)))

bad = False
# EMAIL_TRANSPORT is inferred by the script when unset rather than defaulted,
# so there is no ${KEY:-value} to compare against. The panel mirrors that
# inference in effective_email_transport().
INFERRED = {"EMAIL_TRANSPORT"}

# A shell default may be written as arithmetic — $((8 * 1024 * 1024)) is
# clearer in the script than 8388608, and the panel has to store the number.
# Compare what they evaluate to, not how they are spelled, or the check fails
# on two spellings of the same value.
ARITH = re.compile(r'\A\$\(\(([0-9+\-*/ ()]+)\)\)\Z')


def as_value(text):
    m = ARITH.match(text.strip())
    if not m:
        return text
    try:
        return str(eval(m.group(1), {"__builtins__": {}}, {}))  # digits and operators only
    except Exception:
        return text


for key, shown in sorted(defaults.items()):
    if key in INFERRED:
        continue
    sm = re.search(r'^%s="\$\{%s:-([^}]*)\}"' % (key, key), script, re.M)
    if not sm:
        continue          # panel-only setting; nothing to compare against
    actual = sm.group(1)
    if as_value(actual) != as_value(shown):
        print("  [FAIL] %s: panel shows %r, script defaults to %r" % (key, shown, actual))
        bad = True
if not bad:
    print("  [ ok ] %d panel defaults match update-everything.sh" % len(defaults))

# Every editable setting must either accept an empty value or have a default.
# Otherwise a key absent from someone's config file comes back empty, and since
# the forms post every field they render, the whole form becomes unsaveable —
# which is exactly what adding three settings in 1.2.0 did.
keys = re.search(r"EDITABLE_KEYS = \{(.*?)\n\}", panel, re.S).group(1)
editable = re.findall(r'"([A-Z_]+)":', keys)
trap = [k for k in editable if k not in defaults]
strict = []
for k in trap:
    # Validators that obviously reject empty: _v_int, _v_cron, _v_time, _v_region.
    m2 = re.search(r'"%s":\s*(\w+)' % k, keys)
    if m2 and m2.group(1) in ("_v_int", "_v_cron", "_v_time", "_v_region"):
        strict.append(k)
if strict:
    print("  [FAIL] no default for settings that reject an empty value: %s"
          % ", ".join(sorted(strict)))
    bad = True
else:
    print("  [ ok ] every strict setting has a default")
sys.exit(1 if bad else 0)
PYCHECK
[ $? -eq 0 ] || FAILED=1
fi

# --- 3d. The installer's step counter is honest ------------------------------
# STEP_TOTAL said 9 while only six step() calls existed, so the installer
# counted to six out of nine and stopped. A progress counter that never reaches
# its total reads as a run that died.
echo "== installer step count =="
DECLARED=$(grep -m1 '^STEP_TOTAL=' install.sh | cut -d= -f2)
ACTUAL=$(grep -c '^[[:space:]]*step "' install.sh)
if [ "${DECLARED}" = "${ACTUAL}" ]; then
    ok "STEP_TOTAL ${DECLARED} matches ${ACTUAL} step() calls"
else
    fail "STEP_TOTAL is ${DECLARED} but there are ${ACTUAL} step() calls"
fi

# --- 3d-bis. The installer can reach every notification channel --------------
# Teams, ntfy, Gotify and Telegram shipped in 1.2.0 and were still missing from
# the installer's menu six releases later, so a fresh install could only reach
# half the channels the tool supports. Worse, the prompts that did exist for
# SMTP wrote nothing: the generated config had no SMTP_* keys at all, so email
# was configured and then silently discarded.
#
# Both halves are checked here — offered in the menu, and persisted to the
# config file — because either one alone still leaves a channel unusable.
echo "== installer covers every channel =="
METHODS=$(sed -n '/^VALID_METHODS = {/,/}/p' webui/pve-autoupdate-ui \
          | grep -oE '"[a-z]+"' | tr -d '"' | sort -u)
if [ -z "${METHODS}" ]; then
    fail "could not read VALID_METHODS from the panel"
else
    MENU=$(sed -n '/NOTIFY_METHODS="\${NOTIFY_METHODS},/p' install.sh \
           | sed -n 's/.*,\([a-z]*\)".*/\1/p' | sort -u)
    MISSING=""
    for m in ${METHODS}; do
        grep -qx "${m}" <<<"${MENU}" || MISSING="${MISSING} ${m}"
    done
    if [ -n "${MISSING}" ]; then
        fail "installer menu cannot select:${MISSING}"
    else
        ok "all $(echo "${METHODS}" | wc -w | tr -d ' ') channels are on the installer menu"
    fi
fi

# Every channel credential the update script reads has to be written by the
# installer, or answering its prompts achieves nothing.
CONF_BLOCK=$(sed -n '/^cat > "${CONFIG_FILE}" <<CONF$/,/^CONF$/p' install.sh)
CHANNEL_KEYS="EMAIL_TRANSPORT SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD
SMTP_SECURITY MAILGUN_API_KEY MAILGUN_DOMAIN SENDER_EMAIL RECIPIENT_EMAIL
DISCORD_WEBHOOK_URL DISCORD_BOT_TOKEN DISCORD_USER_ID SLACK_WEBHOOK_URL
TEAMS_WEBHOOK_URL NTFY_URL NTFY_TOKEN GOTIFY_URL GOTIFY_TOKEN
TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID GENERIC_WEBHOOK_URL"
UNWRITTEN=""
for k in ${CHANNEL_KEYS}; do
    grep -q "^${k}=" <<<"${CONF_BLOCK}" || UNWRITTEN="${UNWRITTEN} ${k}"
done
if [ -n "${UNWRITTEN}" ]; then
    fail "installer never writes:${UNWRITTEN}"
else
    ok "every channel credential reaches the config file"
fi

# --- 3d-ter. Every question is actually printed ------------------------------
# `read -p` prints its prompt only when *stdin* is a terminal. The documented
# way to install this is `curl -fsSL … | bash`, where stdin is the script being
# piped in — so all forty-odd questions printed nothing, and the terminal sat
# at a blank line waiting for an answer to a question it had never shown. Whole
# sections of the installer looked empty.
#
# Nothing in bash -n, shellcheck or an automated run catches this: the reads
# still work, so the installer completes. It is only visible to a human at a
# terminal, which is why it survived several releases.
echo "== prompts are printed, not passed to read -p =="
BAD=$(grep -nE 'read +-[a-zA-Z]*p[a-zA-Z]* ' install.sh uninstall.sh || true)
if [ -n "${BAD}" ]; then
    fail "read -p used for a prompt (invisible under 'curl | bash'):"
    echo "${BAD}" | sed 's/^/         /'
else
    ok "no read -p prompts in the installer or uninstaller"
fi
ASKS=$(grep -cE '^[[:space:]]*ask(_secret)? ' install.sh)
if [ "${ASKS}" -lt 30 ]; then
    fail "only ${ASKS} ask()/ask_secret() prompts — did the conversion get reverted?"
else
    ok "${ASKS} questions go through the printing helpers"
fi

# --- 3d-quater. Config values are shell-quoted --------------------------------
# The config file is `source`d as root by every cron run. The installer wrote
# answers into a double-quoted heredoc raw, so a password containing "$" killed
# every run with "unbound variable" (before notify_fatal, so silently), a token
# containing a backtick executed as root weekly, and a value containing a quote
# made the file unparseable. Nothing showed it: the file on disk looked right.
#
# update-everything.sh's own comment asserts "anything the panel or installer
# wrote is single-quoted". This keeps that true.
echo "== config values are shell-quoted =="
CONF_BODY=$(sed -n '/^cat > "${CONFIG_FILE}" <<CONF$/,/^CONF$/p' install.sh \
            | grep -E '^[A-Z0-9_]+=')
RAW=$(echo "${CONF_BODY}" | grep -vE '^[A-Z0-9_]+=\$\(sq ' || true)
if [ -n "${RAW}" ]; then
    fail "config values written without sq():"
    echo "${RAW}" | sed 's/^/         /'
else
    ok "all $(echo "${CONF_BODY}" | wc -l | tr -d ' ') config values go through sq()"
fi

# --- 3d-quinquies. The three schedule parsers agree --------------------------
# UPDATE_SCHEDULES is parsed in three places: the installer (to build the
# crontab), the update script (for --doctor), and the panel (in Python). They
# have to read the same string the same way, or the panel shows one thing while
# cron runs another — and the only symptom is a host that reboots on a week it
# should not have.
echo "== schedule format is parsed the same everywhere =="
SCHED_A=$(sed -n '/^parse_schedules() {/,/^}/p' install.sh)
SCHED_B=$(sed -n '/^parse_schedules() {/,/^}/p' update-everything.sh)
if [ -z "${SCHED_A}" ] || [ -z "${SCHED_B}" ]; then
    fail "parse_schedules() missing from install.sh or update-everything.sh"
elif [ "${SCHED_A}" != "${SCHED_B}" ]; then
    fail "the two shell copies of parse_schedules() have drifted apart"
else
    ok "install.sh and update-everything.sh share one parse_schedules()"
fi

if have_python3; then
    if python3 - <<'PYCHECK'
import io, re, sys
src = io.open('webui/pve-autoupdate-ui', encoding='utf-8').read()
ns = {'re': re}
for pat in [r'^SCHEDULE_MODES = .*$',
            r'^def parse_schedules\(raw, legacy_cron=""\):\n(?:(?: |\t).*\n|\n)*?(?=\n\n)',
            r'^def format_schedules\(items\):\n(?:(?: |\t).*\n|\n)*?(?=\n\n)']:
    m = re.search(pat, src, re.M)
    if not m:
        sys.exit("panel is missing " + pat[:30])
    exec(m.group(0), ns)
P, F = ns['parse_schedules'], ns['format_schedules']
raw = "0 23 * * 5|no|Weekly;0 3 1 * *|only|Window;0 4 * * 0|yes|Sunday"
items = P(raw)
if [i['mode'] for i in items] != ['no', 'only', 'yes']:
    sys.exit("panel parsed %r wrongly: %r" % (raw, items))
if F(items) != raw:
    sys.exit("round-trip changed the value: %r" % F(items))
# A bare expression, and the pre-1.9 fallback, must both still work.
if P("0 4 * * 1")[0]['mode'] != 'yes':
    sys.exit("a bare cron expression must default to updating and rebooting")
if P("", "0 9 * * 1") != [{"cron": "0 9 * * 1", "mode": "yes", "label": "Updates"}]:
    sys.exit("legacy UPDATE_SCHEDULE_CRON fallback is broken")
# An unrecognised mode must fall back to the safe one, never be passed through
# to a crontab line as a flag.
if P("0 4 * * 1|banana|x")[0]['mode'] != 'yes':
    sys.exit("an unknown mode must fall back to 'yes'")
PYCHECK
    then
        ok "the panel parses the same format, and round-trips it unchanged"
    else
        fail "the panel's schedule parsing disagrees with the shell copies"
    fi
else
    ok "python3 not available — skipped (CI always has it)"
fi

# Every mode has to reach cron as the right flag, and the updater has to
# understand every flag the writers can emit — otherwise a schedule silently
# does something other than what the panel says it does.
FLAG_OK=1
for flag in --no-reboot --reboot-window; do
    for f in update-everything.sh install.sh webui/pve-autoupdate-ui; do
        grep -q -- "${flag}" "${f}" || { fail "${flag} is missing from ${f}"; FLAG_OK=0; }
    done
done
[ "${FLAG_OK}" -eq 1 ] && ok "--no-reboot and --reboot-window are emitted and understood"

# --- 3d-sexies. Typical install sets every key it is responsible for ---------
# A Typical install answers no questions, so every value the config file needs
# must come from apply_typical_profile() or from the seeded-from-PREV block.
# A setting added to the prompts but not to the profile leaves an unset variable
# on that path — and under `set -u` that is not a missing default, it is an
# abort partway through writing the config, on the install path most people use.
echo "== Typical install covers every setting =="
PROFILE=$(sed -n '/^apply_typical_profile() {/,/^}/p' install.sh)
KEEPPROF=$(sed -n '/^apply_keep_profile() {/,/^}/p' install.sh)
SEEDED=$(sed -n '/^# Everything the config file needs, seeded from/,/^echo ""$/p' install.sh)
CONF_KEYS=$(sed -n '/^cat > "${CONFIG_FILE}" <<CONF$/,/^CONF$/p' install.sh             | grep -oE '^[A-Z0-9_]+=' | tr -d '=')
# Written from a value the installer computes rather than one it is given.
COMPUTED="NTFY_PRIORITY DRY_RUN LOG_DIR"
MISSING=""
KEEP_MISSING=""
for key in ${CONF_KEYS}; do
    case " ${COMPUTED} " in *" ${key} "*) continue ;; esac
    grep -q "^\s*${key}=" <<<"${PROFILE}${SEEDED}"   || MISSING="${MISSING} ${key}"
    grep -q "^\s*${key}=" <<<"${KEEPPROF}${SEEDED}"  || KEEP_MISSING="${KEEP_MISSING} ${key}"
done
if [ -n "${MISSING}" ]; then
    fail "Typical install never sets:${MISSING}"
else
    ok "all $(echo "${CONF_KEYS}" | wc -w) config keys are set without asking"
fi
# Keep mode skips the prompts too, and used to rely on `source CONFIG_FILE`
# having incidentally bound them — which fails the moment a key is absent from
# an older config, after the heredoc has already truncated the file.
if [ -n "${KEEP_MISSING}" ]; then
    fail "keep/unattended install never sets:${KEEP_MISSING}"
else
    ok "keep mode sets every key explicitly, not via sourcing the old config"
fi

# The three prompt regions must stay behind asking(), or Typical starts
# interrogating people again.
GATES=$(grep -c '^if asking; then' install.sh)
if [ "${GATES}" -eq 3 ]; then
    ok "notifications, advanced settings and schedule are all gated on asking()"
else
    fail "expected 3 asking() gates in install.sh, found ${GATES}"
fi

# --- 3d-sexies. The injected block is valid JavaScript ------------------------
# This is appended to pvemanagerlib.js, which is a single script: one syntax
# error anywhere in it stops the *whole* file executing, so the entire Proxmox
# web UI loads blank. Recovery needs shell access on the node, which is exactly
# what someone who administers the box through that UI does not have to hand.
#
# It shipped. Two string literals in the block contained real newlines instead
# of `\n`, from an editing slip that `bash -n` cannot see — the shell is happy,
# because to the shell it is just text inside a heredoc. Nothing checked the
# JavaScript, so nothing caught it.
echo "== injected JavaScript parses =="
if ! command -v node >/dev/null 2>&1; then
    warn "node not available — skipped (CI installs it)"
else
    JS_TMP=$(mktemp -d)
    {
        echo "// stub"
        echo "Ext.define('PVE.StdWorkspace', {});"
        head -c 70000 /dev/zero | tr ' ' 'x' | fold -w 100 | sed 's|^|// |'
    } > "${JS_TMP}/pvemanagerlib.js"
    printf "WEB_UI_PORT='8007'
" > "${JS_TMP}/conf"
    if PAU_TARGET="${JS_TMP}/pvemanagerlib.js" PAU_BACKUP="${JS_TMP}/orig"        PAU_CONFIG="${JS_TMP}/conf" bash webui/patch-webui.sh apply >/dev/null 2>&1; then
        awk '/==== BEGIN proxmox-autoupdate button ====/,/==== END proxmox-autoupdate button ====/'             "${JS_TMP}/pvemanagerlib.js" > "${JS_TMP}/block.js"
        if [ ! -s "${JS_TMP}/block.js" ]; then
            fail "the patcher reported success but appended no block"
        elif node --check "${JS_TMP}/block.js" 2>"${JS_TMP}/err"; then
            ok "the block appended to pvemanagerlib.js parses as JavaScript"
        else
            fail "the injected block is NOT valid JavaScript — every patched node's web UI would load blank:"
            sed 's/^/         /' "${JS_TMP}/err" | head -6
        fi
        # The whole file has to parse too, not only the block in isolation.
        if node --check "${JS_TMP}/pvemanagerlib.js" >/dev/null 2>&1; then
            ok "the patched pvemanagerlib.js parses as a whole"
        else
            fail "the patched pvemanagerlib.js does not parse"
        fi
    else
        fail "patch-webui.sh apply failed against a stub pvemanagerlib.js"
    fi
    rm -rf "${JS_TMP}"
fi

# --- 3d-sexies-bis. Typical writes what the updater would have used ---------
# The panel's defaults are checked against update-everything.sh above. Nothing
# checked either against apply_typical_profile(), which is the thing that
# actually writes the config - and a value in the config beats the script's
# default. WINDOWS_UPDATE_TIMEOUT sat at 1200 there while both other places said
# 3600, so every Typical install gave a Windows guest twenty minutes for an
# update the tool's own help text calls an hour's work.
echo "== Typical profile matches the updater's defaults =="
if ! have_python3; then
    ok "python3 not available — skipped (CI always has it)"
else
python3 - <<'PYCHECK'
import io, re, sys

install = io.open("install.sh", encoding="utf-8").read()
script = io.open("update-everything.sh", encoding="utf-8").read()

profile = re.search(r"^apply_typical_profile\(\) \{(.*?)^\}", install, re.S | re.M).group(1)
written = dict(re.findall(r'^\s*([A-Z0-9_]+)="([^"$]*)"\s*$', profile, re.M))

# Deliberate differences, with the reason. Typical prints each of these in its
# summary, so nobody is surprised by them.
INTENTIONAL = {
    "REBOOT_TIME": "Typical reboots at 02:00; the bare default is midnight",
}

ARITH = re.compile(r"\A\$\(\(([0-9+\-*/ ()]+)\)\)\Z")


def value(text):
    m = ARITH.match(text.strip())
    if not m:
        return text
    try:
        return str(eval(m.group(1), {"__builtins__": {}}, {}))
    except Exception:
        return text


bad = 0
checked = 0
for key in sorted(written):
    m = re.search(r'^%s="\$\{%s:-([^}]*)\}"' % (key, key), script, re.M)
    if not m:
        continue
    checked += 1
    if value(written[key]) == value(m.group(1)):
        continue
    if key in INTENTIONAL:
        print("  [ ok ] %s differs on purpose: %s" % (key, INTENTIONAL[key]))
        continue
    print("  [FAIL] %s: Typical writes %s, overriding the %s update-everything.sh "
          "would use" % (key, written[key], m.group(1)))
    bad = 1
if not bad:
    print("  [ ok ] %d Typical values match the updater" % checked)
sys.exit(bad)
PYCHECK
[ $? -eq 0 ] || FAILED=1
fi

# --- 3d-septies. The panel's own JavaScript parses ---------------------------
# PAGE_TEMPLATE and GUEST_TEMPLATE each carry a script block, and SHARED_JS is
# spliced into both. None of it was ever parsed by anything: a stray token would
# ship, the service would stay healthy, the port would keep answering 200, and
# the page would be blank. That is the pvemanagerlib failure again, one file
# over.
echo "== panel JavaScript parses =="
if ! command -v node >/dev/null 2>&1; then
    warn "node not available — skipped (CI installs it)"
elif ! have_python3; then
    ok "python3 not available — skipped (CI always has it)"
else
    JS_OUT=$(mktemp -d)
    if python3 - "${JS_OUT}" <<'PYEXTRACT'
import io, os, re, sys

out_dir = sys.argv[1]
src = io.open("webui/pve-autoupdate-ui", encoding="utf-8").read()


def block(name):
    i = src.index(name + ' = r"""')
    j = src.index('"""', i + len(name) + 8)
    return src[i + len(name) + 8:j]


shared = block("SHARED_JS")
for tpl in ("PAGE_TEMPLATE", "GUEST_TEMPLATE"):
    page = (block(tpl)
            .replace("{{JS}}", shared)
            .replace("{{CONFIRM_UPDATES}}", "true")
            .replace("{{CSRF}}", "t").replace("{{USER}}", "root@pam")
            .replace("{{BASE}}", "").replace("{{VMID}}", "101")
            .replace("{{NAME}}", "guest").replace("{{CSS}}", ""))
    js = "\n".join(re.findall(r"<script>(.*?)</script>", page, re.S))
    if not js.strip():
        sys.exit("no script block found in " + tpl)
    io.open(os.path.join(out_dir, tpl + ".js"), "w", encoding="utf-8").write(js)
PYEXTRACT
    then
        JS_OK=1
        for tpl in PAGE_TEMPLATE GUEST_TEMPLATE; do
            if node --check "${JS_OUT}/${tpl}.js" 2>"${JS_OUT}/err"; then
                ok "${tpl} JavaScript parses"
            else
                fail "${tpl} JavaScript does NOT parse — the panel would load blank:"
                sed 's/^/         /' "${JS_OUT}/err" | head -5
                JS_OK=0
            fi
        done
        [ "${JS_OK}" -eq 1 ] || true
    else
        fail "could not extract the panel's script blocks"
    fi
    rm -rf "${JS_OUT}"
fi

# --- 3e. No faint text -------------------------------------------------------
# \033[2m is rendered at very low contrast by xterm.js, which is what the
# Proxmox web shell uses — it made roughly a third of the installer invisible
# in the terminal most people run it from.
echo "== no faint-attribute colour =="
if grep -qs "C_DIM='\\\\033\[2m'" install.sh uninstall.sh update-everything.sh webui/patch-webui.sh; then
    fail "a script still sets C_DIM to the faint attribute (\\033[2m); use \\033[90m"
else
    ok "no script uses the faint attribute for dim text"
fi

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
    # Strip comments before looking for bashisms. Scanning the raw text meant
    # prose tripped the check — a comment containing the word "local" failed the
    # build with "contains bashisms" while dash parsed the script perfectly.
    if grep -qE '\[\[|<<<|\blocal\b|\bdeclare\b' \
         <<<"$(sed 's/[[:space:]]*#.*$//' <<<"${GUEST}")"; then
        fail "generated guest script contains bashisms"
    else
        ok "no bashisms in the generated guest script"
    fi
else
    fail "could not extract the guest script from build_guest_update_script"
fi

# --- 5b. Every advertised package manager is actually handled ----------------
# The README lists the distro families this supports. Alpine was listed for a
# long time while its branch was unreachable, so the list and the code are
# checked against each other rather than trusted.
echo "== distro coverage =="
if [ -n "${GUEST}" ]; then
    COVER_OK=1
    for PM in apt-get dnf yum apk zypper pacman; do
        if grep -q "command -v ${PM}" <<<"${GUEST}"; then
            ok "${PM} branch present"
        else
            fail "${PM} is advertised but has no branch in the guest script"
            COVER_OK=0
        fi
    done
    [ "${COVER_OK}" -eq 1 ] && ok "all six package managers handled"
    # A runtime present but unmanaged must be reported, not silently ignored.
    if grep -q '__CONTAINERS__' <<<"${GUEST}"; then
        ok "container runtimes are detected and reported"
    else
        fail "guest script no longer reports container runtimes"
    fi
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
