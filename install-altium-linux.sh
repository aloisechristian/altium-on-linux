#!/usr/bin/env bash
# ==============================================================================
# Altium Designer Linux Installer & Auto-Patcher
# ==============================================================================
# Automates the setup of Altium Designer on Linux under Wine, automatically
# resolving known Linux/Wine issues:
#   1. Google OAuth / Browser sign-in in both Online Installer & Altium Designer
#   2. "External exception C06D007F ... Abstract error" menu crash (InheritWindowMonitor)
#   3. Black popup/context menus (DevExpress layered window/animation issues)
#   4. Black boxes / invisible text in WPF dialogs (Avalon hardware acceleration)
# ==============================================================================

set -eo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_succ() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
Utilizzo: $(basename "$0") [OPZIONI]

Opzioni:
  -p, --prefix <DIR>       Percorso del Wine prefix (default: ~/.wine-prefixes/altium)
  -i, --installer <FILE>   Percorso dell'eseguibile installer di Altium (.exe)
  --patch-only             Applica solo le patch a un'installazione già presente
  -y, --yes                Modalità non interattiva (accetta le impostazioni predefinite)
  -h, --help               Mostra questo messaggio di aiuto

Esempi:
  $(basename "$0")
  $(basename "$0") -i ~/Scaricati/AltiumDesignerSetup_26_11_1.exe
  $(basename "$0") -p ~/.wine-prefixes/altium26 -i /media/altium_offline/Setup.exe
  $(basename "$0") -p ~/.wine-prefixes/altium --patch-only
