#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${ALTIUM_LINUX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/altium-on-linux}"
WINE_GIT_URL="${ALTIUM_WINE_GIT_URL:-https://gitlab.winehq.org/wine/wine.git}"

REPO_DIR="$DATA_DIR/wine-src"
WORKTREE_DIR="$DATA_DIR/src-current"
BUILD_DIR="$DATA_DIR/build64-current"
CUSTOM_DLLS_DIR="$DATA_DIR/custom-dlls"
DIST_DIR="$DATA_DIR/custom-wine-dist"

DEFAULT_PREFIX="$HOME/.wine-prefixes/altium"
TARGET_PREFIX="${WINEPREFIX:-$DEFAULT_PREFIX}"
STAMP_FILE="$DIST_DIR/.patched-wine-stamp"
LOCK_FILE="/tmp/altium-wine-autopatch-${UID:-$(id -u)}.lock"

PATCHES_DIR=""
BINARIES_DIR=""
FORCE=0
CHECK_ONLY=0
NO_GUI=0

show_help() {
    cat << EOF
Utilizzo: $(basename "$0") [OPZIONI]

Verifica che i moduli Wine custom usati da Altium Designer corrispondano alla
versione di Wine installata sul sistema. Se Wine viene aggiornato (o differisce
dai binari precompilati), scarica i sorgenti upstream, applica le patch e
ricompila automaticamente i soli moduli modificati.

Opzioni:
  --prefix <DIR>        Percorso del Wine prefix (default: $DEFAULT_PREFIX)
  --binaries-dir <DIR>  Directory con binari precompilati (default: auto)
  --patches-dir <DIR>   Directory con i file .patch (default: auto)
  --check-only          Verifica soltanto; esce 0 se allineato, 1 altrimenti
  --force               Forza la ricompilazione da sorgente
  --no-gui              Disabilita dialoghi Zenity / notifiche desktop
  -h, --help            Mostra questo messaggio
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --no-gui) NO_GUI=1; shift ;;
        --prefix) TARGET_PREFIX="$2"; shift 2 ;;
        --binaries-dir) BINARIES_DIR="$2"; shift 2 ;;
        --patches-dir) PATCHES_DIR="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Opzione sconosciuta: $1" >&2; exit 2 ;;
    esac
done

TARGET_PREFIX="$(realpath -m "$TARGET_PREFIX")"

if [[ -z "$PATCHES_DIR" ]]; then
    if [[ -f "$DATA_DIR/patches/00-full-wine-11.20-altium-fluid.patch" ]]; then
        PATCHES_DIR="$DATA_DIR/patches"
    elif [[ -f "$SCRIPT_DIR/patches/00-full-wine-11.20-altium-fluid.patch" ]]; then
        PATCHES_DIR="$SCRIPT_DIR/patches"
    fi
fi

if [[ -z "$BINARIES_DIR" ]] && [[ -d "$SCRIPT_DIR/binaries" ]]; then
    BINARIES_DIR="$SCRIPT_DIR/binaries"
fi

