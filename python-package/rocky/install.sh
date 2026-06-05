#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_BASE="$SCRIPT_DIR/rpms"
REQ_DEFAULT="$SCRIPT_DIR/../requirements.txt"
REQ_PY36="$SCRIPT_DIR/../requirements-py36.txt"

echo "============================================================"
echo "  Rocky Linux offline installer"
echo "============================================================"
echo "  OS: $(cat /etc/rocky-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null || echo 'unknown')"
echo ""

ROCKY_VER=9
if [ -f /etc/rocky-release ]; then
    ROCKY_VER=$(grep -oE 'release [0-9]+' /etc/rocky-release 2>/dev/null | awk '{print $2}' | head -1 || echo 9)
elif [ -f /etc/redhat-release ]; then
    ROCKY_VER=$(grep -oE 'release [0-9]+' /etc/redhat-release 2>/dev/null | awk '{print $2}' | head -1 || echo 9)
fi
ROCKY_VER=${ROCKY_VER:-9}
echo "[INFO] Rocky version: $ROCKY_VER"

DNF=$(command -v dnf5 2>/dev/null || command -v dnf 2>/dev/null || true)
if [ -z "$DNF" ]; then
    echo "[WARN] dnf/dnf5 not found. Falling back to direct rpm installation."
fi

RPM_DIR="$RPM_BASE/rocky${ROCKY_VER}"