EOF
}

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${ALTIUM_LINUX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/altium-on-linux}"
TARGET_PREFIX="$HOME/.wine-prefixes/altium"
INSTALLER_PATH=""
NON_INTERACTIVE=false
PATCH_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prefix)
            TARGET_PREFIX="$2"
            shift 2
            ;;
        -i|--installer)
            INSTALLER_PATH="$2"
            shift 2
            ;;
        --patch-only)
            PATCH_ONLY=true
            shift
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_err "Opzione sconosciuta: $1"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}        Altium Designer - Installer & Patcher per Linux         ${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"
echo ""

# Check dependencies
log_info "Verifica delle dipendenze di sistema..."
MISSING_DEPS=()
for cmd in wine winetricks python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    log_err "Dipendenze mancanti: ${MISSING_DEPS[*]}"
    echo "Installa i pacchetti richiesti con il gestore pacchetti della tua distribuzione."
    exit 1
fi
log_succ "Tutte le dipendenze essenziali (wine, winetricks, python3) sono presenti."

# Interactive prompt for prefix if not non-interactive
if [[ "$NON_INTERACTIVE" = false ]]; then
    read -rp "$(echo -e "${BOLD}Percorso del Wine prefix [${TARGET_PREFIX}]: ${NC}")" USER_PREFIX_INPUT
    if [[ -n "$USER_PREFIX_INPUT" ]]; then
        TARGET_PREFIX="${USER_PREFIX_INPUT/#\~/$HOME}"
    fi
fi

TARGET_PREFIX="$(realpath -m "$TARGET_PREFIX")"
export WINEPREFIX="$TARGET_PREFIX"
export WINEARCH="win64"
export WINEDEBUG="-all"

# Check if Altium is already installed in this prefix
EXISTING_ALTIUM=""
for cand in "$TARGET_PREFIX/drive_c/Program Files/Altium"/AD* "$TARGET_PREFIX/drive_c/Program Files/Altium/Altium Designer"*; do
    if [[ -d "$cand" && (-f "$cand/X2.EXE" || -f "$cand/X2.exe") ]]; then
        EXISTING_ALTIUM="$cand"
        break
    fi
done

if [[ -n "$EXISTING_ALTIUM" && "$PATCH_ONLY" = false && -z "$INSTALLER_PATH" && "$NON_INTERACTIVE" = false ]]; then
    echo -e "${YELLOW}È stata rilevata un'installazione esistente di Altium Designer in:${NC}"
    echo "  $EXISTING_ALTIUM"
    read -rp "$(echo -e "${BOLD}Vuoi applicare direttamente le correzioni/patch senza reinstallare? [S/n]: ${NC}")" DIRECT_PATCH
    if [[ ! "$DIRECT_PATCH" =~ ^[nN] ]]; then
        PATCH_ONLY=true
    fi
fi

# Function to apply patches to installed Altium
apply_patches_and_finish() {
    local ALTIUM_DIR="$1"
    local X2_EXE="$ALTIUM_DIR/X2.EXE"
    [[ -f "$X2_EXE" ]] || X2_EXE="$ALTIUM_DIR/X2.exe"
    local AUTH_DLL="$ALTIUM_DIR/System/Altium.Identity.Authentication.dll"
    local IS_DOTNET_FX=false
    if [[ ! -f "$ALTIUM_DIR/hostfxr.dll" && ! -f "$ALTIUM_DIR/coreclr.dll" ]]; then
        IS_DOTNET_FX=true
    fi

    echo ""
    log_info "Applicazione delle correzioni ad Altium Designer..."

    # 0. Install Microsoft .NET Framework 4.8 for legacy .NET Framework versions (e.g. AD20/AD22)
    #    Wine Mono does not support ComInterfaceType.InterfaceIsIDispatch used by Altium.SDK.Interfaces.dll
    if [[ "$IS_DOTNET_FX" = true ]]; then
        if [[ ! -f "$TARGET_PREFIX/dosdevices/c:/windows/dotnet48.installed.workaround" ]]; then
            log_info "Rilevato Altium basato su .NET Framework 4.x: installazione di Microsoft .NET Framework 4.8 (dotnet48)..."
            wineserver -k 2>/dev/null || true
            LC_ALL=en_US.UTF-8 winetricks -q --force dotnet48 win10 || {
                log_warn "Winetricks dotnet48 completato con avvisi non critici. Verifica in corso..."
            }
            wineserver -w 2>/dev/null || true
            log_succ "Microsoft .NET Framework 4.8 configurato."
        else
            log_succ "Microsoft .NET Framework 4.8 già presente nel prefix."
        fi
    fi

    # 1. Patch Altium.Identity.Authentication.dll (presente nelle versioni con OAuth integrato, es. AD26)
    log_info "Verifica Patch OAuth in Altium.Identity.Authentication.dll..."
    if [[ -f "$AUTH_DLL" ]]; then
        python3 - << EOF
import os

path = "$AUTH_DLL"
with open(path, "rb") as f:
    data = bytearray(f.read())

pattern = bytes.fromhex("28 5f 00 00 0a 28 60 00 00 0a 2c")
pos = data.find(pattern)
if pos != -1:
    if not os.path.exists(path + ".bak"):
        with open(path + ".bak", "wb") as bf:
            bf.write(data)
    # Patch to call xdg-open directly
    patch = bytes.fromhex("72 a3 04 00 70 02 28 68 00 00 0a 26 2a")
    data[pos:pos+len(patch)] = patch
    with open(path, "wb") as f:
        f.write(data)
    print("Patch OAuth applicata con successo!")
else:
    print("Pattern Patch OAuth non trovato o già applicato.")
EOF
        log_succ "Patch OAuth verificata/applicata."
    else
        log_info "File Altium.Identity.Authentication.dll non presente in questa versione, patch OAuth saltata."
    fi

    # 2, 3, 4 & 4.2: Multi-version PE patches in X2.EXE
    #   - InheritWindowMonitor delay-import thunk (solo se presente nel PE Delay Import Directory, es. AD26)
    #   - TWinControl.CreateWnd ("Control has no parent window"), con risoluzione dinamica IAT stubs
    #   - CountAtoms telemetry loop
    #   - TViewComponent _AddRef prima di SetServerView (versioni legacy tipo AD20)
    log_info "Applicazione delle patch binarie su $(basename "$X2_EXE")..."
    python3 - << EOF
import os, re, shutil, struct

path = "$X2_EXE"
is_dotnet_fx = ("$IS_DOTNET_FX" == "true")
with open(path, "rb") as f:
    data = bytearray(f.read())
orig_snapshot = bytes(data)
modified = False

def parse_pe(buf):
    e_lfanew = struct.unpack_from("<I", buf, 0x3c)[0]
    nsec = struct.unpack_from("<H", buf, e_lfanew + 6)[0]
    ohsz = struct.unpack_from("<H", buf, e_lfanew + 20)[0]
    opth = e_lfanew + 24
    base = struct.unpack_from("<Q", buf, opth + 24)[0]
    dd = opth + 112
    secs = []
    for i in range(nsec):
        sec_off = opth + ohsz + i * 40
        name, vsz, sva, rsz, rp = struct.unpack_from("<8sIIII", buf, sec_off)
        secs.append((name, vsz, sva, rsz, rp, sec_off))
    return base, dd, secs

base, dd, secs = parse_pe(data)
_, tvsz, tsva, trsz, trp, tsec_off = secs[0]
tva = base + tsva

def rva2off(rva):
    for _, vsz, sva, rsz, rp, _ in secs:
        if sva <= rva < sva + max(vsz, rsz):
            return rp + (rva - sva)
    return None

def off2va(off):
    for _, vsz, sva, rsz, rp, _ in secs:
        if rp <= off < rp + rsz:
            return base + sva + (off - rp)
    return None

# --- 2. InheritWindowMonitor (via PE Delay Import Directory) ---
dimp_rva, _ = struct.unpack_from("<II", data, dd + 13 * 8)
iwm_diat_va = None
if dimp_rva:
    off = rva2off(dimp_rva)
    while off is not None:
        _, dll_rva, _, diat_rva, dint_rva = struct.unpack_from("<IIIII", data, off)
        if not dll_rva:
            break
        if dint_rva:
            io = rva2off(dint_rva)
            slot = 0
            while io is not None:
                ent, = struct.unpack_from("<Q", data, io + slot * 8)
                if not ent:
                    break
                if not (ent & (1 << 63)):
                    ho = rva2off(ent & 0x7fffffff) + 2
                    fn = data[ho:data.find(b"\x00", ho)].decode("ascii", "replace")
                    if fn == "InheritWindowMonitor":
                        iwm_diat_va = base + diat_rva + slot * 8
                        break
                slot += 1
        if iwm_diat_va is not None:
            break
        off += 32

if iwm_diat_va is not None:
    iwm_patch = bytes([0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3] + [0x90] * 10)
    iwm_patched = False
    for j in range(trsz - 16):
        if data[trp + j : trp + j + 4] == b"\x52\x48\x8d\x15":
            rel, = struct.unpack_from("<i", data, trp + j + 4)
            if tva + j + 8 + rel == iwm_diat_va:
                data[trp + j : trp + j + len(iwm_patch)] = iwm_patch
                modified = True
                iwm_patched = True
                print(f"Patch InheritWindowMonitor applicata all'offset {hex(trp + j)}!")
                break
    if not iwm_patched:
        print("Thunk InheritWindowMonitor già patchato.")
else:
    print("InheritWindowMonitor non presente nei delay-import, patch saltata.")

# --- 3. TWinControl.CreateWnd ("Control has no parent window") ---
sig_cw = bytes.fromhex("48 89 85 c8 00 00 00 eb 46 48 8d 4d 58")
idx_cw = data.find(sig_cw)
if idx_cw != -1:
    imp_rva, _ = struct.unpack_from("<II", data, dd + 1 * 8)
    iat_targets = {}
    if imp_rva:
        off = rva2off(imp_rva)
        while off is not None:
            ilt_rva, _, _, name_rva, iat_rva = struct.unpack_from("<IIIII", data, off)
            if not name_rva:
                break
            no = rva2off(name_rva)
            dll = data[no:data.find(b"\x00", no)].decode("ascii", "replace").lower()
            if dll == "user32.dll":
                io = rva2off(ilt_rva or iat_rva)
                slot = 0
                while io is not None:
                    ent, = struct.unpack_from("<Q", data, io + slot * 8)
                    if not ent:
                        break
                    if not (ent & (1 << 63)):
                        ho = rva2off(ent & 0x7fffffff) + 2
                        fn = data[ho:data.find(b"\x00", ho)].decode("ascii", "replace")
                        if fn in ("GetActiveWindow", "GetForegroundWindow"):
                            iat_targets[fn] = base + iat_rva + slot * 8
                    slot += 1
            off += 20

    stubs = {}
    for fn, target_iat in iat_targets.items():
        for j in range(trsz - 6):
            if data[trp + j] == 0xff and data[trp + j + 1] == 0x25:
                rel, = struct.unpack_from("<i", data, trp + j + 2)
                if tva + j + 6 + rel == target_iat:
                    stubs[fn] = tva + j
                    break

    if "GetActiveWindow" in stubs and "GetForegroundWindow" in stubs:
        pos = idx_cw + 9
        pos_va = off2va(pos)
        rel_active = struct.pack("<i", stubs["GetActiveWindow"] - (pos_va + 9))
        rel_fg = struct.pack("<i", stubs["GetForegroundWindow"] - (pos_va + 19))
        patch_cw = (
            b"\x48\x83\xec\x20"
            b"\xe8" + rel_active +
            b"\x48\x85\xc0\x75\x05"
            b"\xe8" + rel_fg +
            b"\x48\x83\xc4\x20\x48\x89\x85\xc8\x00\x00\x00\xeb\x26"
            + b"\x90" * 38
        )
        data[pos : pos + len(patch_cw)] = patch_cw
        modified = True
        print(f"Patch TWinControl.CreateWnd applicata all'offset {hex(pos)}!")
    else:
        print("ATTENZIONE: stub user32 GetActiveWindow/GetForegroundWindow non trovati.")
else:
    print("Pattern TWinControl.CreateWnd già patchato o non trovato.")

# --- 4. CountAtoms Telemetry Loop ---
sig_ca = bytes.fromhex("55 48 83 ec 40 48 8b ec 48 89 4d 50 c7 45 34 00 00 00 00 c7 45 2c 00 00 00 00 c7 45 30 00 c0 00 00")
idx_ca = data.find(sig_ca)
if idx_ca != -1:
    patch_ca = bytes([
        0xc7, 0x41, 0x18, 0x32, 0x00, 0x00, 0x00,
        0xc7, 0x41, 0x1c, 0x32, 0x00, 0x00, 0x00,
        0xc3,
    ]) + b"\x90" * (150 - 15)
    data[idx_ca : idx_ca + len(patch_ca)] = patch_ca
    modified = True
    print(f"Patch CountAtoms applicata all'offset {hex(idx_ca)}!")
else:
    print("Pattern CountAtoms già patchato o non trovato.")

# --- 4.2 TViewComponent _AddRef prima di SetServerView (AD20 .NET Framework) ---
m_s1 = list(re.finditer(rb"\x48\x89\xc3\x48\x89\xd9\x48\x8b\x55\x38\x48\x8b\x33\xff\x96\x28\x02\x00\x00.{100,400}?\x48\x89\xd9\x48\x8b\x03\xff\x90\x38\x02\x00\x00", data, re.S))
m_s2 = list(re.finditer(rb"\x48\x8b\x55\x78\x48\x8b\x45\x28\x48\x8b\x18\xff\x93\x28\x02\x00\x00.{8,24}?\x48\x8b\x45\x28\x48\x89\xc1\x48\x8b\x00\xff\x90\x38\x02\x00\x00", data, re.S))
if is_dotnet_fx and (m_s1 or m_s2):
    cave1 = bytes.fromhex("48 89 c3 48 83 ec 28 48 89 d9 48 8b 03 ff 90 38 02 00 00 48 89 d9 48 8b 55 38 48 8b 33 ff 96 28 02 00 00 48 83 c4 28 c3")
    cave2 = bytes.fromhex("48 83 ec 28 48 8b 4d 28 48 8b 01 ff 90 38 02 00 00 48 8b 4d 28 48 8b 55 78 48 8b 01 48 89 c3 ff 93 28 02 00 00 48 83 c4 28 c3")
    # Allocate aligned caves inside .text tail zero padding
    cave_off1 = trp + ((tvsz + 15) & ~15)
    cave_off2 = cave_off1 + ((len(cave1) + 15) & ~15)
    needed_vsz = (cave_off2 - trp) + len(cave2)
    next_sva = secs[1][2] if len(secs) > 1 else tsva + trsz
    if cave_off2 + len(cave2) <= trp + trsz and tsva + needed_vsz <= next_sva and all(b == 0 for b in data[cave_off1 : cave_off2 + len(cave2)]):
        data[cave_off1 : cave_off1 + len(cave1)] = cave1
        data[cave_off2 : cave_off2 + len(cave2)] = cave2
        if needed_vsz > tvsz:
            struct.pack_into("<I", data, tsec_off + 8, needed_vsz)
        cave1_va = off2va(cave_off1)
        cave2_va = off2va(cave_off2)
        for m in m_s1:
            s_off = m.start()
            l_off = m.end() - 12
            rel = struct.pack("<i", cave1_va - (off2va(s_off) + 5))
            data[s_off : s_off + 19] = b"\xe8" + rel + b"\x90" * 14
            data[l_off : l_off + 12] = b"\x90" * 12
        for m in m_s2:
            s_off = m.start()
            l_off = m.end() - 16
            rel = struct.pack("<i", cave2_va - (off2va(s_off) + 5))
            data[s_off : s_off + 17] = b"\xe8" + rel + b"\x90" * 12
            data[l_off : l_off + 16] = b"\x90" * 16
        modified = True
        print(f"Patch TViewComponent _AddRef applicata ({len(m_s1) + len(m_s2)} siti)!")
else:
    print("TViewComponent _AddRef già patchato o non necessario per questa versione.")

if modified:
    if not os.path.exists(path + ".orig"):
        with open(path + ".orig", "wb") as bf:
            bf.write(orig_snapshot)
    tmp_path = path + ".tmp"
    with open(tmp_path, "wb") as f:
        f.write(data)
    shutil.copymode(path, tmp_path)
    os.replace(tmp_path, path)
EOF
    log_succ "Patch binarie X2.EXE verificate/applicate."

    # 5. Patch Direct2D HWND Presentation in AdvSch.dll (FUseDC offset rilevato dinamicamente)
    log_info "Applicazione Patch rendering Direct2D schematico (PresentToWnd in AdvSch.dll)..."
    python3 - << EOF
import os, re, shutil

advsch_path = os.path.join(os.path.dirname("$X2_EXE"), "System", "AdvSch.dll")
if os.path.exists(advsch_path):
    with open(advsch_path, "rb") as f:
        data = bytearray(f.read())
    orig_snapshot = bytes(data)

    m1s = list(re.finditer(rb"\x80\xb8(..\x00\x00)\x00\x74\x2a\x48\x8b\x85", data))
    m2s = list(re.finditer(rb"\x48\x83\x79\x08\x00\x0f\x95\xc1\x88\x88(..\x00\x00)", data))
    pairs = [(a, b) for a in m1s for b in m2s if a.group(1) == b.group(1)]

    patched = False
    if pairs:
        m1, m2 = pairs[0]
        data[m1.start() + 7 : m1.start() + 9] = b"\xeb\x2a"
        data[m2.start() + 5 : m2.start() + 8] = b"\x31\xc9\x90"
        patched = True

    if patched:
        if not os.path.exists(advsch_path + ".orig"):
            with open(advsch_path + ".orig", "wb") as bf:
                bf.write(orig_snapshot)
        tmp_path = advsch_path + ".tmp"
        with open(tmp_path, "wb") as f:
            f.write(data)
        shutil.copymode(advsch_path, tmp_path)
        os.replace(tmp_path, advsch_path)
        print("Patch AdvSch.dll (Direct2D HWND PresentToWnd) applicata con successo!")
    else:
        print("AdvSch.dll già patchato o pattern non trovato.")
else:
    print("AdvSch.dll non trovato.")
EOF
    log_succ "Patch Direct2D schematico in AdvSch.dll verificata/applicata."

    # 5.1 Patch AdvSim.dll (Mixed Simulation mouse/hover hook flood)
    log_info "Verifica e patch AdvSim.dll (blocco hook flood su movimento mouse)..."
    python3 - << EOF
import os, glob

ext_pattern = os.path.join("$TARGET_PREFIX", "drive_c", "ProgramData", "Altium", "Altium Designer *", "Extensions", "Mixed Simulation", "AdvSim.dll")
matches = glob.glob(ext_pattern)
if matches:
    for advsim_path in matches:
        with open(advsim_path, "rb") as f:
            data = bytearray(f.read())

        sig_orig = bytes.fromhex("55 53 48 83 ec 38 48 8b ec 48 89 cb 48 8d 4d 28 e8 6b d7 d3 ff 48 8b 4d 28 b2 01")
        patch = bytes.fromhex("48 8b 81 b0 00 00 00 c3") # mov 0xb0(%rcx), %rax; ret

        idx = data.find(sig_orig)
        if idx != -1:
            if not os.path.exists(advsim_path + ".orig"):
                with open(advsim_path + ".orig", "wb") as bf:
                    bf.write(data)
            data[idx : idx + len(patch)] = patch
            with open(advsim_path, "wb") as f:
                f.write(data)
            print("Patch AdvSim.dll applicata con successo (offset " + hex(idx) + ")!")
        else:
            print("AdvSim.dll già patchato o pattern non trovato.")
else:
    print("AdvSim.dll non presente in questa installazione, patch saltata.")
EOF
    log_succ "Patch hook flood in AdvSim.dll verificata/applicata."

    # 4.1 Patch null pointer dereference in ScriptingSystem.dll
    python3 - << EOF
import os

dll_path = os.path.join(os.path.dirname("$X2_EXE"), "System", "ScriptingSystem.dll")
if os.path.exists(dll_path):
    with open(dll_path, "rb") as f:
        data = bytearray(f.read())

    sig_orig = bytes.fromhex("48 83 7d 40 00 74 3e 48 8b 45 40 48 8b 40 18 48 8b 08")
    patch = bytes.fromhex("48 85 c0 74 40 48 8b 40 18 48 85 c0 74 37 48 8b 08 90")

    idx = data.find(sig_orig)
    if idx != -1:
        if not os.path.exists(dll_path + ".orig"):
            with open(dll_path + ".orig", "wb") as bf:
                bf.write(data)
        data[idx : idx + len(patch)] = patch
        with open(dll_path + ".patched", "wb") as f:
            f.write(data)
        os.replace(dll_path + ".patched", dll_path)
        print("Patch ScriptingSystem.dll applicata con successo (offset " + hex(idx) + ")!")
    else:
        print("ScriptingSystem.dll già patchato o pattern non trovato.")
else:
    print("ScriptingSystem.dll non trovato.")
EOF
    log_succ "Patch null pointer dereference in ScriptingSystem.dll verificata/applicata."

    # 5. Install portable Wine auto-patcher, custom DLLs/SOs & custom-wine-dist
    log_info "Configurazione runtime Wine ottimizzato e auto-patcher in: $DATA_DIR"
    mkdir -p "$DATA_DIR/patches"
    if [[ -d "$SCRIPT_DIR/patches" ]]; then
        cp -f "$SCRIPT_DIR/patches/"*.patch "$DATA_DIR/patches/" 2>/dev/null || true
    fi
    if [[ -f "$SCRIPT_DIR/ensure-wine-patched.sh" ]]; then
        cp -f "$SCRIPT_DIR/ensure-wine-patched.sh" "$DATA_DIR/ensure-wine-patched.sh"
        chmod +x "$DATA_DIR/ensure-wine-patched.sh"
    fi
    if [[ -x "$DATA_DIR/ensure-wine-patched.sh" ]]; then
        ALTIUM_LINUX_DATA_DIR="$DATA_DIR" "$DATA_DIR/ensure-wine-patched.sh" \
            --prefix "$TARGET_PREFIX" \
            --patches-dir "$DATA_DIR/patches" \
            --binaries-dir "$SCRIPT_DIR/binaries"
        log_succ "Moduli Wine custom e runtime sincronizzati con la versione di sistema."
    else
        log_warn "ensure-wine-patched.sh non trovato in $SCRIPT_DIR; assicurati che l'intera repository sia stata clonata."
    fi

    # 5.2 Set BufferedPainting=1 across all Altium Schematic preference sections in user.reg
    log_info "Configurazione BufferedPainting=1 (UxTheme double-buffering per schematico fluido)..."
    python3 - << 'EOF'
import os, re

user_reg = os.path.expandvars("$TARGET_PREFIX/user.reg")
if os.path.exists(user_reg):
    with open(user_reg, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    content = re.sub(r'"BufferedPainting"="[0-9]+"', '"BufferedPainting"="1"', content)
    with open(user_reg, "w", encoding="utf-8") as f:
        f.write(content)
EOF

    local LAUNCHER_SCRIPT="$TARGET_PREFIX/start-altium.sh"
    local DXVK_CONF="$TARGET_PREFIX/dxvk.conf"
    log_info "Configurazione ottimizzazioni DXVK e memoria..."
    cat << EOF > "$DXVK_CONF"
# Limita i thread di compilazione shader Vulkan per evitare picchi di RAM massicci su CPU multi-core
dxvk.numCompilerThreads = 2

# Limita il framerate massimo a 60 FPS per evitare picchi a migliaia di FPS nei dialoghi/anteprime ECO
dxvk.maxFrameRate = 60
dxgi.maxFrameRate = 60

# Riduci il numero di backbuffer da 5 a 2 per risparmiare VRAM sui 2GB della GPU
dxgi.numBackBuffers = 2
d3d9.numBackBuffers = 2

# Riutilizzo aggressivo della memoria VRAM durante la rigenerazione di poligoni e modelli 3D
dxvk.allowMemoryReuse = True

# Ottimizzazione latenza presentazione e ridisegno immediato per CAD desktop (elimina il ritardo di ridisegno / box di selezione)
dxgi.syncInterval = 0
d3d11.syncInterval = 0
d3d9.presentInterval = 0
dxgi.maxFrameLatency = 1
d3d11.maxFrameLatency = 1
d3d9.maxFrameLatency = 1
dxgi.tearFree = False
dxgi.deferSurfaceCreation = True
d3d9.deferSurfaceCreation = True
EOF

    # 5.3 Apply Altium performance & network preferences dynamically for every detected Altium GUID in user.reg
    log_info "Applicazione preferenze Altium (Schematic/PCB/Network) sui profili rilevati..."
    local DYN_REG_FILE="/tmp/altium_dyn_fixes_$$.reg"
    python3 - << EOF > "$DYN_REG_FILE"
import os, re

user_reg = os.path.join("$TARGET_PREFIX", "user.reg")
guids = {"{098E92C5-2552-44B1-BA35-25D7FC633AAE}", "{F12855C5-BD21-4C4B-BDC8-9239BA72A9A5}"}
if os.path.exists(user_reg):
    with open(user_reg, "r", encoding="utf-8", errors="ignore") as f:
        for m in re.finditer(r"Software\\\\Altium\\\\Altium Designer (\{[0-9A-Fa-f-]+\})", f.read()):
            guids.add(m.group(1).upper())

print("Windows Registry Editor Version 5.00\n")
for g in sorted(guids):
    base = f"HKEY_CURRENT_USER\\\\Software\\\\Altium\\\\Altium Designer {g}\\\\DesignExplorer\\\\Preferences"
    print(f"""[{base}\\\\SCH\\\\Schematic Preferences]
"BufferedPainting"="1"
"AlwaysDrag"="0"
"SpatialAnalysisDuringDragging"="0"
"OptimizePolylines"="1"
"Display Printer Fonts"="0"

[{base}\\\\Schematic Preferences\\\\General]
"BufferedPainting"="1"

[{base}\\\\AdvPCB\\\\SystemOptions]
"UseAnimation"="0"
"UseSmoothZoom"="0"
"CleanRedraw"="1"

[{base}\\\\Client\\\\Client Preferences]
"Animated Panels"="0"
"Animation Speed"=dword:00000000
"Auto Transparent Toolbars"="0"
"Dynamic Auto Transparency"="0"
"AllowedNetworkActivity"="AltiumPortal;AltiumCloud;AltiumVault;Browser;LicenseServer;Suppliers"
"ConnectivityInsight"="0"
"ConnectivityInsightHoverPreview"="0"
"ConnectivityInsightHoverTextHint"="0"
"ConnectivityInsightHoverTree"="0"
"HyperlinkInsight"="0"
"HyperlinkInsightHoverEnabled"="0"
"DocumnetInsight"="0"
"ProjectInsight"="0"
""")
EOF
    WINEPREFIX="$TARGET_PREFIX" wine regedit "$DYN_REG_FILE" >/dev/null 2>&1 || true
    WINEPREFIX="$TARGET_PREFIX" wineserver -w 2>/dev/null || true
    rm -f "$DYN_REG_FILE"

    local ALTIUM_VER
    ALTIUM_VER="$(basename "$ALTIUM_DIR")"
    local LOCALE_LINE=""
    local EXTRA_CEF_FLAGS=""
    if [[ "$IS_DOTNET_FX" = true ]]; then
        LOCALE_LINE='export LC_ALL="${LC_ALL:-en_US.UTF-8}"'
        EXTRA_CEF_FLAGS="--disable-gpu --disable-gpu-compositing "
    fi

    log_info "Creazione dello script di avvio in: $LAUNCHER_SCRIPT"
    cat << EOF > "$LAUNCHER_SCRIPT"
#!/usr/bin/env bash
export WINEPREFIX="$TARGET_PREFIX"
export WINEARCH="win64"
export WINEDEBUG="\${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="d2d1=n,b;gdiplus=n,b;vbscript=n,b;msado15=n,b"
$LOCALE_LINE

# Disabilita VSync a livello driver e DXVK per ridisegno immediato e reattivo
export __GL_SYNC_TO_VBLANK=0
export vblank_mode=0
export DXVK_CONFIG_FILE="$DXVK_CONF"
export DXVK_HUD="\${DXVK_HUD:-0}"

# Forza NVIDIA GPU in modalità massime prestazioni (P0) se presente
if command -v nvidia-settings >/dev/null 2>&1; then
    DISPLAY="\${DISPLAY:-:0}" nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=1" >/dev/null 2>&1 || true
fi

# Verifica che i moduli Wine custom corrispondano al pacchetto Wine di sistema
DATA_DIR="\${ALTIUM_LINUX_DATA_DIR:-$DATA_DIR}"
ENSURE_PATCHED="\$DATA_DIR/ensure-wine-patched.sh"
if [[ -x "\$ENSURE_PATCHED" ]]; then
    ALTIUM_LINUX_DATA_DIR="\$DATA_DIR" "\$ENSURE_PATCHED" --prefix "\$WINEPREFIX" || exit 1
fi

DIST_WINE_BIN="\$DATA_DIR/custom-wine-dist/current-wine"
if [[ -x "\$DIST_WINE_BIN" ]]; then
    WINE_LIB_ROOT="\$(dirname "\$(dirname "\$(readlink -f "\$DIST_WINE_BIN")")")"
    export WINEDLLPATH="\$DATA_DIR/custom-dlls:\$WINE_LIB_ROOT/x86_64-unix:\$WINE_LIB_ROOT/x86_64-windows"
    WINE_BIN="\$DIST_WINE_BIN"
else
    export WINEDLLPATH="\$DATA_DIR/custom-dlls"
    WINE_BIN="wine"
fi

CUSTOM_WINESERVER="\$DATA_DIR/custom-dlls/x86_64-unix/wineserver"
if [[ -x "\$CUSTOM_WINESERVER" ]]; then
    export WINESERVER="\$CUSTOM_WINESERVER"
    NEED_START=1
    for ws_pid in \$(pidof wineserver 2>/dev/null || true); do
        WS_PREFIX=\$(tr '\0' '\n' < "/proc/\$ws_pid/environ" 2>/dev/null | sed -n 's/^WINEPREFIX=//p' | head -n 1 || true)
        [[ "\$WS_PREFIX" == "\$WINEPREFIX" ]] || continue
        EXE_PATH=\$(readlink -f "/proc/\$ws_pid/exe" 2>/dev/null || true)
        if [[ "\$EXE_PATH" == "\$CUSTOM_WINESERVER" ]]; then
            NEED_START=0
        else
            kill -9 "\$ws_pid" 2>/dev/null || true
            sleep 0.2
        fi
    done
    if [[ "\$NEED_START" -eq 1 ]]; then
        WINEPREFIX="\$WINEPREFIX" "\$CUSTOM_WINESERVER" -p
        sleep 0.3
    fi
fi

ALTIUM_EXE="$X2_EXE"

if [[ ! -f "\$ALTIUM_EXE" ]]; then
    echo "Eseguibile non trovato: \$ALTIUM_EXE"
    exit 1
fi

"\$WINE_BIN" "\$ALTIUM_EXE" ${EXTRA_CEF_FLAGS}--disable-gpu-sandbox --renderer-process-limit=2 --js-flags="--max-old-space-size=256" "\$@"
EOF
    chmod +x "$LAUNCHER_SCRIPT"
    log_succ "Script di avvio creato."

    # 4. Icon & Desktop Entry
    local ICON_PATH="$TARGET_PREFIX/altium.svg"
    if [[ ! -f "$ICON_PATH" ]]; then
        cat << 'EOF' > "$ICON_PATH"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="20" fill="#20232A"/>
  <path d="M 50 15 L 82 78 L 68 78 L 50 42 L 32 78 L 18 78 Z" fill="#F4B400"/>
  <path d="M 38 64 L 62 64 L 50 40 Z" fill="#20232A"/>
</svg>
EOF
    fi

    local DESKTOP_DIR="$HOME/.local/share/applications"
    mkdir -p "$DESKTOP_DIR"
    local DESKTOP_FILE="$DESKTOP_DIR/altium-designer.desktop"
    local DESKTOP_NAME="Altium Designer"
    if [[ "$TARGET_PREFIX" != "$HOME/.wine-prefixes/altium" && "$ALTIUM_VER" != "AD26" ]]; then
        local VER_SLUG
        VER_SLUG="$(echo "$ALTIUM_VER" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
        DESKTOP_FILE="$DESKTOP_DIR/altium-designer-${VER_SLUG}.desktop"
        DESKTOP_NAME="Altium Designer ($ALTIUM_VER)"
    fi
    cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Name=$DESKTOP_NAME
Comment=Altium Designer on Wine ($ALTIUM_VER)
Exec=$LAUNCHER_SCRIPT
Icon=$ICON_PATH
Terminal=false
Type=Application
Categories=Development;Electronics;Engineering;
StartupNotify=true
EOF

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
    log_succ "Collegamento desktop creato: $DESKTOP_FILE"

    # 5. Patch Altium Library Loader (AltiumLL.vbs) se presente
    local ALTIUM_LL_DIR="$TARGET_PREFIX/drive_c/users/$USER/Documents/AltiumLL"
    if [[ -f "$ALTIUM_LL_DIR/AltiumLL.vbs" ]]; then
        log_info "Verifica e patch Altium Library Loader (fix Base64 Wine)..."
        python3 - << 'EOF'
import os
vbs_path = os.path.expandvars("$TARGET_PREFIX/drive_c/users/$USER/Documents/AltiumLL/AltiumLL.vbs")
if os.path.exists(vbs_path):
    with open(vbs_path, 'r', encoding='latin1', newline='') as f:
        content = f.read()
    if 'Stream_StringToBinary' in content:
        # Patch Base64Encode to pure VBScript to avoid broken ADODB.Stream utf-8 in Wine
        old_sub = '''Function Base64Encode(sText)

    Dim oXML, oNode
    Set oXML = CreateObject("Msxml2.DOMDocument.3.0")
    Set oNode = oXML.CreateElement("base64")
    oNode.dataType = "bin.base64"
    oNode.nodeTypedValue =Stream_StringToBinary(sText)
    Base64Encode = oNode.text
    Set oNode = Nothing
    Set oXML = Nothing
End Function'''
        new_sub = '''Function Base64Encode(sText)
    Dim cList, i, b1, b2, b3, res
    cList = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    res = ""
    For i = 1 To Len(sText) Step 3
        b1 = Asc(Mid(sText, i, 1)) And 255
        If i + 1 <= Len(sText) Then b2 = Asc(Mid(sText, i + 1, 1)) And 255 Else b2 = -1
        If i + 2 <= Len(sText) Then b3 = Asc(Mid(sText, i + 2, 1)) And 255 Else b3 = -1
        
        res = res & Mid(cList, (b1 \\ 4) + 1, 1)
        If b2 <> -1 Then
            res = res & Mid(cList, ((b1 And 3) * 16) + (b2 \\ 16) + 1, 1)
            If b3 <> -1 Then
                res = res & Mid(cList, ((b2 And 15) * 4) + (b3 \\ 64) + 1, 1)
                res = res & Mid(cList, (b3 And 63) + 1, 1)
            Else
                res = res & Mid(cList, ((b2 And 15) * 4) + 1, 1) & "="
            End If
        Else
            res = res & Mid(cList, ((b1 And 3) * 16) + 1, 1) & "=="
        End If
    Next
    Base64Encode = "BOM_" & res
End Function'''
        old_crlf = old_sub.replace('\r\n', '\n').replace('\n', '\r\n')
        new_crlf = new_sub.replace('\r\n', '\n').replace('\n', '\r\n')
        if old_crlf in content:
            content = content.replace(old_crlf, new_crlf)

        # Fix MyDocuments path in Wine to avoid Permission Denied on AltiumLL.txt
        if 'SpecialFolders("MyDocuments")' in content:
            t1 = '   InstallFolder = WshShell.SpecialFolders("MyDocuments")\r\n   InstalledDir = InstallFolder & "\\AltiumLL"'
            r1 = '   InitInstalledDir'
            content = content.replace(t1, r1)

            t2 = 'Function ReadTXT(LineNo)\r\n   TXTFileName = InstalledDir & "\\AltiumLL.txt"'
            r2 = '''Sub InitInstalledDir()\r\n   If Trim(InstalledDir) <> "" Then Exit Sub\r\n   Dim sa, docFolder, fs\r\n   Set fs = CreateObject("Scripting.FileSystemObject")\r\n   On Error Resume Next\r\n   Set sa = CreateObject("Shell.Application")\r\n   Set docFolder = sa.Namespace(5)\r\n   If Not docFolder Is Nothing Then\r\n      InstallFolder = docFolder.Self.Path\r\n   End If\r\n   Err.Clear\r\n   On Error GoTo 0\r\n   If Trim(InstallFolder) = "" Or Not fs.FolderExists(InstallFolder & "\\AltiumLL") Then\r\n      Dim up\r\n      up = Replace(CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%"), Chr(0), "")\r\n      If fs.FolderExists(up & "\\Documents\\AltiumLL") Then\r\n         InstallFolder = up & "\\Documents"\r\n      ElseIf fs.FolderExists("C:\\AltiumLL") Then\r\n         InstallFolder = "C:"\r\n      End If\r\n   End If\r\n   InstalledDir = InstallFolder & "\\AltiumLL"\r\nEnd Sub\r\n\r\nFunction ReadTXT(LineNo)\r\n   InitInstalledDir\r\n   TXTFileName = InstalledDir & "\\AltiumLL.txt"'''
            content = content.replace(t2, r2)

            t3 = 'Function UpdateTXT()\r\n   TXTFileName = InstalledDir & "\\AltiumLL.txt"'
            r3 = 'Function UpdateTXT()\r\n   InitInstalledDir\r\n   TXTFileName = InstalledDir & "\\AltiumLL.txt"'
            content = content.replace(t3, r3)

        with open(vbs_path, 'w', encoding='latin1', newline='') as f:
            f.write(content)
        print("Patch AltiumLL.vbs applicata!")

    if 'dom.selectNodes ("//ROOT/Parts/")' in content or 'dom.selectNodes("//ROOT/Parts/")' in content:
        content = content.replace('dom.selectNodes ("//ROOT/Parts/")', 'dom.selectNodes ("//ROOT/Parts/*")')
        content = content.replace('dom.selectNodes("//ROOT/Parts/")', 'dom.selectNodes("//ROOT/Parts/*")')
        with open(vbs_path, 'w', encoding='latin1', newline='') as f:
            f.write(content)
        print("Patch XPath //ROOT/Parts/* applicata a AltiumLL.vbs!")

    if 'Sub ShowImages()' in content and 'On Error Resume Next' not in content.split('Sub ShowImages()')[1][:60]:
        content = content.replace('Sub ShowImages()', 'Sub ShowImages()\r\n    On Error Resume Next\r\n    InitInstalledDir')
        with open(vbs_path, 'w', encoding='latin1', newline='') as f:
            f.write(content)

    if 'Function ProcessSelectedPart(partID)' in content and 'InitInstalledDir' not in content.split('Function ProcessSelectedPart(partID)')[1][:200]:
        old_psp = 'Function ProcessSelectedPart(partID)\r\n\r\n    If CheckLogin Then'
        new_psp = '''Function ProcessSelectedPart(partID)\r\n    InitInstalledDir\r\n    Dim fsoCheck\r\n    Set fsoCheck = CreateObject("Scripting.FileSystemObject")\r\n    If Not fsoCheck.FolderExists(InstalledDir & "\\Temp") Then fsoCheck.CreateFolder(InstalledDir & "\\Temp")\r\n    Set fsoCheck = Nothing\r\n\r\n    If CheckLogin Then'''
        content = content.replace(old_psp, new_psp)
        with open(vbs_path, 'w', encoding='latin1', newline='') as f:
            f.write(content)

    if 'outFile= ecadModelPath & prtName & ".cb"' in content:
        old_cb_block = '''        outFile= ecadModelPath & prtName & ".cb"
        Set fso = CreateObject("Scripting.FileSystemObject")
        Set cbFile = fso.CreateTextFile(outFile,True)
        cbFile.Write cb
        cbFile.Close
        Set fso = Nothing
        ProcessCB(ecadModelPath & prtName & ".cb")'''
        new_cb_block = '''        outFile = ecadModelPath & prtName & ".cb"
        Set fso = CreateObject("Scripting.FileSystemObject")
        On Error Resume Next
        If fso.FileExists(outFile) Then fso.DeleteFile outFile, True
        Set cbFile = fso.CreateTextFile(outFile, True)
        If Err.Number <> 0 Then
            Err.Clear
            outFile = ecadModelPath & prtName & "_" & Int(Timer * 100) & ".cb"
            Set cbFile = fso.CreateTextFile(outFile, True)
        End If
        On Error GoTo 0
        cbFile.Write cb
        cbFile.Close
        Set fso = Nothing
        ProcessCB(outFile)'''
        content = content.replace(old_cb_block.replace('\r\n', '\n').replace('\n', '\r\n'), new_cb_block.replace('\r\n', '\n').replace('\n', '\r\n'))
        with open(vbs_path, 'w', encoding='latin1', newline='') as f:
            f.write(content)

    # Patch missing Set on PCBServer / COM object assignments (fixes Access Violation in ScriptingSystem.dll)
    with open(vbs_path, 'rb') as f:
        raw = f.read()
    lines = raw.split(b'\r\n')
    new_lines = []
    modified = False
    for line in lines:
        stripped = line.strip()
        if b'= PCBServer.PCBObjectFactory' in line or b'= pcbserver.PCBObjectFactory' in line:
            if not line.strip().startswith(b'Set '):
                indent = len(line) - len(line.lstrip())
                line = line[:indent] + b'Set ' + line[indent:].replace(b'pcbserver.', b'PCBServer.')
                modified = True
        elif stripped == b'PCBLib = PCBServer.GetCurrentPCBLibrary':
            line = line.replace(b'PCBLib =', b'Set PCBLib =')
            modified = True
        elif stripped == b'Component = PCBLib.GetComponent(j)':
            line = line.replace(b'Component =', b'Set Component =')
            modified = True
        elif b'= Client.OpenDocument(' in line and not line.strip().startswith(b'Set '):
            indent = len(line) - len(line.lstrip())
            line = line[:indent] + b'Set ' + line[indent:]
            modified = True
        elif stripped == b'temp_fp = PCBLib.CreateNewComponent':
            line = line.replace(b'temp_fp =', b'Set temp_fp =')
            modified = True
        elif stripped.startswith(b'Model = STEPmodel.ModelFactory_FromFilename'):
            line = line.replace(b'Model =', b'Set Model =')
            modified = True
        elif stripped == b'PcbLib.CurrentComponent = footprint':
            indent = len(line) - len(line.lstrip())
            line = line[:indent] + b'On Error Resume Next: Set PCBLib.CurrentComponent = footprint: PCBLib.CurrentComponent = footprint: On Error GoTo 0'
            modified = True
        elif stripped == b'PCBLib.CurrentComponent = temp_fp':
            indent = len(line) - len(line.lstrip())
            line = line[:indent] + b'On Error Resume Next: Set PCBLib.CurrentComponent = temp_fp: PCBLib.CurrentComponent = temp_fp: On Error GoTo 0'
            modified = True
        elif stripped == b'STEPmodel.Model = Model':
            indent = len(line) - len(line.lstrip())
            line = line[:indent] + b'On Error Resume Next: Set STEPmodel.Model = Model: STEPmodel.Model = Model: On Error GoTo 0'
            modified = True
        new_lines.append(line)
    if modified:
        with open(vbs_path, 'wb') as f:
            f.write(b'\r\n'.join(new_lines))
        print("Patch missing Set in AltiumLL.vbs applicata!")
EOF
        log_succ "Altium Library Loader configurato con successo."
    fi

    echo ""
    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo -e "${BOLD}${GREEN}  Configurazione e correzioni completate con successo!           ${NC}"
    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo "Puoi avviare Altium Designer:"
    echo "  1. Cercandolo nel menu delle applicazioni ($DESKTOP_NAME)"
    echo "  2. Dal terminale: $LAUNCHER_SCRIPT"
    if [[ "$IS_DOTNET_FX" = true ]]; then
        echo ""
        log_info "Nota per Altium Designer ($ALTIUM_VER) con runtime .NET Framework 4.8:"
        echo "  - Se il dialogo in-app 'Sign in' accetta solo Email/Password (es. AD20.0.9)"
        echo "    e usi normalmente Google, imposta una password Altium tramite 'Forgotten password ?'"
        echo "    su https://myaccount.altium.com/ oppure usa una licenza standalone (.alf) / Private License Server."
    fi
    echo ""
}

# Apply system & registry settings to prefix
configure_prefix_environment() {
    mkdir -p "$TARGET_PREFIX"
    log_info "Configurazione del Wine prefix in: $TARGET_PREFIX..."
    # Skip wineboot -u when dotnet48 is already installed: BaseWow64Install runs
    # RegisterDlls on syswow64 mscoree.dll and pops a modal rundll32 error dialog.
    if [[ ! -f "$TARGET_PREFIX/system.reg" || ! -f "$TARGET_PREFIX/dosdevices/c:/windows/dotnet48.installed.workaround" ]]; then
        wineboot -u
    fi

    local WT_LOG="$TARGET_PREFIX/winetricks.log"
    local NEED_TRICKS=()
    local WIN_VER_OK=false
    if [[ -f "$WT_LOG" ]] && [[ "$(grep -E '^(win10|win7|winxp)$' "$WT_LOG" | tail -n 1 || true)" == "win10" ]]; then
        WIN_VER_OK=true
    fi
    [[ "$WIN_VER_OK" = true ]] || NEED_TRICKS+=("win10")
    for pair in "corefonts:corefonts" "tahoma:tahoma" "fontsmooth-rgb:fontsmooth=rgb" "d3dcompiler_47:d3dcompiler_47" "dxvk:dxvk"; do
        local pkg="${pair%%:*}"
        local entry="${pair#*:}"
        if [[ ! -f "$WT_LOG" ]] || ! grep -qxF "$entry" "$WT_LOG"; then
            NEED_TRICKS+=("$pkg")
        fi
    done

    if [[ ${#NEED_TRICKS[@]} -gt 0 ]]; then
        log_info "Installazione dei componenti tramite winetricks (${NEED_TRICKS[*]})..."
        winetricks -q "${NEED_TRICKS[@]}" || {
            log_warn "Winetricks completato con avvisi non critici. Si prosegue..."
        }
    else
        log_succ "Componenti winetricks base già installati nel prefix."
    fi

    log_info "Installazione e sincronizzazione font di sistema (Segoe UI, Tahoma)..."
    mkdir -p "$TARGET_PREFIX/drive_c/windows/Fonts" "$HOME/.local/share/fonts/segoe-ui" "$HOME/.local/share/fonts/tahoma"
    if [[ -d "$HOME/.local/share/fonts/segoe-ui" ]]; then
        cp -f "$HOME/.local/share/fonts/segoe-ui/"*.ttf "$TARGET_PREFIX/drive_c/windows/Fonts/" 2>/dev/null || true
    fi
    if [[ -f "$TARGET_PREFIX/drive_c/windows/Fonts/tahoma.ttf" ]]; then
        cp -f "$TARGET_PREFIX/drive_c/windows/Fonts/tahoma"*.ttf "$HOME/.local/share/fonts/tahoma/" 2>/dev/null || true
    fi
    command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$HOME/.local/share/fonts" 2>/dev/null || true
    log_succ "Font di sistema sincronizzati (Segoe UI, Tahoma)."

    log_info "Applicazione delle impostazioni del registro (WPF, animazioni menu, ombre, ClearType, buffering)..."
    local REG_FIX_FILE="/tmp/altium_fixes_$$.reg"
    cat << 'EOF' > "$REG_FIX_FILE"
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"ClientSideGraphics"="Y"
"ClientSideWithRender"="Y"
"UseTakeFocus"="N"

[HKEY_CURRENT_USER\Software\Microsoft\Avalon.Graphics]
"DisableHWAcceleration"=dword:00000000

[HKEY_CURRENT_USER\Control Panel\Desktop]
"UserPreferencesMask"=hex:90,12,03,80,10,00,00,00
"MenuShowDelay"="0"
"SmoothScroll"=dword:00000000
"DragFullWindows"="0"
"FontSmoothing"="2"
"FontSmoothingType"=dword:00000002
"FontSmoothingGamma"=dword:00000578
"FontSmoothingOrientation"=dword:00000001

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects]
"VisualFXSetting"=dword:00000002

[HKEY_CURRENT_USER\Software\Altium\Altium Designer {F12855C5-BD21-4C4B-BDC8-9239BA72A9A5}\DesignExplorer\Preferences\Client\Client Preferences]
"Animated Panels"="0"
"Animation Speed"=dword:00000000
"Auto Transparent Toolbars"="0"
"Dynamic Auto Transparency"="0"

[HKEY_CURRENT_USER\Software\Altium\Altium Designer {098E92C5-2552-44B1-BA35-25D7FC633AAE}\DesignExplorer\Preferences\SCH\Schematic Preferences]
"BufferedPainting"="1"
"AlwaysDrag"="0"
"SpatialAnalysisDuringDragging"="0"
"OptimizePolylines"="1"
"Display Printer Fonts"="0"

[HKEY_CURRENT_USER\Software\Altium\Altium Designer {098E92C5-2552-44B1-BA35-25D7FC633AAE}\DesignExplorer\Preferences\Schematic Preferences\General]
"BufferedPainting"="1"

[HKEY_CURRENT_USER\Software\Altium\Altium Designer {F12855C5-BD21-4C4B-BDC8-9239BA72A9A5}\DesignExplorer\Preferences\SCH\Schematic Preferences]
"BufferedPainting"="1"
"AlwaysDrag"="0"
"SpatialAnalysisDuringDragging"="0"
"OptimizePolylines"="1"
"Display Printer Fonts"="0"

[HKEY_CURRENT_USER\Software\Altium\Altium Designer {F12855C5-BD21-4C4B-BDC8-9239BA72A9A5}\DesignExplorer\Preferences\Schematic Preferences\General]
"BufferedPainting"="1"

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"*d2d1"="native,builtin"

[HKEY_CURRENT_USER\Software\Altium\Altium Designer {098E92C5-2552-44B1-BA35-25D7FC633AAE}\DesignExplorer\Preferences\AdvPCB\SystemOptions]
"UseAnimation"="0"
"UseSmoothZoom"="0"
"CleanRedraw"="1"

[HKEY_CURRENT_USER\Software\Altium\Altium Designer {098E92C5-2552-44B1-BA35-25D7FC633AAE}\DesignExplorer\Preferences\Client\Client Preferences]
"Animated Panels"="0"
"Animation Speed"=dword:00000000
"Auto Transparent Toolbars"="0"
"Dynamic Auto Transparency"="0"
"AllowedNetworkActivity"="AltiumPortal;AltiumCloud;AltiumVault;Browser;LicenseServer;Suppliers"
"ConnectivityInsight"="0"
"ConnectivityInsightHoverPreview"="0"
"ConnectivityInsightHoverTextHint"="0"
"ConnectivityInsightHoverTree"="0"
"HyperlinkInsight"="0"
"HyperlinkInsightHoverEnabled"="0"
"DocumnetInsight"="0"
"ProjectInsight"="0"
EOF

    wine regedit "$REG_FIX_FILE"
    wineserver -w 2>/dev/null || true
    rm -f "$REG_FIX_FILE"

    # Setup xdg-open.exe in Wine so any process calling xdg-open delegates to host browser
    local SYS32="$TARGET_PREFIX/drive_c/windows/system32"
    local SYSWOW="$TARGET_PREFIX/drive_c/windows/syswow64"
    local WINDIR="$TARGET_PREFIX/drive_c/windows"
    if [[ -f "$SYS32/winebrowser.exe" ]]; then
        cp -f "$SYS32/winebrowser.exe" "$SYS32/xdg-open.exe"
        cp -f "$SYS32/winebrowser.exe" "$WINDIR/xdg-open.exe"
        if [[ -d "$SYSWOW" ]]; then
            cp -f "$SYS32/winebrowser.exe" "$SYSWOW/xdg-open.exe"
        fi
    fi

    # Setup host xdg-open wrapper that brings browser to foreground on KDE/GNOME
    mkdir -p "$HOME/.local/bin"
    local XDG_WRAPPER="$HOME/.local/bin/xdg-open"
    if [[ ! -f "$XDG_WRAPPER" ]]; then
        cat << 'EOF' > "$XDG_WRAPPER"
#!/usr/bin/env bash
/usr/bin/xdg-open "$@" &
PID=$!
(
    sleep 0.5
    if command -v qdbus6 >/dev/null 2>&1; then
        cat << 'JS' > /tmp/raise_browser.js
for (var client of workspace.windowList()) {
    if (client.resourceClass.indexOf("firefox") !== -1 || client.resourceClass.indexOf("chrome") !== -1 || client.resourceClass.indexOf("browser") !== -1) {
        workspace.activeWindow = client;
        break;
    }
}
JS
        qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "/tmp/raise_browser.js" "raise_browser" >/dev/null 2>&1 || true
        qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1 || true
        qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "raise_browser" >/dev/null 2>&1 || true
        rm -f /tmp/raise_browser.js
    fi
) &
wait $PID
EOF
        chmod +x "$XDG_WRAPPER"
    fi
    log_succ "Ambiente e registro del prefix configurati."
}

# If patch only requested, apply and exit
if [[ "$PATCH_ONLY" = true ]]; then
    if [[ -z "$EXISTING_ALTIUM" ]]; then
        FOUND_EXE="$(find "$TARGET_PREFIX/drive_c/Program Files" -maxdepth 4 -iname "X2.EXE" 2>/dev/null | head -n 1 || true)"
        [[ -n "$FOUND_EXE" ]] && EXISTING_ALTIUM="$(dirname "$FOUND_EXE")"
    fi
    if [[ -z "$EXISTING_ALTIUM" ]]; then
        log_err "Nessuna installazione di Altium Designer trovata in $TARGET_PREFIX."
        exit 1
    fi
    configure_prefix_environment
    apply_patches_and_finish "$EXISTING_ALTIUM"
    exit 0
fi

# Ask for installer if not specified
if [[ -z "$INSTALLER_PATH" && "$NON_INTERACTIVE" = false ]]; then
    while true; do
        read -rp "$(echo -e "${BOLD}Percorso del file installer (.exe): ${NC}")" USER_INST_INPUT
        USER_INST_INPUT="${USER_INST_INPUT/#\~/$HOME}"
        if [[ -f "$USER_INST_INPUT" ]]; then
            INSTALLER_PATH="$USER_INST_INPUT"
            break
        else
            log_err "File non trovato: $USER_INST_INPUT. Riprova."
        fi
    done
elif [[ -z "$INSTALLER_PATH" && "$NON_INTERACTIVE" = true ]]; then
    log_err "In modalità non interattiva è obbligatorio specificare il parametro --installer."
    exit 1
fi

if [[ ! -f "$INSTALLER_PATH" ]]; then
    log_err "Installer specificato non trovato: $INSTALLER_PATH"
    exit 1
fi

INSTALLER_PATH="$(realpath "$INSTALLER_PATH")"

echo ""
log_info "Configurazione:"
echo "  - Wine Prefix: $TARGET_PREFIX"
echo "  - Installer:   $INSTALLER_PATH"
echo ""

configure_prefix_environment

# Perform Online OAuth Login Bridge if using online installer
SESSION_TOKEN=""
if [[ "$(basename "$INSTALLER_PATH")" =~ ^AltiumDesignerSetup ]]; then
    echo -e "${BOLD}${YELLOW}----------------------------------------------------------------${NC}"
    echo -e "${BOLD}${YELLOW}  Accesso Account Altium / Google per l'Online Installer        ${NC}"
    echo -e "${BOLD}${YELLOW}----------------------------------------------------------------${NC}"
    echo "L'installer online richiede l'autenticazione per scaricare i pacchetti di Altium."
    echo "Stiamo per aprire il tuo browser di sistema per effettuare l'accesso in sicurezza."
    echo ""
    if [[ "$NON_INTERACTIVE" != true ]]; then
        read -rp "$(echo -e "${BOLD}Premi [INVIO] per aprire il browser ed eseguire l'accesso...${NC}")"
    fi

    log_info "Avvio del bridge OAuth nativo..."
    set +e
    SESSION_TOKEN="$(python3 - << 'EOF'
import os, sys, base64, hashlib, uuid, urllib.parse, json, subprocess
import urllib.request, urllib.error

CLIENT_ID = "D6CA83C5-9282-4B85-A140-520296EB95C2"
AUTH_URL = "https://auth.altium.com"
AWAIT_URL = "https://actionwait.altium.com/await"
REDIRECT_URI = f"{AUTH_URL}/api/AuthComplete"
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

try:
    # 1. Generate PKCE (54 random bytes, matching Altium's Authorizer implementation)
    raw_verifier = os.urandom(54)
    verifier = base64.urlsafe_b64encode(raw_verifier).decode('ascii').rstrip('=')
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode('ascii')).digest()).decode('ascii').rstrip('=')
    state_token = str(uuid.uuid4())

    query = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "response_type": "code",
        "scope": "openid profile",
        "redirect_uri": REDIRECT_URI,
        "code_challenge": challenge,
        "state": state_token,
        "code_challenge_method": "S256"
    })
    auth_link = f"{AUTH_URL}/connect/authorize?{query}"

    sys.stderr.write("[OAuth] Apertura del browser per il login Altium/Google...\n")
    # Open browser natively on Linux
    subprocess.Popen(["xdg-open", auth_link])

    sys.stderr.write("[OAuth] In attesa del completamento del login nel browser (timeout 5 min)...\n")
    # Long-poll ActionWait
    req = urllib.request.Request(
        AWAIT_URL,
        data=json.dumps({"token": state_token}).encode('utf-8'),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST"
    )

    with urllib.request.urlopen(req, timeout=300) as resp:
        body = resp.read().decode('utf-8')
        data = json.loads(body)
        
        # ActionWait returns JSON with a 'Data' field containing a dictionary {"code": "...", "state": "..."}
        res_data = data.get("Data") or data.get("data") or data
        if isinstance(res_data, str) and res_data.strip().startswith("{"):
            try:
                res_data = json.loads(res_data)
            except Exception:
                pass

        if isinstance(res_data, dict):
            if "error" in res_data:
                sys.stderr.write(f"[OAuth ERROR] Server ActionWait ha restituito un errore: {res_data['error']}\n")
                sys.exit(1)
            code = res_data.get("code") or res_data.get("Code") or res_data.get("data")
        else:
            code = res_data

        if not code:
            sys.stderr.write(f"[OAuth ERROR] Nessun codice di autorizzazione trovato nella risposta ActionWait: {body}\n")
            sys.exit(1)

        code = str(code).strip()

    sys.stderr.write("[OAuth] Codice ricevuto. Richiesta del token di sessione...\n")

    # Exchange code for access token (client_id MUST be included in POST body)
    token_req_data = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "code_verifier": verifier
    }).encode('utf-8')

    token_req = urllib.request.Request(
        f"{AUTH_URL}/connect/token",
        data=token_req_data,
        headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT},
        method="POST"
    )

    with urllib.request.urlopen(token_req, timeout=30) as resp:
        token_data = json.loads(resp.read().decode('utf-8'))
        access_token = token_data.get("access_token", "")
        if not access_token:
            sys.stderr.write(f"[OAuth ERROR] Nessun access_token nella risposta: {token_data}\n")
            sys.exit(1)
        # Print token to stdout for bash capture
        print(access_token)
        sys.stderr.write("[OAuth] Login completato con successo!\n")

