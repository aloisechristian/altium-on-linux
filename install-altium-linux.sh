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

    echo ""
    log_info "Applicazione delle correzioni ad Altium Designer..."

    # 1. Patch Altium.Identity.Authentication.dll
    log_info "Applicazione Patch OAuth in Altium.Identity.Authentication.dll..."
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
        log_warn "File $AUTH_DLL non trovato, patch saltata."
    fi

    # 2. Patch InheritWindowMonitor in X2.EXE
    log_info "Applicazione Patch crash menu C06D007F (InheritWindowMonitor in X2.EXE)..."
    python3 - << EOF
import struct, os

path = "$X2_EXE"
with open(path, "rb") as f:
    data = bytearray(f.read())

patch = bytes([0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90])
pos = 0xab3360

if pos < len(data) and data[pos] == 0x52 and data[pos+1] == 0x48 and data[pos+2] == 0x8d and data[pos+3] == 0x15:
    if not os.path.exists(path + ".bak"):
        with open(path + ".bak", "wb") as bf:
            bf.write(data)
    data[pos:pos+len(patch)] = patch
    with open(path, "wb") as f:
        f.write(data)
    print("Patch InheritWindowMonitor applicata con successo all'offset noto 0xab3360!")
else:
    found = False
    idx = data.find(bytes([0x52, 0x48, 0x8d, 0x15]))
    while idx != -1:
        if data[idx+8:idx+11] == bytes([0xe9, 0xc3, 0xff]) or data[idx+13:idx+16] == bytes([0xcc, 0xcc, 0xcc]):
            if not os.path.exists(path + ".bak"):
                with open(path + ".bak", "wb") as bf:
                    bf.write(data)
            data[idx:idx+len(patch)] = patch
            with open(path, "wb") as f:
                f.write(data)
            print(f"Patch InheritWindowMonitor applicata all'offset {hex(idx)}!")
            found = True
            break
        idx = data.find(bytes([0x52, 0x48, 0x8d, 0x15]), idx+1)
    if not found:
        print("Thunk InheritWindowMonitor già patchato o non trovato.")
EOF
    log_succ "Patch InheritWindowMonitor verificata/applicata."

    # 3. Patch "Control has no parent window" (EInvalidOperation in TWinControl.CreateWnd) in X2.EXE
    log_info "Applicazione Patch apertura schematici (Control has no parent window in X2.EXE)..."
    python3 - << EOF
import os, struct, shutil

path = "$X2_EXE"
with open(path, "rb") as f:
    data = bytearray(f.read())

sig = bytes.fromhex('48 89 85 c8 00 00 00 eb 46 48 8d 4d 58')
idx = data.find(sig)
if idx != -1:
    pos = idx + 9
    patch_code = bytes.fromhex('48 83 ec 20 e8 11 83 c8 ff 48 85 c0 75 05 e8 67 84 c8 ff 48 83 c4 20 48 89 85 c8 00 00 00 eb 26') + bytes([0x90] * 38)
    if not os.path.exists(path + ".bak"):
        with open(path + ".bak", "wb") as bf:
            bf.write(data)
    data[pos:pos+70] = patch_code
    tmp_path = path + ".tmp"
    with open(tmp_path, "wb") as f:
        f.write(data)
    shutil.copymode(path, tmp_path)
    os.replace(tmp_path, path)
    print("Patch TWinControl.CreateWnd applicata con successo!")
else:
    print("Pattern TWinControl.CreateWnd già patchato o non trovato.")
EOF
    log_succ "Patch apertura schematici verificata/applicata."

    # 4. Patch Atom Leak / Telemetry Brute-Force Loop in X2.EXE
    log_info "Applicazione Patch ciclo monitor atom/clipboard (CountAtoms in X2.EXE)..."
    python3 - << EOF
import os, shutil

path = "$X2_EXE"
with open(path, "rb") as f:
    data = bytearray(f.read())

sig = bytes.fromhex("55 48 83 ec 40 48 8b ec 48 89 4d 50 c7 45 34 00 00 00 00 c7 45 2c 00 00 00 00 c7 45 30 00 c0 00 00")
idx = data.find(sig)
if idx != -1:
    if not os.path.exists(path + ".orig"):
        with open(path + ".orig", "wb") as bf:
            bf.write(data)
    patch = bytes([
        0xc7, 0x41, 0x18, 0x32, 0x00, 0x00, 0x00,  # movl $50, 0x18(%rcx)
        0xc7, 0x41, 0x1c, 0x32, 0x00, 0x00, 0x00,  # movl $50, 0x1c(%rcx)
        0xc3,                                       # ret
    ]) + b"\x90" * (150 - 15)
    data[idx : idx + len(patch)] = patch
    tmp_path = path + ".tmp"
    with open(tmp_path, "wb") as f:
        f.write(data)
    shutil.copymode(path, tmp_path)
    os.replace(tmp_path, path)
    print("Patch CountAtoms applicata con successo!")
