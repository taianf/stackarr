#!/usr/bin/env bash
#
# apply-admin-password.sh - push STACKARR_ADMIN_PASSWORD into every Stackarr service.
#
#   ./scripts/apply-admin-password.sh           apply / re-apply
#   ./scripts/apply-admin-password.sh --check   report only, change nothing
#
# Credentials come from .env (STACKARR_ADMIN_USERNAME / STACKARR_ADMIN_PASSWORD).
# A blank STACKARR_ADMIN_PASSWORD means "skip syncing entirely".
#
# See the warning block in .env: one shared password across every service is a
# single point of compromise. Fine on a trusted LAN, never on the internet.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
CONFIG_ROOT="$ROOT/.stackarr/config"
MODE=apply

case "${1:-}" in
	--check) MODE=check ;;
	--help | -h)
		sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	"") ;;
	*)
		echo "usage: $(basename "$0") [--check]" >&2
		exit 2
		;;
esac

if [[ ! -f $ENV_FILE ]]; then
	echo "error: $ENV_FILE not found" >&2
	exit 1
fi

# Parse .env without exporting junk; only the keys we care about.
read_env() {
	sed -n "s/^[[:space:]]*$1=\(.*\)$/\1/p" "$ENV_FILE" | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

ADMIN_USER="$(read_env STACKARR_ADMIN_USERNAME)"
ADMIN_PASS="$(read_env STACKARR_ADMIN_PASSWORD)"
ADMIN_PASS="${ADMIN_PASS//\"/}"
ADMIN_PASS="${ADMIN_PASS//\'/}"

if [[ -z $ADMIN_PASS ]]; then
	echo "STACKARR_ADMIN_PASSWORD is blank in .env - nothing to sync."
	exit 0
fi

export ADMIN_USER ADMIN_PASS MODE CONFIG_ROOT ENV_FILE ROOT

if ! command -v python3 >/dev/null; then
	echo "error: python3 is required" >&2
	exit 1
fi

python3 - <<'PY'
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import time

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

CFG = os.environ["CONFIG_ROOT"]
ENV_FILE = os.environ["ENV_FILE"]
ROOT = os.environ["ROOT"]
USER = os.environ["ADMIN_USER"] or "admin"
PW = os.environ["ADMIN_PASS"].encode()
CHECK = os.environ["MODE"] == "check"

SERVARR = ("radarr", "sonarr", "lidarr", "prowlarr")
SERVARR_ITERATIONS = 10000

results = []  # (service, status, detail)
changed = False


def report(name, status, detail=""):
    global changed
    if status in ("updated", "mismatch", "error"):
        changed = True
    results.append((name, status, detail))


def docker(*args, check=False):
    return subprocess.run(("docker",) + args, capture_output=True, text=True, check=check)


def container_exists(name):
    return docker("inspect", "--type", "container", name).returncode == 0


def container_env(name, key):
    if not container_exists(name):
        return None
    env = docker("inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", name).stdout
    m = re.search(rf"^{re.escape(key)}=(.*)$", env, re.M)
    return m.group(1).strip() if m else None


def recreate_and_wait(service, env_key, container_env_key):
    """Force-recreate a service and confirm the new env actually took effect.

    `docker compose up` intermittently leaves the container in "Created" (a
    racing recreate, or a port clash) while still exiting 0, so the outcome is
    judged by inspecting the container, never by the exit code.
    """
    want = PW.decode()
    last_err = ""
    for attempt in range(3):
        up = subprocess.run(
            ("docker", "compose", "--profile", service, "up", "-d",
             "--force-recreate", service),
            cwd=ROOT, capture_output=True, text=True,
        )
        lines = (up.stderr or up.stdout).strip().splitlines()
        last_err = lines[-1][:70] if lines else ""

        for _ in range(30):
            state = docker("inspect", "--format", "{{.State.Status}}", service).stdout.strip()
            if state == "running" and container_env(service, container_env_key) == want:
                return True
            if state in ("created", "exited"):
                # Start it by hand; compose lost the race with its own recreate.
                docker("start", service)
            time.sleep(2)
    return False, last_err or "container did not come up with the new env"


def restart(name):
    """Stop -> mutate -> start, so the app reloads and never fights the writer."""
    if not container_exists(name):
        return False
    running = docker("inspect", "--format", "{{.State.Running}}", name).stdout.strip() == "true"
    if running:
        docker("stop", name)
    return True


def start(name):
    if container_exists(name):
        docker("start", name)


def reroot(path):
    """Config files are written as root inside containers; restore the host owner."""
    shutil.chown(path, user=os.getuid(), group=os.getgid())


# --------------------------------------------------------------------------- #
# Servarr (Radarr / Sonarr / Lidarr / Prowlarr)
# Password = base64( PBKDF2-HMAC-SHA512( pw, base64decode(Salt), Iterations, 32 ) )
# --------------------------------------------------------------------------- #
def servarr_hash(password, salt_b64, iterations):
    return base64.b64encode(
        hashlib.pbkdf2_hmac("sha512", password, base64.b64decode(salt_b64), iterations, 32)
    ).decode()


def servarr(name):
    db = os.path.join(CFG, name, f"{name}.db")
    if not os.path.exists(db):
        return report(name, "skipped", "no database")
    try:
        con = sqlite3.connect(db)
        rows = con.execute("SELECT Id, Username, Password, Salt, Iterations FROM Users").fetchall()
    except sqlite3.Error as e:
        return report(name, "error", f"sqlite: {e}")

    if not rows:
        return report(name, "error", "no user rows")

    bad = []
    for _id, uname, stored, salt, iters in rows:
        if uname != USER:
            continue
        if servarr_hash(PW, salt, int(iters or SERVARR_ITERATIONS)) == stored:
            continue
        bad.append((_id, uname))

    if CHECK:
        if not bad:
            return report(name, "ok", f"{USER} matches")
        return report(name, "mismatch", f"{USER} differs")

    if not bad:
        con.close()
        return report(name, "ok", f"{USER} already matches")

    was = restart(name)
    try:
        con = sqlite3.connect(db)
        for _id, uname in bad:
            salt = base64.b64encode(secrets.token_bytes(16)).decode()
            h = servarr_hash(PW, salt, SERVARR_ITERATIONS)
            con.execute(
                "UPDATE Users SET Password=?, Salt=?, Iterations=? WHERE Id=?",
                (h, salt, str(SERVARR_ITERATIONS), _id),
            )
        con.commit()
        reroot(db)
    except sqlite3.Error as e:
        con.close()
        start(name)
        return report(name, "error", f"sqlite: {e}")
    con.close()
    if was:
        start(name)
    report(name, "updated", f"{USER} re-hashed (fresh salt)")


# --------------------------------------------------------------------------- #
# qBittorrent 4.2+
#
# WebUI\Password_PBKDF2 = "@ByteArray(base64(salt):base64(pbkdf2))"
# PBKDF2-HMAC-SHA512, 100000 iterations, 64-byte output, 16-byte random salt.
# The "@ByteArray(...)" wrapper is Qt's QByteArray serialisation - without it
# the value is silently ignored and qBittorrent falls back to a random
# per-boot temp password.
#
# The container must be STOPPED before this file is written: a running
# qBittorrent rewrites the config from memory on shutdown and clobbers it.
# --------------------------------------------------------------------------- #
QBITTORRENT_ITERATIONS = 100000
QBITTORRENT_SALT_LEN = 16
QBITTORRENT_DK_LEN = 64


def qbittorrent_hash(password, salt):
    digest = hashlib.pbkdf2_hmac(
        "sha512", password, salt, QBITTORRENT_ITERATIONS, QBITTORRENT_DK_LEN
    )
    return f"@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(digest).decode()})"


def qbittorrent_match(path, password):
    """Verify the stored hash against the target password."""
    blob = None
    with open(path) as fh:
        for line in fh:
            if line.startswith("WebUI\\Password_PBKDF2"):
                # Qt quotes the value in the INI file; strip those, not just spaces.
                blob = line.split("=", 1)[1].strip().strip('"')
    if not blob:
        return None  # no password set: qBittorrent uses a random temp one
    if not blob.startswith("@ByteArray(") or not blob.endswith(")"):
        return False  # legacy/garbled value
    salt_b64, _, hash_b64 = blob[len("@ByteArray("):-1].partition(":")
    try:
        salt = base64.b64decode(salt_b64)
    except binascii.Error:
        return False
    return qbittorrent_hash(password, salt) == f"@ByteArray({salt_b64}:{hash_b64})"


def qbittorrent(path):
    cred = re.compile(
        r'^WebUI\\(Username|Password_PBKDF2|Password_Salt|Iterations|'
        r'AuthSubnetWhitelist|AuthSubnetWhitelistEnabled|LocalHostAuth)\b'
    )

    if CHECK:
        got = qbittorrent_match(path, PW)
        if got is None:
            return report("qbittorrent", "mismatch", "no password set (random temp per boot)")
        if got:
            return report("qbittorrent", "ok", "admin matches")
        return report("qbittorrent", "mismatch", "password differs")

    if qbittorrent_match(path, PW):
        return report("qbittorrent", "ok", "already matches")

    salt = secrets.token_bytes(QBITTORRENT_SALT_LEN)
    value = qbittorrent_hash(PW, salt)
    was = restart("qbittorrent")          # stop BEFORE writing, never after
    try:
        with open(path) as fh:
            lines = [l for l in fh.read().splitlines() if not cred.match(l)]
        i = lines.index("[Preferences]")
        lines[i + 1:i + 1] = [f'WebUI\\Username="{USER}"', f'WebUI\\Password_PBKDF2="{value}"']
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        reroot(tmp)
        os.chmod(tmp, 0o664)
        os.replace(tmp, path)
    except (OSError, ValueError) as e:
        if was:
            start("qbittorrent")
        return report("qbittorrent", "error", str(e)[:60])
    if was:
        start("qbittorrent")

    for _ in range(45):
        if qbittorrent_match(path, PW):
            break
        time.sleep(2)
    else:
        return report("qbittorrent", "error", "wrote the hash but it did not verify")
    report("qbittorrent", "updated", "PBKDF2-SHA512 hash written")


# --------------------------------------------------------------------------- #
# Bazarr - config.yaml auth.password = md5 hex
# --------------------------------------------------------------------------- #
def bazarr(path):
    with open(path) as fh:
        cfg = yaml.safe_load(fh) or {}
    auth = cfg.setdefault("auth", {})
    auth.setdefault("type", "form")
    auth["username"] = USER
    want = hashlib.md5(PW).hexdigest()

    if CHECK:
        if auth.get("password") == want and auth.get("username") == USER:
            return report("bazarr", "ok", f"{USER} matches")
        return report("bazarr", "mismatch", "password differs")

    if auth.get("password") == want and auth.get("username") == USER:
        return report("bazarr", "ok", "already matches")

    was = restart("bazarr")
    auth["password"] = want
    with open(path, "w") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False)
    reroot(path)
    if was:
        start("bazarr")
    report("bazarr", "updated", "md5 written")