echo ""
echo "[1/2] Installing system RPM packages from rocky${ROCKY_VER}/ ..."
if [ -d "$RPM_DIR" ] && [ "$(find "$RPM_DIR" -maxdepth 1 -name '*.rpm' 2>/dev/null | head -1)" ]; then
    echo "      Path: $RPM_DIR"
    if [ "$ROCKY_VER" = "8" ]; then
        PY_RPMS=()
        for PATTERN in \
            "platform-python-*.rpm" \
            "platform-python-setuptools-*.rpm" \
            "platform-python-pip-*.rpm" \
            "python3-libs-3.6*.rpm" \
            "python3-pip-9*.rpm" \
            "python3-pip-wheel-9*.rpm" \
            "python3-setuptools-wheel-39*.rpm" \
            "libffi-*.rpm" \
            "openssl-libs-*.rpm" \
            "readline-*.rpm" \
            "sqlite-libs-*.rpm" \
            "bzip2-libs-*.rpm" \
            "xz-libs-*.rpm" \
            "zlib-*.rpm" \
            "gdbm-libs-*.rpm" \
            "ncurses-libs-*.rpm"; do
            for RPM in "$RPM_DIR"/$PATTERN; do
                [ -e "$RPM" ] && PY_RPMS+=("$RPM")
            done
        done

        if [ "${#PY_RPMS[@]}" -gt 0 ]; then
            rpm -Uvh --replacepkgs --nodeps "${PY_RPMS[@]}"
        fi
    elif [ -n "$DNF" ]; then
        if [ "$(basename "$DNF")" = "dnf5" ]; then
            "$DNF" install -y --disablerepo='*' "$RPM_DIR"/*.rpm 2>/dev/null || \
            rpm -Uvh --replacepkgs --nodeps "$RPM_DIR"/*.rpm
        else
            "$DNF" localinstall -y --disablerepo='*' "$RPM_DIR"/*.rpm 2>/dev/null || \
            rpm -Uvh --replacepkgs --nodeps "$RPM_DIR"/*.rpm
        fi
    else
        rpm -Uvh --replacepkgs --nodeps "$RPM_DIR"/*.rpm
    fi

    echo "      git: $(git --version 2>/dev/null || echo 'not found')"
    echo "      python: $(python3 --version 2>/dev/null || /usr/libexec/platform-python --version 2>/dev/null || python3.9 --version 2>/dev/null || echo 'not found')"
else
    echo "      [WARN] $RPM_DIR is missing or empty. Skipping system RPM installation."
    echo "             Ensure git, python3, and python3-pip are already installed."
fi

echo ""
echo "[INFO] Selecting Python interpreter ..."
PYTHON=""
PY_MAJOR=""
PY_MINOR=""
if [ "$ROCKY_VER" = "8" ]; then
    PYTHON_CANDIDATES="/usr/libexec/platform-python python3 python3.6 python36 python3.12 python3.11 python3.10 python3.9 python39 python3.8 python38"
else
    PYTHON_CANDIDATES="python3.12 python3.11 python3.10 python3.9 python39 python3.8 python38 python3.6 python36 python3"
fi

for CANDIDATE in $PYTHON_CANDIDATES; do
    if command -v "$CANDIDATE" >/dev/null 2>&1; then
        VERSION=$("$CANDIDATE" -c 'import sys; print("%s.%s" % (sys.version_info[0], sys.version_info[1]))' 2>/dev/null || true)
        PY_MAJOR=${VERSION%%.*}
        PY_MINOR=${VERSION#*.}
        if [ "$PY_MAJOR" = "3" ] && [ "$PY_MINOR" -ge 6 ]; then
            PYTHON="$CANDIDATE"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo "[ERROR] Python 3.6 or newer is required."
    exit 1
fi

if ! "$PYTHON" -m pip --version >/dev/null 2>&1; then
    echo "[ERROR] pip is not available for $PYTHON."
    exit 1
fi

REQ_FILE="$REQ_DEFAULT"
VERSIONED_PKG="$SCRIPT_DIR/packages/rocky${ROCKY_VER}"
COMMON_PKG="$SCRIPT_DIR/packages"
PY36_PKG="$SCRIPT_DIR/packages/py36"

if [ "$PY_MINOR" -eq 6 ]; then
    REQ_FILE="$REQ_PY36"
    if [ ! -f "$REQ_FILE" ]; then
        echo "[ERROR] Python 3.6 requirements file is missing: $REQ_FILE"
        exit 1
    fi
    if [ -d "$PY36_PKG" ] && [ "$(find "$PY36_PKG" -maxdepth 1 -name '*.whl' 2>/dev/null | head -1)" ]; then
        PY_PKG_DIR="$PY36_PKG"
    else
        echo "[ERROR] Python 3.6 wheel directory is missing or empty: $PY36_PKG"
        exit 1
    fi
else
    if [ -d "$VERSIONED_PKG" ] && [ "$(find "$VERSIONED_PKG" -maxdepth 1 -name '*.whl' 2>/dev/null | head -1)" ]; then
        PY_PKG_DIR="$VERSIONED_PKG"
    elif [ -d "$COMMON_PKG" ] && [ "$(find "$COMMON_PKG" -maxdepth 1 -name '*.whl' 2>/dev/null | head -1)" ]; then
        PY_PKG_DIR="$COMMON_PKG"
    else
        echo "[ERROR] Python wheel directory is missing or empty."
        echo "        Run download.sh on an internet-connected Rocky host first."
        exit 1
    fi
fi

echo "      Python: $($PYTHON --version)"
echo "      Requirements: $REQ_FILE"
echo "      Wheels: $PY_PKG_DIR"

echo ""
echo "[2/2] Installing Python packages offline ..."
if [ "$PY_MINOR" -eq 6 ]; then
    "$PYTHON" -m pip install \
        --no-index \
        --find-links "$PY_PKG_DIR" \
        "pip==21.3.1" \
        "setuptools==59.6.0" \
        "wheel==0.37.1"
fi

"$PYTHON" -m pip install \
    --no-index \
    --find-links "$PY_PKG_DIR" \
    -r "$REQ_FILE"

echo ""
echo "============================================================"
echo "  Installation complete"
echo "============================================================"
"$PYTHON" -m pip list 2>/dev/null | grep -iE \
    "tomli|jinja2|markupsafe|inquirer|paramiko|pexpect|requests|cryptography|blessed|bcrypt|pynacl|cffi|urllib3|certifi" \
    | awk '{printf "  %-30s %s\n", $1, $2}'

echo ""
echo "  git: $(git --version 2>/dev/null || echo 'not installed')"
echo "============================================================"