except urllib.error.HTTPError as e:
    err_body = e.read().decode('utf-8', errors='ignore')
    sys.stderr.write(f"[OAuth HTTP ERROR {e.code}]: {err_body}\n")
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f"[OAuth ERROR]: {e}\n")
    sys.exit(1)
EOF
)"
    PY_STATUS=$?
    set -e

    if [[ $PY_STATUS -ne 0 || -z "$SESSION_TOKEN" ]]; then
        log_err "Impossibile ottenere il token di autenticazione dal browser."
        log_err "Assicurati di aver completato l'accesso nel browser entro 5 minuti."
        exit 1
    fi
    log_succ "Autenticazione riuscita! Token di sessione acquisito."
fi

# Run the installer
log_info "Avvio dell'installer di Altium Designer..."
echo -e "${YELLOW}Completa la procedura guidata a schermo (destinazione, componenti, ecc.).${NC}"
echo -e "${YELLOW}Lo script attenderà il completamento dell'installazione...${NC}"

if [[ -n "$SESSION_TOKEN" ]]; then
    # Online installer with pre-authenticated session
    # AD24+ accepts "-SessionId:<tok> -Install"; older installers (e.g. AD20/AD22) use "-SessionID:<tok>" without "-Install"
    HAS_STANDALONE_INSTALL="$(python3 - << EOF