# --------------------------------------------------------------------------- #
# PostgreSQL
# --------------------------------------------------------------------------- #
def scram_matches(password, verifier):
    """Check a password against pg_authid's SCRAM-SHA-256 verifier.

    Necessary because pg_hba.conf in this stack starts with `trust` rules, so a
    real connection attempt succeeds with any password and proves nothing.
    verifier: SCRAM-SHA-256$<iter>:<salt>$<StoredKey>:<ServerKey>
    """
    try:
        if not verifier or not verifier.startswith("SCRAM-SHA-256$"):
            return None
        _, params, keys = verifier.split("$", 2)
        iterations, salt_b64 = params.split(":", 1)
        stored_key = keys.split(":", 1)[0]
        salted = hashlib.pbkdf2_hmac("sha256", password, base64.b64decode(salt_b64), int(iterations))
        client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
        return base64.b64encode(hashlib.sha256(client_key).digest()).decode() == stored_key
    except (ValueError, binascii.Error):
        return None


def pg_verifier(pguser):
    q = docker(
        "exec", "database", "psql", "-U", pguser, "-tAc",
        f"SELECT coalesce(rolpassword,'') FROM pg_authid WHERE rolname='{pguser}';",
    )
    if q.returncode != 0:
        return None
    return q.stdout.strip()