else:
    print("Pattern CountAtoms già patchato o non trovato.")
EOF
    log_succ "Patch ciclo monitor atom/clipboard verificata/applicata."

    # 5. Patch Direct2D HWND Presentation in AdvSch.dll
    log_info "Applicazione Patch rendering Direct2D schematico (PresentToWnd in AdvSch.dll)..."
    python3 - << EOF
import os

advsch_path = os.path.join(os.path.dirname("$X2_EXE"), "System", "AdvSch.dll")
if os.path.exists(advsch_path):
    with open(advsch_path, "rb") as f:
        data = bytearray(f.read())

    sig1 = bytes.fromhex("80 b8 8a 05 00 00 00 74 2a 48 8b 85")
    sig2 = bytes.fromhex("48 83 79 08 00 0f 95 c1 88 88 8a 05 00 00")

    idx1 = data.find(sig1)
    idx2 = data.find(sig2)
    patched = False

    if idx1 != -1:
        data[idx1 + 7 : idx1 + 9] = b"\xeb\x2a"
        patched = True
    if idx2 != -1:
        data[idx2 + 5 : idx2 + 8] = b"\x31\xc9\x90"
        patched = True

    if patched:
        if not os.path.exists(advsch_path + ".orig"):
            with open(advsch_path + ".orig", "wb") as bf:
                bf.write(data)
        with open(advsch_path, "wb") as f:
            f.write(data)
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
    advsim_path = matches[0]
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
    print("AdvSim.dll non trovato.")
EOF
    log_succ "Patch hook flood in AdvSim.dll verificata/applicata."

    # 5. Install optimized Direct2D (d2d1.dll) & win32u.so & Create Launcher Script / DXVK Tuning
    if [[ -f "/home/christiana/custom-wine-dlls/x86_64-windows/d2d1.dll" ]]; then
        log_info "Installazione d2d1.dll ottimizzata (batching GPU + glyph cache 8192 + scaled DWrite analysis) nel prefix..."
        cp -f "/home/christiana/custom-wine-dlls/x86_64-windows/d2d1.dll" "$TARGET_PREFIX/drive_c/windows/system32/d2d1.dll"
        if [[ -d "/home/christiana/custom-wine-dist/usr/lib/wine/x86_64-windows" ]]; then
            cp -f "/home/christiana/custom-wine-dlls/x86_64-windows/d2d1.dll" "/home/christiana/custom-wine-dist/usr/lib/wine/x86_64-windows/d2d1.dll" 2>/dev/null || true
        fi
        log_succ "d2d1.dll ottimizzata installata in system32."
    elif [[ -f "/home/christiana/custom-wine-dlls/x86_64-windows/d2d1-native.dll" ]]; then
        log_info "Installazione d2d1.dll ottimizzata nel prefix..."
        cp -f "/home/christiana/custom-wine-dlls/x86_64-windows/d2d1-native.dll" "$TARGET_PREFIX/drive_c/windows/system32/d2d1.dll"
        log_succ "d2d1.dll ottimizzata installata in system32."
    fi
    if [[ -f "/home/christiana/custom-wine-dlls/x86_64-unix/win32u.so" ]]; then
        log_info "Sincronizzazione win32u.so ottimizzata (dirty surface tracking & epoll POLLIN re-arm)..."
        cp -f "/home/christiana/custom-wine-dlls/x86_64-unix/win32u.so" "$TARGET_PREFIX/win32u.so" 2>/dev/null || true
        if [[ -d "/home/christiana/custom-wine-dist/usr/lib/wine/x86_64-unix" ]]; then
            cp -f "/home/christiana/custom-wine-dlls/x86_64-unix/win32u.so" "/home/christiana/custom-wine-dist/usr/lib/wine/x86_64-unix/win32u.so" 2>/dev/null || true
        fi
        log_succ "win32u.so sincronizzata."
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