data = open("$INSTALLER_PATH", "rb").read()
u = "-Install\x00".encode("utf-16le")
a = b"-Install\x00"
print("yes" if (u in data or a in data) else "no")
EOF
)"
    if [[ "$HAS_STANDALONE_INSTALL" == "yes" ]]; then
        wine "$INSTALLER_PATH" -SessionId:"$SESSION_TOKEN" -Install || true
    else
        wine "$INSTALLER_PATH" -SessionID:"$SESSION_TOKEN" || true
    fi
else
    # Offline or standard setup
    wine "$INSTALLER_PATH" || true
fi

# Locate installed Altium Designer
log_info "Ricerca dell'installazione di Altium Designer nel prefix..."
ALTIUM_DIR=""
for cand in "$TARGET_PREFIX/drive_c/Program Files/Altium"/AD* \
            "$TARGET_PREFIX/drive_c/Program Files/Altium/Altium Designer"* \
            "$TARGET_PREFIX/drive_c/Program Files/Altium"/*; do
    if [[ -d "$cand" && (-f "$cand/X2.EXE" || -f "$cand/X2.exe") ]]; then
        ALTIUM_DIR="$cand"
        break
    fi
done

if [[ -z "$ALTIUM_DIR" ]]; then
    FOUND_EXE="$(find "$TARGET_PREFIX/drive_c/Program Files" -maxdepth 4 -iname "X2.EXE" 2>/dev/null | head -n 1)"
    if [[ -n "$FOUND_EXE" ]]; then
        ALTIUM_DIR="$(dirname "$FOUND_EXE")"
    fi
fi

if [[ -z "$ALTIUM_DIR" ]]; then
    log_err "Impossibile trovare la cartella di Altium Designer in $TARGET_PREFIX/drive_c/Program Files/Altium."
    log_err "L'installazione potrebbe essere stata annullata o posizionata in un percorso differente."
    exit 1
fi
log_succ "Altium Designer rilevato in: $ALTIUM_DIR"

# Apply all patches and finish
apply_patches_and_finish "$ALTIUM_DIR"