def postgres():
    if not container_exists("database"):
        return report("postgres", "skipped", "container not present")
    # The superuser is the account that actually gates access here.
    pguser = read_env_value("DATABASE_SUPERUSER") or "postgres"

    def current():
        return scram_matches(PW, pg_verifier(pguser))

    if CHECK:
        got = current()
        if got is None:
            return report("postgres", "error", "could not read the stored verifier")
        if got:
            return report("postgres", "ok", f"{pguser} verifier matches")
        return report("postgres", "mismatch", f"{pguser} password differs")

    if current() is True:
        return report("postgres", "ok", "already matches")

    # psql only interpolates :'var' when reading SQL from stdin, and it escapes
    # embedded quotes correctly - important because the password comes from .env.
    alter = subprocess.run(
        (
            "docker", "exec", "-i", "database",
            "psql", "-U", pguser, "-v", "ON_ERROR_STOP=1", "-v", f"pw={PW.decode()}",
        ),
        input=f'ALTER ROLE "{pguser}" WITH PASSWORD :\'pw\';\n',
        capture_output=True, text=True,
    )
    if alter.returncode != 0:
        return report("postgres", "error", alter.stderr.strip()[:60] or "ALTER ROLE failed")
    if current() is not True:
        return report("postgres", "error", "verification after ALTER ROLE failed")
    report("postgres", "updated", f"{pguser} password set")


