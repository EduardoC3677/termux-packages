#!/data/data/com.termux/files/usr/bin/bash
# Wrapper mejorado para tsu - siempre usa root de Android (KernelSU/Magisk)
# Este comando siempre busca el binario su de Android, incluso en proot

# Forzar uso de binarios su de Android
SU_BINARY_SEARCH=(
    "/sbin/su"
    "/system/bin/su"
    "/system/xbin/su"
    "/data/local/xbin/su"
    "/data/local/bin/su"
    "/system/sd/xbin/su"
    "/system/bin/failsafe/su"
    "/data/local/su"
    "/su/bin/su"
    "/su/bin"
)

# Buscar binario su de Android
SU_BINARY=""
for binary in "${SU_BINARY_SEARCH[@]}"; do
    if [ -x "$binary" ]; then
        SU_BINARY="$binary"
        break
    fi
done

if [ -z "$SU_BINARY" ]; then
    echo "Error: No se encontró binario su de Android (KernelSU/Magisk)"
    echo "Por favor, instala KernelSU o Magisk en tu dispositivo."
    exit 1
fi

# Configuración de entorno Android
ANDROID_SYSPATHS="/system/bin:/system/xbin"
TERMUX_PREFIX="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}"

# Preservar entorno si se solicita
if [ "$1" = "-e" ] || [ "$1" = "--preserve-environment" ]; then
    shift
    exec "$SU_BINARY" -c "PATH=$ANDROID_SYSPATHS:$PATH $*"
else
    # Limpiar entorno y usar shell de Android
    SHELL="${SHELL:-/system/bin/sh}"
    exec "$SU_BINARY" -c "PATH=$ANDROID_SYSPATHS env -i HOME=/root SHELL=$SHELL TERM=xterm-256color $SHELL"
fi