detect_system_wine() {
    SYS_WINE_BIN="$(command -v wine 2>/dev/null || command -v wine64 2>/dev/null || true)"
    if [[ -z "$SYS_WINE_BIN" ]] || [[ ! -x "$SYS_WINE_BIN" ]]; then
        echo "Wine di sistema non trovato nel PATH." >&2
        return 1
    fi

    local resolved_bin bin_dir prefix_guess
    resolved_bin="$(readlink -f "$SYS_WINE_BIN" 2>/dev/null || echo "$SYS_WINE_BIN")"
    bin_dir="$(dirname "$resolved_bin")"
    prefix_guess="$(cd "$bin_dir/.." 2>/dev/null && pwd || echo "/usr")"

    local lib_candidates=(
        "${resolved_bin%/x86_64-unix/*}"
        "$prefix_guess/lib/wine"
        "$prefix_guess/lib64/wine"
        "$prefix_guess/lib/x86_64-linux-gnu/wine"
        "/usr/lib/wine"
        "/usr/lib64/wine"
        "/usr/lib/x86_64-linux-gnu/wine"
        "/opt/wine-staging/lib/wine"
        "/opt/wine-devel/lib/wine"
        "/opt/wine-stable/lib/wine"
    )

    SYS_WINE_LIB=""
    local c
    for c in "${lib_candidates[@]}"; do
        if [[ -f "$c/x86_64-unix/ntdll.so" ]]; then
            SYS_WINE_LIB="$(realpath "$c")"
            break
        fi
    done

    if [[ -z "$SYS_WINE_LIB" ]]; then
        local found_ntdll
        found_ntdll="$(find /usr/lib* /opt/wine* -maxdepth 5 -path '*/x86_64-unix/ntdll.so' 2>/dev/null | head -n 1 || true)"
        if [[ -n "$found_ntdll" ]]; then
            SYS_WINE_LIB="$(dirname "$(dirname "$found_ntdll")")"
        fi
    fi

    if [[ -z "$SYS_WINE_LIB" ]] || [[ ! -f "$SYS_WINE_LIB/x86_64-unix/ntdll.so" ]]; then
        echo "Librerie Wine (x86_64-unix/ntdll.so) non trovate sul sistema." >&2
        return 1
    fi

    if [[ -x "$SYS_WINE_LIB/x86_64-unix/wine" ]]; then
        LOADER_BIN_NAME="wine"
    elif [[ -x "$SYS_WINE_LIB/x86_64-unix/wine64" ]]; then
        LOADER_BIN_NAME="wine64"
    else
        echo "Loader wine/wine64 non trovato in $SYS_WINE_LIB/x86_64-unix" >&2
        return 1
    fi

    local share_candidates=(
        "$prefix_guess/share/wine"
        "$(dirname "$SYS_WINE_LIB")/../share/wine"
        "$(dirname "$(dirname "$SYS_WINE_LIB")")/share/wine"
        "/usr/share/wine"
        "/usr/share/wine-staging"
        "/opt/wine-staging/share/wine"
        "/opt/wine-devel/share/wine"
        "/opt/wine-stable/share/wine"
    )

    SYS_WINE_SHARE=""
    for c in "${share_candidates[@]}"; do
        if [[ -d "$c" ]] && [[ -f "$c/wine.inf" ]]; then
            SYS_WINE_SHARE="$(realpath "$c")"
            break
        fi
    done
    if [[ -z "$SYS_WINE_SHARE" ]]; then
        for c in "${share_candidates[@]}"; do
            if [[ -d "$c" ]]; then
                SYS_WINE_SHARE="$(realpath "$c")"
                break
            fi
        done
    fi

    if [[ -z "$SYS_WINE_SHARE" ]]; then
        echo "Cartella share/wine di sistema non trovata." >&2
        return 1
    fi

    SYS_WINE_VER="$("$SYS_WINE_BIN" --version 2>/dev/null || echo "unknown")"
    WINE_TAG="${SYS_WINE_VER%% *}"
    local ntdll_stat
    ntdll_stat="$(stat -c '%Y-%s' "$SYS_WINE_LIB/x86_64-unix/ntdll.so")"
    SYS_STAMP="${SYS_WINE_VER}:${ntdll_stat}"
    DIST_LIB_DIR="$DIST_DIR/${SYS_WINE_LIB#/}"
    DIST_SHARE_DIR="$DIST_DIR/${SYS_WINE_SHARE#/}"
}

check_artifacts_present() {
    local required=(
        "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver"
        "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so"
        "$CUSTOM_DLLS_DIR/x86_64-windows/d2d1.dll"
        "$CUSTOM_DLLS_DIR/x86_64-windows/vbscript.dll"
        "$CUSTOM_DLLS_DIR/x86_64-windows/msado15.dll"
        "$DIST_DIR/current-wine"
        "$DIST_LIB_DIR/x86_64-unix/$LOADER_BIN_NAME"
        "$DIST_LIB_DIR/x86_64-unix/ntdll.so"
        "$DIST_LIB_DIR/x86_64-unix/win32u.so"
        "$DIST_LIB_DIR/x86_64-windows/d2d1.dll"
        "$DIST_LIB_DIR/x86_64-windows/vbscript.dll"
        "$DIST_LIB_DIR/x86_64-windows/msado15.dll"
    )
    local f
    for f in "${required[@]}"; do
        [[ -s "$f" ]] || return 1
    done
    return 0
}

sync_prefix_custom_dlls() {
    local sys32="$TARGET_PREFIX/drive_c/windows/system32"
    [[ -d "$sys32" ]] || return 0
    local dll
    for dll in d2d1.dll vbscript.dll msado15.dll; do
        local src="$CUSTOM_DLLS_DIR/x86_64-windows/$dll"
        local dst="$sys32/$dll"
        if [[ -s "$src" ]] && ! cmp -s "$src" "$dst" 2>/dev/null; then
            rm -f "$dst"
            cp -f "$src" "$dst"
        fi
    done
}