# --------------------------------------------------------------------------- #
# tinyMediaManager - password lives in the container env, so it needs a recreate
# --------------------------------------------------------------------------- #
def set_env_value(key, value):
    with open(ENV_FILE) as fh:
        text = fh.read()
    line = f"{key}={value}"
    pat = re.compile(rf"^{re.escape(key)}=.*$", re.M)
    if pat.search(text):
        text = pat.sub(line, text)
    else:
        if not text.endswith("\n"):
            text += "\n"
        text += line + "\n"
    with open(ENV_FILE, "w") as fh:
        fh.write(text)


def tinymediamanager():
    key = "TINYMEDIAMANAGER_PASSWORD"
    current = read_env_value(key) or container_env("tinymediamanager", "PASSWORD") or ""

    if CHECK:
        if current == PW.decode():
            return report("tinymediamanager", "ok", "env value matches (authoritative)")
        return report(
            "tinymediamanager", "mismatch",
            "env differs - rerun without --check to recreate the container",
        )

    if current != PW.decode():
        set_env_value(key, PW.decode())
    result = recreate_and_wait("tinymediamanager", key, "PASSWORD")
    if result is not True:
        return report("tinymediamanager", "error", result[1])
    report("tinymediamanager", "updated", "env set + container recreated")


def read_env_value(key):
    with open(ENV_FILE) as fh:
        m = re.search(rf"^{re.escape(key)}=(.*)$", fh.read(), re.M)
    return m.group(1).strip().strip("\"'") if m else ""


