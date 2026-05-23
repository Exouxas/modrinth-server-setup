#!/usr/bin/env bash
# setup.sh — Download a Modrinth modpack and set up a Forge server.
# Usage: ./setup.sh <slug> [--version <version>] [--no-auto-update] [--agree-eula]

set -euo pipefail

MODRINTH_API="https://api.modrinth.com/v2"
USER_AGENT="modrinth-server-setup/1.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SLUG=""
PACK_VERSION=""
AUTO_UPDATE=true
AGREE_EULA=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <slug> [--version <version>] [--no-auto-update] [--agree-eula]" >&2
    exit 1
fi

# First positional argument is the slug
SLUG="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "Error: --version requires a non-empty value." >&2
                exit 1
            fi
            PACK_VERSION="$2"
            shift 2
            ;;
        --no-auto-update)
            AUTO_UPDATE=false
            shift
            ;;
        --agree-eula)
            AGREE_EULA=true
            shift
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Usage: $0 <slug> [--version <version>] [--no-auto-update] [--agree-eula]" >&2
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1" >&2
            echo "Usage: $0 <slug> [--version <version>] [--no-auto-update] [--agree-eula]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
echo "Modrinth Server Setup"
echo "  Slug:        $SLUG"
echo "  Version:     ${PACK_VERSION:-latest}"
echo "  Auto-update: $AUTO_UPDATE"
echo "  Agree EULA:  $AGREE_EULA"
echo

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: '$1' is required but not found in PATH." >&2
        exit 1
    fi
}
check_cmd curl
check_cmd unzip
check_cmd python3
check_cmd java

# ---------------------------------------------------------------------------
# Resolve version via Modrinth API
# ---------------------------------------------------------------------------
echo "Fetching version list for '$SLUG'..."
VERSIONS_JSON=$(curl -fsSL \
    -H "User-Agent: $USER_AGENT" \
    "$MODRINTH_API/project/$SLUG/version")

if [[ -z "$VERSIONS_JSON" || "$VERSIONS_JSON" == "[]" ]]; then
    echo "Error: No versions found for '$SLUG'. Check the slug and try again." >&2
    exit 1
fi

# Write versions JSON to a temp file so Python scripts can read it via a file
# argument (avoids combining <<heredoc and <<<string on the same command).
VERSIONS_TMP=$(mktemp)
echo "$VERSIONS_JSON" > "$VERSIONS_TMP"

if [[ -n "$PACK_VERSION" ]]; then
    # Find the specific requested version
    VERSION_JSON=$(python3 - "$VERSIONS_TMP" "$PACK_VERSION" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    versions = json.load(f)
target = sys.argv[2]
for v in versions:
    if v["version_number"] == target or v["id"] == target:
        print(json.dumps(v))
        sys.exit(0)
sys.exit(1)
PYEOF
    ) || {
        rm -f "$VERSIONS_TMP"
        echo "Error: Version '$PACK_VERSION' not found for '$SLUG'." >&2
        exit 1
    }
else
    # Pick the latest release, falling back to beta then alpha
    VERSION_JSON=$(python3 - "$VERSIONS_TMP" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    versions = json.load(f)
for vtype in ("release", "beta", "alpha"):
    for v in versions:
        if v["version_type"] == vtype:
            print(json.dumps(v))
            sys.exit(0)
sys.exit(1)
PYEOF
    ) || {
        rm -f "$VERSIONS_TMP"
        echo "Error: No usable versions found for '$SLUG'." >&2
        exit 1
    }
fi
rm -f "$VERSIONS_TMP"

RESOLVED_VERSION=$(echo "$VERSION_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['version_number'])")

# Extract primary .mrpack file URL and filename from the version object
read -r MRPACK_URL MRPACK_FILENAME < <(echo "$VERSION_JSON" | python3 -c "
import json, sys
v = json.load(sys.stdin)
for f in v['files']:
    if f.get('primary') or f['filename'].endswith('.mrpack'):
        print(f['url'], f['filename'])
        sys.exit(0)
sys.exit(1)
") || {
    echo "Error: No .mrpack file found in version '$RESOLVED_VERSION'." >&2
    exit 1
}

echo "  Resolved: $RESOLVED_VERSION"
echo "  File:     $MRPACK_FILENAME"
echo

# ---------------------------------------------------------------------------
# Download the .mrpack
# ---------------------------------------------------------------------------
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MRPACK_PATH="$WORK_DIR/$MRPACK_FILENAME"