is_already_patched() {
    [[ -f "$STAMP_FILE" ]] || return 1
    [[ "$(cat "$STAMP_FILE" 2>/dev/null || true)" == "$SYS_STAMP" ]] || return 1
    check_artifacts_present || return 1
    return 0
}

ZENITY_PID=""
PROGRESS_FIFO=""

cleanup_ui() {
    exec 8>&- 2>/dev/null || true
    if [[ -n "$ZENITY_PID" ]]; then
        kill "$ZENITY_PID" 2>/dev/null || true
        ZENITY_PID=""
    fi
    if [[ -n "$PROGRESS_FIFO" ]] && [[ -p "$PROGRESS_FIFO" ]]; then
        rm -f "$PROGRESS_FIFO"
        PROGRESS_FIFO=""
    fi
}

notify_msg() {
    local urgency="$1"
    local title="$2"
    local body="$3"
    if [[ "$NO_GUI" -eq 0 ]] && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        command -v notify-send >/dev/null 2>&1 && notify-send -u "$urgency" "$title" "$body" >/dev/null 2>&1 || true
    fi
}

start_progress_ui() {
    if [[ "$NO_GUI" -eq 0 ]] && [[ ! -t 1 ]] && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1; then
        PROGRESS_FIFO="/tmp/altium-wine-progress-$$.fifo"
        mkfifo "$PROGRESS_FIFO"
        (zenity --progress --pulsate --no-cancel --auto-close \
            --title="Altium Designer — Aggiornamento Wine" \
            --text="Rilevato $SYS_WINE_VER non patchato.\nApplicazione patch e ricompilazione moduli custom in corso (circa 2-4 min)..." \
            < "$PROGRESS_FIFO" >/dev/null 2>&1 || true) &
        ZENITY_PID=$!
        exec 8>"$PROGRESS_FIFO"
    fi
}

fail_with_error() {
    local msg="$1"
    echo "[ERROR] $msg" >&2
    cleanup_ui
    notify_msg "critical" "Altium Designer — Errore patch Wine" "$msg"
    if [[ "$NO_GUI" -eq 0 ]] && [[ ! -t 1 ]] && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Altium Designer — Errore Auto-Patch Wine" --text="$msg" >/dev/null 2>&1 || true
    fi
    exit 1
}

patch_d2d1_dos_stub() {
    python3 - "$1" << 'EOF'
import sys
p = sys.argv[1]
with open(p, "rb") as f:
    b = bytearray(f.read())
if b[:2] != b"MZ":
    raise SystemExit(f"Non un PE valido: {p}")
lfanew = int.from_bytes(b[0x3c:0x40], "little")
# Rimuove la firma "Wine builtin DLL" affinché d2d1=n,b venga caricata da system32/
if lfanew >= 0x78:
    stub = b"\x0e\x1f\xba\x0e\x00\xb4\t\xcd!\xb8\x01L\xcd!This program cannot be run in DOS mode.$\x00\x00"
    b[0x40:0x78] = stub
elif b[0x40:0x50] == b"Wine builtin DLL":
    b[0x40:0x60] = b"\x00" * 32
with open(p, "wb") as f:
    f.write(b)
EOF
}