# --------------------------------------------------------------------------- #
# Stackarr web UI (port 7777)
#
# Credentials live in stackarr.db -> app_settings -> "stackarr.runtimeConfig",
# as JSON with USERNAME / PASSWORD fields. PASSWORD is compared verbatim with
# timingSafeEqual against the submitted password - it is stored in PLAINTEXT,
# not hashed, so do not sha1/md5 it. The shipped install uses a random 40-char
# hex string here, which is why admin/<shared password> does not work out of
# the box.
#
# The app owns this row and rewrites it, so stop it before editing.
# --------------------------------------------------------------------------- #
def stackarr(db):
    def read():
        con = sqlite3.connect(db)
        try:
            row = con.execute(
                "SELECT value FROM app_settings WHERE key='stackarr.runtimeConfig'"
            ).fetchone()
            return json.loads(row[0]) if row else None
        finally:
            con.close()

    try:
        cfg = read()
    except (sqlite3.Error, json.JSONDecodeError) as e:
        return report("stackarr", "error", str(e)[:60])
    if cfg is None:
        return report("stackarr", "error", "no stackarr.runtimeConfig row")

    if CHECK:
        if cfg.get("PASSWORD") == PW.decode() and cfg.get("USERNAME") == USER:
            return report("stackarr", "ok", f"{USER} matches")
        return report("stackarr", "mismatch", "web UI password differs")

    if cfg.get("PASSWORD") == PW.decode() and cfg.get("USERNAME") == USER:
        return report("stackarr", "ok", "already matches")

    was = restart("app")                 # stop first: the app rewrites this row
    try:
        cfg["USERNAME"] = USER
        cfg["PASSWORD"] = PW.decode()
        con = sqlite3.connect(db)
        con.execute(
            "UPDATE app_settings SET value=? WHERE key='stackarr.runtimeConfig'",
            (json.dumps(cfg),),
        )
        con.commit()
        con.close()
        reroot(db)
    except sqlite3.Error as e:
        if was:
            start("app")
        return report("stackarr", "error", f"sqlite: {e}")
    if was:
        start("app")

    for _ in range(60):
        try:
            cfg2 = read()
        except sqlite3.Error:
            cfg2 = None
        if cfg2 and cfg2.get("PASSWORD") == PW.decode():
            break
        time.sleep(2)
    else:
        return report("stackarr", "error", "wrote the value but it did not stick")
    report("stackarr", "updated", "web UI credentials written")


# --------------------------------------------------------------------------- #
for svc in SERVARR:
    servarr(svc)

sa = os.path.join(CFG, "stackarr.db")
if os.path.exists(sa):
    stackarr(sa)
else:
    report("stackarr", "skipped", "no stackarr.db")

qb = os.path.join(CFG, "qbittorrent", "qBittorrent", "qBittorrent.conf")
if os.path.exists(qb):
    try:
        qbittorrent(qb)
    except OSError as e:
        report("qbittorrent", "error", str(e)[:60])
else:
    report("qbittorrent", "skipped", "no qBittorrent.conf")

bz = os.path.join(CFG, "bazarr", "config", "config.yaml")
try:
    bazarr(bz) if os.path.exists(bz) else report("bazarr", "skipped", "no config.yaml")
except yaml.YAMLError as e:
    report("bazarr", "error", f"bad yaml: {e}")

postgres()
tinymediamanager()

# Services with no shared admin login, or hashes we refuse to forge.
report("recyclarr", "n/a", "no admin login (web UI uses a secret key)")
report("jellyfin", "manual", "PBKDF2-SHA512 with per-user salt; set by hand")

# --------------------------------------------------------------------------- #
width = max(len(n) for n, _, _ in results)
print()
print(f"  {'SERVICE'.ljust(width)}  STATUS    DETAIL")
print(f"  {'-' * width}  --------  {'-' * 52}")
for name, status, detail in results:
    print(f"  {name.ljust(width)}  {status.ljust(8)}  {detail}")
print()

if CHECK:
    drifted = [n for n, s, _ in results if s in ("mismatch", "error")]
    if drifted:
        print(f"  {len(drifted)} service(s) differ: {', '.join(drifted)}")
        sys.exit(1)
    print("  All synchronised services already match.")
else:
    done = [n for n, s, _ in results if s == "updated"]
    print(f"  Applied to: {', '.join(done) if done else 'nothing (already in sync)'}")
PY