# Ottimizzazione latenza presentazione e ridisegno immediato per CAD desktop (elimina il ritardo di ridisegno / box di selezione)
dxgi.syncInterval = 0
d3d11.syncInterval = 0
d3d9.presentInterval = 0
dxgi.maxFrameLatency = 1
d3d11.maxFrameLatency = 1
d3d9.maxFrameLatency = 1
dxgi.tearFree = False
EOF

    log_info "Creazione dello script di avvio in: $LAUNCHER_SCRIPT"
    cat << EOF > "$LAUNCHER_SCRIPT"
#!/usr/bin/env bash
export WINEPREFIX="$TARGET_PREFIX"
export WINEARCH="win64"
export WINEDEBUG="-all"
export WINEDLLPATH="/home/christiana/custom-wine-dlls:/home/christiana/wine-custom-libs:/usr/lib/wine/x86_64-unix:/usr/lib/wine/x86_64-windows"
export WINEDLLOVERRIDES="d2d1=n,b;gdiplus=n,b"

# Disabilita VSync a livello driver e DXVK per ridisegno immediato e reattivo
export __GL_SYNC_TO_VBLANK=0
export vblank_mode=0
export DXVK_CONFIG_FILE="$DXVK_CONF"
export DXVK_HUD="${DXVK_HUD:-0}"

# Forza NVIDIA GPU in modalità massime prestazioni (P0) per eliminare stutter e latenza clock
DISPLAY="${DISPLAY:-:1}" nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=1" >/dev/null 2>&1 || true

CUSTOM_WINESERVER="/home/christiana/wine-d2d1-build/build64/server/wineserver"
if [[ -x "\$CUSTOM_WINESERVER" ]]; then
    export WINESERVER="\$CUSTOM_WINESERVER"
    if ! pgrep -f "\$CUSTOM_WINESERVER" >/dev/null 2>&1; then
        killall -9 wineserver 2>/dev/null || true
        sleep 0.2
        "\$CUSTOM_WINESERVER" -p
        sleep 0.2
    fi
fi

ALTIUM_EXE="$X2_EXE"

if [[ ! -f "\$ALTIUM_EXE" ]]; then
    echo "Eseguibile non trovato: \$ALTIUM_EXE"
    exit 1
fi

WINE_BIN="/home/christiana/custom-wine-dist/usr/lib/wine/x86_64-unix/wine"
if [[ ! -x "\$WINE_BIN" ]]; then
    WINE_BIN="wine"
fi

"\$WINE_BIN" "\$ALTIUM_EXE" --disable-gpu-sandbox --renderer-process-limit=2 --js-flags="--max-old-space-size=256" "\$@"
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
    cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Name=Altium Designer
Comment=Altium Designer on Wine
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
EOF
        log_succ "Altium Library Loader configurato con successo."
    fi

    echo ""
    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo -e "${BOLD}${GREEN}  Configurazione e correzioni completate con successo!           ${NC}"
    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo "Puoi avviare Altium Designer:"
    echo "  1. Cercandolo nel menu delle applicazioni (Altium Designer)"
    echo "  2. Dal terminale: $LAUNCHER_SCRIPT"
    echo ""
}

# Apply system & registry settings to prefix
configure_prefix_environment() {
    mkdir -p "$TARGET_PREFIX"
    log_info "Configurazione del Wine prefix in: $TARGET_PREFIX..."
    wineboot -u

    log_info "Installazione dei componenti tramite winetricks (corefonts, tahoma, fontsmooth-rgb, d3dcompiler_47, dxvk)..."
    winetricks -q win10 corefonts tahoma fontsmooth-rgb d3dcompiler_47 dxvk || {
        log_warn "Winetricks completato con avvisi non critici. Si prosegue..."
    }

    log_info "Installazione e sincronizzazione font di sistema (Segoe UI, Tahoma)..."
    mkdir -p "$TARGET_PREFIX/drive_c/windows/Fonts" "$HOME/.local/share/fonts/segoe-ui" "$HOME/.local/share/fonts/tahoma"
    if [[ -d "/home/christiana/.local/share/fonts/segoe-ui" ]]; then
        cp -f /home/christiana/.local/share/fonts/segoe-ui/*.ttf "$TARGET_PREFIX/drive_c/windows/Fonts/" 2>/dev/null || true
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
"AllowedNetworkActivity"="LicenseServer"
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
    read -rp "$(echo -e "${BOLD}Premi [INVIO] per aprire il browser ed eseguire l'accesso...${NC}")"

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
    wine "$INSTALLER_PATH" -SessionId:"$SESSION_TOKEN" -Install || true
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
