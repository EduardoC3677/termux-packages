#!/data/data/com.termux/files/usr/bin/bash
# Wrapper inteligente para su que detecta el entorno
# - En Debian proot: usa /usr/bin/su (root de Debian)
# - En Termux nativo: usa tsu (KernelSU/Magisk para root de Android)

# Detectar si estamos en un entorno proot
if [ -n "$PROOT_VERSION" ] || [ -n "$PROOT_DISTRIBUTION" ] || [ -f "/.dockerenv" ] && [ -f "/etc/debian_version" ]; then
    # Estamos en Debian proot - usar su nativo de Debian
    exec /usr/bin/su "$@"
else
    # Estamos en Termux nativo - usar tsu para root de Android
    exec tsu "$@"
fi