if [[ -f "$MRPACK_PATH" ]]; then
    echo "Using cached .mrpack: $MRPACK_FILENAME"
else
    echo "Downloading $MRPACK_FILENAME..."
    curl -fL --progress-bar \
        -H "User-Agent: $USER_AGENT" \
        -o "$MRPACK_PATH" "$MRPACK_URL"
    echo "Downloaded."
fi
echo

# ---------------------------------------------------------------------------
# Read modrinth.index.json from the .mrpack (it is a zip file)
# ---------------------------------------------------------------------------
echo "Reading pack metadata..."
INDEX_JSON=$(unzip -p "$MRPACK_PATH" modrinth.index.json)

read -r MC_VERSION FORGE_VERSION < <(echo "$INDEX_JSON" | python3 -c "
import json, sys
deps = json.load(sys.stdin)['dependencies']
mc    = deps.get('minecraft', '')
forge = deps.get('forge', '')
other = [k for k in deps if k not in ('minecraft', 'forge')]
print(mc, forge, *other)
")

if [[ -z "$FORGE_VERSION" ]]; then
    OTHER_LOADERS=$(echo "$INDEX_JSON" | python3 -c "
import json, sys
deps = json.load(sys.stdin)['dependencies']
others = {k: v for k, v in deps.items() if k != 'minecraft'}
for k, v in others.items():
    print(f'  {k}: {v}')
")
    echo "Error: Only Forge modpacks are supported currently." >&2
    echo "  This pack's dependencies:" >&2
    echo "$OTHER_LOADERS" >&2
    exit 1
fi

echo "  Minecraft: $MC_VERSION"
echo "  Forge:     $FORGE_VERSION"
echo

# ---------------------------------------------------------------------------
# Create server directory
# ---------------------------------------------------------------------------
SERVER_DIR="$WORK_DIR/server"
mkdir -p "$SERVER_DIR"

# ---------------------------------------------------------------------------
# Download and run the Forge installer
# ---------------------------------------------------------------------------
FORGE_FULL="${MC_VERSION}-${FORGE_VERSION}"
FORGE_INSTALLER="forge-${FORGE_FULL}-installer.jar"
FORGE_INSTALLER_PATH="$SERVER_DIR/$FORGE_INSTALLER"
FORGE_URL="https://maven.minecraftforge.net/net/minecraftforge/forge/${FORGE_FULL}/${FORGE_INSTALLER}"

if [[ ! -f "$FORGE_INSTALLER_PATH" ]]; then
    echo "Downloading Forge installer ($FORGE_FULL)..."
    curl -fL --progress-bar \
        -H "User-Agent: $USER_AGENT" \
        -o "$FORGE_INSTALLER_PATH" "$FORGE_URL"
    echo "Downloaded."
fi

# Skip installation if Forge is already installed (libraries/ dir is the reliable indicator)
if [[ -d "$SERVER_DIR/libraries/net/minecraftforge" ]]; then
    echo "Forge already installed — skipping installer."
else
    echo "Running Forge installer (downloads the Minecraft server jar, may take a while)..."
    (cd "$SERVER_DIR" && java -jar "$FORGE_INSTALLER" --installServer .)
    # Clean up the installer log if it exists
    rm -f "$SERVER_DIR/${FORGE_INSTALLER}.log"
    echo "Forge installation complete."
fi
echo

# ---------------------------------------------------------------------------
# Extract overrides from the .mrpack into server/
# ---------------------------------------------------------------------------
echo "Extracting config overrides from .mrpack..."
TMP_DIR=$(mktemp -d)
# Always clean up the temp dir, even on error
trap 'rm -rf "$TMP_DIR"' EXIT

unzip -q "$MRPACK_PATH" -d "$TMP_DIR"

if [[ -d "$TMP_DIR/overrides" ]]; then
    cp -r "$TMP_DIR/overrides/." "$SERVER_DIR/"
    echo "Config overrides extracted."
else
    echo "No overrides/ folder in .mrpack — skipping."
fi
echo

# ---------------------------------------------------------------------------
# Download server-side mods
# ---------------------------------------------------------------------------
echo "Downloading server mods..."

python3 - "$SERVER_DIR" "$TMP_DIR/modrinth.index.json" << 'PYEOF'
import json, os, sys, urllib.request, shutil

server_dir = sys.argv[1]
index_path = sys.argv[2]

with open(index_path) as f:
    index = json.load(f)

mods_dir = os.path.join(server_dir, "mods")
disabled_dir = os.path.join(mods_dir, "disabled_clientonly")
os.makedirs(mods_dir, exist_ok=True)
os.makedirs(disabled_dir, exist_ok=True)

# Connector-wrapped Fabric mods that declare environment:client in their
# fabric.mod.json — they will crash Forge's dependency checker on a server.
CLIENT_ONLY_BLOCKLIST = {
    "continuity-3.0.0+1.20.1.forge.jar",
}

files = index["files"]
failed = []

for i, entry in enumerate(files, 1):
    env = entry.get("env", {})
    filename = os.path.basename(entry["path"])
    tag = f"[{i}/{len(files)}]"

    # Marked client-only in the index itself — skip entirely
    if env.get("server") == "unsupported":
        print(f"  {tag} Skip (client-only): {filename}")
        continue

    dest = os.path.join(mods_dir, filename)

    # Known server-crashing client-only mods — move out of mods/
    if filename in CLIENT_ONLY_BLOCKLIST:
        if os.path.exists(dest):
            shutil.move(dest, os.path.join(disabled_dir, filename))
            print(f"  {tag} Moved to disabled_clientonly: {filename}")
        else:
            print(f"  {tag} Skip (client-only blocklist): {filename}")
        continue

    if os.path.exists(dest):
        print(f"  {tag} Already exists: {filename}")
        continue

    url = entry["downloads"][0]
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
        with open(dest, "wb") as f:
            f.write(data)
        print(f"  {tag} Downloaded: {filename}")
    except Exception as e:
        failed.append((filename, str(e)))
        print(f"  {tag} FAILED: {filename}: {e}", file=sys.stderr)

print(f"\n  Done. {len(files) - len(failed)} mods processed, {len(failed)} failed.")
if failed:
    for name, err in failed:
        print(f"    FAILED: {name}: {err}", file=sys.stderr)
    sys.exit(1)
PYEOF
echo

# ---------------------------------------------------------------------------
# Fix file permissions
# Files extracted from a zip archive are often read-only, which causes
# AccessDeniedException on config and mods/.connector/ on first Forge boot.
# ---------------------------------------------------------------------------
echo "Fixing file permissions..."
python3 - "$SERVER_DIR" << 'PYEOF'
import os, stat, sys
root = sys.argv[1]
fixed = 0
for dirpath, dirs, fnames in os.walk(root):
    for fn in fnames:
        fp = os.path.join(dirpath, fn)
        try:
            mode = os.stat(fp).st_mode
            if not (mode & stat.S_IWRITE):
                os.chmod(fp, mode | stat.S_IWRITE)
                fixed += 1
        except OSError:
            pass
print(f"  Made {fixed} file(s) writable.")
PYEOF
echo

# ---------------------------------------------------------------------------
# Accept the Minecraft EULA
# ---------------------------------------------------------------------------
if [[ "$AGREE_EULA" == "true" ]]; then
    echo "eula=true" > "$SERVER_DIR/eula.txt"
    echo "EULA accepted — written to server/eula.txt."
else
    # Only warn on first setup; on updates the file already exists
    if [[ ! -f "$SERVER_DIR/eula.txt" ]]; then
        echo "NOTICE: EULA not accepted."
        echo "  Review https://aka.ms/MinecraftEULA, then either:"
        echo "    echo 'eula=true' > server/eula.txt"
        echo "  or re-run setup.sh with --agree-eula."
    fi
fi
echo

# ---------------------------------------------------------------------------
# Write .setup-config.json
# Stores setup metadata used by server/run.sh for auto-update.
# ---------------------------------------------------------------------------
SETUP_SH_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup.sh"

python3 - "$SERVER_DIR/.setup-config.json" \
    "$SLUG" "$RESOLVED_VERSION" "$AUTO_UPDATE" \
    "$MC_VERSION" "$FORGE_VERSION" "$SETUP_SH_PATH" << 'PYEOF'
import json, sys
out_path, slug, version, auto_update, mc, forge, setup_sh = sys.argv[1:]
config = {
    "slug":        slug,
    "version":     version,
    "auto_update": auto_update == "true",
    "minecraft":   mc,
    "forge":       forge,
    "setup_sh":    setup_sh,
}
with open(out_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
print("  Written: .setup-config.json")
PYEOF
echo

# ---------------------------------------------------------------------------
# Generate server/run.sh
# This overwrites the Forge-generated run.sh — our version replicates its
# launch logic while adding an auto-update check before each server start.
# ---------------------------------------------------------------------------
cat > "$SERVER_DIR/run.sh" << 'RUNSH'
#!/usr/bin/env bash
# run.sh — Start the Forge server, with optional Modrinth auto-update.
# Generated by setup.sh — the launch logic is safe to customise below the
# "Start the server" section, but keep the auto-update block intact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/.setup-config.json"
MODRINTH_API="https://api.modrinth.com/v2"
USER_AGENT="modrinth-server-setup/1.0"

# ---------------------------------------------------------------------------
# Read .setup-config.json
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG" ]]; then
    echo "Error: .setup-config.json not found. Was setup.sh run successfully?" >&2
    exit 1
fi

read_cfg() { python3 -c "import json; c=json.load(open('$CONFIG')); print(c['$1'])"; }

SLUG=$(read_cfg slug)
CURRENT_VERSION=$(read_cfg version)
AUTO_UPDATE=$(read_cfg auto_update)   # True or False (Python bool repr)
SETUP_SH=$(read_cfg setup_sh)

# ---------------------------------------------------------------------------
# Auto-update check
# ---------------------------------------------------------------------------
if [[ "$AUTO_UPDATE" == "True" ]]; then
    echo "[update] Checking for updates to '$SLUG'..."

    LATEST=$(curl -fsSL -H "User-Agent: $USER_AGENT" \
        "$MODRINTH_API/project/$SLUG/version" 2>/dev/null \
        | python3 -c "
import json, sys
versions = json.load(sys.stdin)
for vtype in ('release', 'beta', 'alpha'):
    for v in versions:
        if v['version_type'] == vtype:
            print(v['version_number'])
            sys.exit(0)
" 2>/dev/null || echo "")

    if [[ -z "$LATEST" ]]; then
        echo "[update] Could not reach Modrinth API — skipping update check."
    elif [[ "$LATEST" == "$CURRENT_VERSION" ]]; then
        echo "[update] Already up to date ($CURRENT_VERSION)."
    else
        echo "[update] Update available: $CURRENT_VERSION → $LATEST"
        if [[ -f "$SETUP_SH" ]]; then
            echo "[update] Running setup.sh to apply update..."
            bash "$SETUP_SH" "$SLUG" --version "$LATEST"
            echo "[update] Update complete."
        else
            echo "[update] Warning: setup.sh not found at '$SETUP_SH' — skipping update." >&2
        fi
    fi
else
    echo "[update] Auto-update disabled."
fi
echo

# ---------------------------------------------------------------------------
# Start the server
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"

# Find the Forge unix_args.txt — its path encodes the MC+Forge version
UNIX_ARGS=$(find "$SCRIPT_DIR/libraries/net/minecraftforge/forge" \
    -name "unix_args.txt" 2>/dev/null | head -1)

if [[ -z "$UNIX_ARGS" ]]; then
    echo "Error: Could not find Forge unix_args.txt under libraries/." \
         "Is Forge installed?" >&2
    exit 1
fi

# Collect extra JVM flags from user_jvm_args.txt (strip comments and blank lines)
JVM_OPTS=""
if [[ -f "$SCRIPT_DIR/user_jvm_args.txt" ]]; then
    JVM_OPTS=$(grep -v '^\s*#' "$SCRIPT_DIR/user_jvm_args.txt" \
               | grep -v '^\s*$' | tr '\n' ' ')
fi

echo "Starting Forge server..."
# shellcheck disable=SC2086
exec java $JVM_OPTS @"$UNIX_ARGS" nogui "$@"
RUNSH

chmod +x "$SERVER_DIR/run.sh"
echo "Generated: server/run.sh"
echo

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "============================================================"
echo " Setup complete!"
echo "  Pack:     $SLUG  $RESOLVED_VERSION"
echo "  MC:       $MC_VERSION   Forge: $FORGE_VERSION"
echo "  Server:   $SERVER_DIR"
echo
if [[ "$AGREE_EULA" != "true" && ! -f "$SERVER_DIR/eula.txt" ]]; then
    echo "  *** ACTION REQUIRED before first start ***"
    echo "  Accept the Minecraft EULA:"
    echo "    echo 'eula=true' > server/eula.txt"
    echo "  or re-run with --agree-eula."
    echo
fi
echo "  Configure RAM in server/user_jvm_args.txt (-Xms / -Xmx)."
echo
echo "  To start the server:"
echo "    cd server && ./run.sh"
echo "============================================================"