sync_custom_wine_dist() {
    rm -rf "$DIST_DIR/usr" "$DIST_DIR/opt" "$DIST_DIR/lib" "$DIST_DIR/lib64"
    mkdir -p \
        "$DIST_LIB_DIR/x86_64-unix" \
        "$DIST_LIB_DIR/x86_64-windows" \
        "$(dirname "$DIST_SHARE_DIR")"

    local f base
    for f in "$SYS_WINE_LIB"/x86_64-unix/*; do
        [[ -e "$f" ]] || continue
        ln -sfn "$f" "$DIST_LIB_DIR/x86_64-unix/$(basename "$f")"
    done
    for f in "$SYS_WINE_LIB"/x86_64-windows/*; do
        [[ -e "$f" ]] || continue
        ln -sfn "$f" "$DIST_LIB_DIR/x86_64-windows/$(basename "$f")"
    done
    if [[ -d "$SYS_WINE_LIB/i386-windows" ]]; then
        ln -sfn "$SYS_WINE_LIB/i386-windows" "$DIST_LIB_DIR/i386-windows"
    fi
    if [[ -d "$SYS_WINE_LIB/i386-unix" ]]; then
        ln -sfn "$SYS_WINE_LIB/i386-unix" "$DIST_LIB_DIR/i386-unix"
    fi
    ln -sfn "$SYS_WINE_SHARE" "$DIST_SHARE_DIR"

    # File loader reali allineati alla build di sistema (evita risoluzione /proc/self/exe verso /usr)
    for base in "$LOADER_BIN_NAME" wine-preloader wine64-preloader ntdll.so; do
        if [[ -e "$SYS_WINE_LIB/x86_64-unix/$base" ]]; then
            rm -f "$DIST_LIB_DIR/x86_64-unix/$base"
            cp -f "$SYS_WINE_LIB/x86_64-unix/$base" "$DIST_LIB_DIR/x86_64-unix/$base"
        fi
    done

    rm -f "$DIST_LIB_DIR/x86_64-unix/win32u.so"
    cp -f "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so" "$DIST_LIB_DIR/x86_64-unix/win32u.so"

    local dll
    for dll in d2d1.dll vbscript.dll msado15.dll; do
        rm -f "$DIST_LIB_DIR/x86_64-windows/$dll"
        cp -f "$CUSTOM_DLLS_DIR/x86_64-windows/$dll" "$DIST_LIB_DIR/x86_64-windows/$dll"
    done

    ln -sfn "$DIST_LIB_DIR/x86_64-unix/$LOADER_BIN_NAME" "$DIST_DIR/current-wine"
}

stop_prefix_wineserver() {
    if [[ -x "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" ]]; then
        WINEPREFIX="$TARGET_PREFIX" "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" -k 2>/dev/null || true
    fi
    WINEPREFIX="$TARGET_PREFIX" wineserver -k 2>/dev/null || true
    sleep 0.3
}

run_prefix_wineboot_if_needed() {
    local force_boot="${1:-0}"
    [[ -f "$TARGET_PREFIX/system.reg" ]] || return 0
    if [[ "$force_boot" -eq 0 ]] && [[ -f "$TARGET_PREFIX/.update-timestamp" ]] && [[ -f "$SYS_WINE_SHARE/wine.inf" ]]; then
        if [[ "$TARGET_PREFIX/.update-timestamp" -nt "$SYS_WINE_SHARE/wine.inf" ]]; then
            return 0
        fi
    fi
    echo "[$(date -Is)] Aggiornamento prefix Wine (wineboot -u)..."
    env WINEPREFIX="$TARGET_PREFIX" \
        WINEARCH="win64" \
        WINEDEBUG="-all" \
        WINEDLLOVERRIDES="mscoree,mshtml=" \
        WINESERVER="$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" \
        WINEDLLPATH="$CUSTOM_DLLS_DIR:$SYS_WINE_LIB/x86_64-unix:$SYS_WINE_LIB/x86_64-windows" \
        timeout 180 "$DIST_DIR/current-wine" wineboot -u || true
    WINEPREFIX="$TARGET_PREFIX" "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" -k 2>/dev/null || true
}

try_seed_prebuilt() {
    [[ -n "$BINARIES_DIR" ]] || return 1
    [[ -f "$BINARIES_DIR/VERSION" ]] || return 1
    local bin_ver
    bin_ver="$(tr -d '[:space:]' < "$BINARIES_DIR/VERSION" 2>/dev/null || true)"
    [[ "$bin_ver" == "$WINE_TAG" ]] || return 1

    local f
    for f in \
        "$BINARIES_DIR/x86_64-unix/wineserver" \
        "$BINARIES_DIR/x86_64-unix/win32u.so" \
        "$BINARIES_DIR/x86_64-windows/d2d1.dll" \
        "$BINARIES_DIR/x86_64-windows/vbscript.dll" \
        "$BINARIES_DIR/x86_64-windows/msado15.dll"; do
        [[ -s "$f" ]] || return 1
    done

    mkdir -p "$CUSTOM_DLLS_DIR/x86_64-unix" "$CUSTOM_DLLS_DIR/x86_64-windows" "$DIST_DIR"
    rm -f "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" \
          "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so" \
          "$CUSTOM_DLLS_DIR/x86_64-windows/d2d1.dll" \
          "$CUSTOM_DLLS_DIR/x86_64-windows/vbscript.dll" \
          "$CUSTOM_DLLS_DIR/x86_64-windows/msado15.dll"
    cp -f "$BINARIES_DIR/x86_64-unix/wineserver" "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver"
    cp -f "$BINARIES_DIR/x86_64-unix/win32u.so" "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so"
    chmod +x "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so"
    cp -f "$BINARIES_DIR/x86_64-windows/d2d1.dll" "$CUSTOM_DLLS_DIR/x86_64-windows/d2d1.dll"
    cp -f "$BINARIES_DIR/x86_64-windows/vbscript.dll" "$CUSTOM_DLLS_DIR/x86_64-windows/vbscript.dll"
    cp -f "$BINARIES_DIR/x86_64-windows/msado15.dll" "$CUSTOM_DLLS_DIR/x86_64-windows/msado15.dll"

    patch_d2d1_dos_stub "$CUSTOM_DLLS_DIR/x86_64-windows/d2d1.dll"
    sync_custom_wine_dist
    sync_prefix_custom_dlls
    run_prefix_wineboot_if_needed 0
    echo "$SYS_STAMP" > "$STAMP_FILE"
    return 0
}

check_build_deps() {
    local missing=()
    local cmd
    for cmd in git make flex bison python3 pkg-config gcc; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    local has_pe_compiler=0
    if command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; then
        has_pe_compiler=1
    elif command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        has_pe_compiler=1
    fi
    if [[ "$has_pe_compiler" -eq 0 ]]; then
        missing+=("clang+lld (o x86_64-w64-mingw32-gcc)")
    fi

    if command -v pkg-config >/dev/null 2>&1 && ! pkg-config --exists freetype2 2>/dev/null; then
        missing+=("freetype2-dev")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        fail_with_error "Per ricompilare le patch su $WINE_TAG mancano: ${missing[*]}.
Installa i pacchetti di build:
- Arch: sudo pacman -S --needed git make flex bison clang lld freetype2 pkgconf python
- Ubuntu/Debian: sudo apt install git make flex bison gcc-mingw-w64-x86-64 libfreetype-dev pkg-config python3
- Fedora: sudo dnf install git make flex bison mingw64-gcc freetype-devel pkgconf-pkg-config python3"
    fi
}

apply_repo_patches() {
    [[ -n "$PATCHES_DIR" ]] && [[ -d "$PATCHES_DIR" ]] || fail_with_error "Cartella patch non trovata ($PATCHES_DIR)."

    local patch_files=(
        "$PATCHES_DIR/00-full-wine-11.20-altium-fluid.patch"
        "$PATCHES_DIR/03-vbscript-axsite-iserviceprovider.patch"
        "$PATCHES_DIR/04-msado15-stream-savetofile.patch"
    )
    local p
    for p in "${patch_files[@]}"; do
        [[ -f "$p" ]] || fail_with_error "File patch mancante: $p"
        echo "[$(date -Is)] Applicazione $(basename "$p")..."
        if ! git -C "$WORKTREE_DIR" apply "$p" 2>/dev/null; then
            git -C "$WORKTREE_DIR" apply --3way "$p" \
                || fail_with_error "Conflitto applicando $(basename "$p") su $WINE_TAG. Controlla $LOG_FILE."
        fi
    done
}

detect_system_wine

if [[ "$FORCE" -eq 0 ]] && is_already_patched; then
    sync_prefix_custom_dlls
    exit 0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "Wine non ancora patchato per $SYS_STAMP"
    exit 1
fi

exec 9>"$LOCK_FILE"
flock -x 9

detect_system_wine
if [[ "$FORCE" -eq 0 ]] && is_already_patched; then
    sync_prefix_custom_dlls
    exit 0
fi

mkdir -p "$DATA_DIR" "$CUSTOM_DLLS_DIR/x86_64-unix" "$CUSTOM_DLLS_DIR/x86_64-windows" "$DIST_DIR"
mkdir -p "$(dirname "$TARGET_PREFIX")" "$TARGET_PREFIX"
LOG_FILE="$DATA_DIR/wine-autopatch.log"
: > "$LOG_FILE"

if [[ "$FORCE" -eq 0 ]] && try_seed_prebuilt >> "$LOG_FILE" 2>&1; then
    echo "[$(date -Is)] Installati binari precompilati per $WINE_TAG" >> "$LOG_FILE"
    exit 0
fi

check_build_deps

trap cleanup_ui EXIT
start_progress_ui
notify_msg "normal" "Altium Designer — Auto-Patch Wine" "Rilevato $SYS_WINE_VER: scaricamento e compilazione moduli patchati in corso..."

{
    echo "[$(date -Is)] Avvio auto-patch da sorgente per $SYS_STAMP (tag: $WINE_TAG)"
    stop_prefix_wineserver

    if [[ ! -d "$REPO_DIR/.git" ]]; then
        rm -rf "$REPO_DIR"
        git init "$REPO_DIR"
        git -C "$REPO_DIR" remote add origin "$WINE_GIT_URL"
    else
        git -C "$REPO_DIR" remote set-url origin "$WINE_GIT_URL" 2>/dev/null || true
    fi

    if ! git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/${WINE_TAG}" >/dev/null 2>&1; then
        echo "[$(date -Is)] Download tag upstream $WINE_TAG..."
        git -C "$REPO_DIR" fetch --depth 1 origin "refs/tags/${WINE_TAG}:refs/tags/${WINE_TAG}" \
            || fail_with_error "Impossibile scaricare il tag git '$WINE_TAG' da WineHQ. Verifica connessione o $LOG_FILE."
    fi

    git -C "$REPO_DIR" worktree prune 2>/dev/null || true
    if [[ -d "$WORKTREE_DIR" ]]; then
        git -C "$WORKTREE_DIR" reset --hard >/dev/null 2>&1 || true
        git -C "$WORKTREE_DIR" clean -fd >/dev/null 2>&1 || true
        git -C "$WORKTREE_DIR" checkout --detach "refs/tags/${WINE_TAG}"
    else
        git -C "$REPO_DIR" worktree add --detach "$WORKTREE_DIR" "refs/tags/${WINE_TAG}"
    fi

    apply_repo_patches

    echo "[$(date -Is)] Configurazione build per $WINE_TAG..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    (
        cd "$BUILD_DIR"
        CFG_ARCH_FLAG="--enable-win64"
        if grep -q -- '--enable-archs' ../src-current/configure 2>/dev/null; then
            CFG_ARCH_FLAG="--enable-archs=x86_64"
        fi
        ../src-current/configure "$CFG_ARCH_FLAG" --disable-tests --without-x
        echo "[$(date -Is)] Compilazione dei 5 moduli patchati ($(nproc) core)..."
        make -j"$(nproc)" \
            server/wineserver \
            dlls/win32u/win32u.so \
            dlls/d2d1/x86_64-windows/d2d1.dll \
            dlls/vbscript/x86_64-windows/vbscript.dll \
            dlls/msado15/x86_64-windows/msado15.dll
    ) || fail_with_error "Compilazione fallita su $WINE_TAG. Controlla $LOG_FILE."

    echo "[$(date -Is)] Installazione binari compilati..."
    rm -f "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" \
          "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so" \
          "$CUSTOM_DLLS_DIR/x86_64-windows/d2d1.dll" \
          "$CUSTOM_DLLS_DIR/x86_64-windows/vbscript.dll" \
          "$CUSTOM_DLLS_DIR/x86_64-windows/msado15.dll"
    cp -f "$BUILD_DIR/server/wineserver" "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver"
    cp -f "$BUILD_DIR/dlls/win32u/win32u.so" "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so"
    chmod +x "$CUSTOM_DLLS_DIR/x86_64-unix/wineserver" "$CUSTOM_DLLS_DIR/x86_64-unix/win32u.so"
    cp -f "$BUILD_DIR/dlls/d2d1/x86_64-windows/d2d1.dll" "$CUSTOM_DLLS_DIR/x86_64-windows/d2d1.dll"
    cp -f "$BUILD_DIR/dlls/vbscript/x86_64-windows/vbscript.dll" "$CUSTOM_DLLS_DIR/x86_64-windows/vbscript.dll"
    cp -f "$BUILD_DIR/dlls/msado15/x86_64-windows/msado15.dll" "$CUSTOM_DLLS_DIR/x86_64-windows/msado15.dll"

    patch_d2d1_dos_stub "$CUSTOM_DLLS_DIR/x86_64-windows/d2d1.dll"
    sync_custom_wine_dist
    sync_prefix_custom_dlls
    run_prefix_wineboot_if_needed 1

    # Libera spazio temporaneo di build mantenendo la cache git per aggiornamenti futuri
    rm -rf "$BUILD_DIR"
    git -C "$REPO_DIR" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"

    echo "$SYS_STAMP" > "$STAMP_FILE"
    echo "[$(date -Is)] Completato con successo per $SYS_STAMP"
} >> "$LOG_FILE" 2>&1

if [[ -n "$ZENITY_PID" ]]; then
    echo "100" >&8 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
fi
cleanup_ui
notify_msg "normal" "Altium Designer — Wine Patchato" "$SYS_WINE_VER patchato e sincronizzato con successo."
