#!/usr/bin/env bash
##
##  Script for generating bootstrap archives.
##

set -e

export TERMUX_SCRIPTDIR=$(realpath "$(dirname "$(realpath "$0")")/../")
. $(dirname "$(realpath "$0")")/properties.sh
BOOTSTRAP_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tmp.XXXXXXXX")
trap 'rm -rf $BOOTSTRAP_TMPDIR' EXIT

# By default, bootstrap archives are compatible with Android >=7.0
# and <10.
BOOTSTRAP_ANDROID10_COMPATIBLE=false

# By default, bootstrap archives will be built for all architectures
# supported by Termux application.
# Override with option '--architectures'.
TERMUX_ARCHITECTURES=("aarch64" "arm" "i686" "x86_64")

# The supported termux package managers.
TERMUX_PACKAGE_MANAGERS=("apt" "pacman")

# The repository base urls mapping for package managers.
declare -A REPO_BASE_URLS=(
	["apt"]="https://packages-cf.termux.dev/apt/termux-main"
	["pacman"]="https://sync.termux-pacman.dev/main"
)

# The package manager that will be installed in bootstrap.
# The default is 'apt'. Can be changed by using the '--pm' option.
TERMUX_PACKAGE_MANAGER="apt"

# The repository base url for package manager.
# Can be changed by using the '--repository' option.
REPO_BASE_URL="${REPO_BASE_URLS[${TERMUX_PACKAGE_MANAGER}]}"

# A list of non-essential packages. By default it is empty, but can
# be filled with option '--add'.
declare -a ADDITIONAL_PACKAGES

# Debian proot mode: when enabled, the bootstrap downloads a Debian arm64
# rootfs from official Debian repositories instead of Termux packages,
# and uses proot to run it without root access.
BOOTSTRAP_DEBIAN_PROOT=false

# Debian release codename for the rootfs.
DEBIAN_RELEASE="bookworm"

# Debian rootfs base URL for downloading debootstrap/minbase tarballs.
DEBIAN_ROOTFS_BASE_URL="http://deb.debian.org/debian"

# Debian architecture mapping from Termux arch names.
declare -A DEBIAN_ARCH_MAP=(
	["aarch64"]="arm64"
	["arm"]="armhf"
	["i686"]="i386"
	["x86_64"]="amd64"
)

# Check for some important utilities that may not be available for
# some reason.
for cmd in ar awk curl grep gzip find sed tar xargs xz zip jq; do
	if [ -z "$(command -v $cmd)" ]; then
		echo "[!] Utility '$cmd' is not available in PATH."
		exit 1
	fi
done

# Download package lists from remote repository.
# Actually, there 2 lists can be downloaded: one architecture-independent and
# one for architecture specified as '$1' argument. That depends on repository.
# If repository has been created using "aptly", then architecture-independent
# list is not available.
read_package_list_deb() {
	local architecture
	for architecture in all "$1"; do
		if [ ! -e "${BOOTSTRAP_TMPDIR}/packages.${architecture}" ]; then
			echo "[*] Downloading package list for architecture '${architecture}'..."
			if ! curl --fail --location \
				--output "${BOOTSTRAP_TMPDIR}/packages.${architecture}" \
				"${REPO_BASE_URL}/dists/stable/main/binary-${architecture}/Packages"; then
				if [ "$architecture" = "all" ]; then
					echo "[!] Skipping architecture-independent package list as not available..."
					continue
				fi
			fi
			echo >> "${BOOTSTRAP_TMPDIR}/packages.${architecture}"
		fi

		echo "[*] Reading package list for '${architecture}'..."
		while read -r -d $'\xFF' package; do
			if [ -n "$package" ]; then
				local package_name
				package_name=$(echo "$package" | grep -i "^Package:" | awk '{ print $2 }')

				if [ -z "${PACKAGE_METADATA["$package_name"]}" ]; then
					PACKAGE_METADATA["$package_name"]="$package"
				else
					local prev_package_ver cur_package_ver
					cur_package_ver=$(echo "$package" | grep -i "^Version:" | awk '{ print $2 }')
					prev_package_ver=$(echo "${PACKAGE_METADATA["$package_name"]}" | grep -i "^Version:" | awk '{ print $2 }')

					# If package has multiple versions, make sure that our metadata
					# contains the latest one.
					if [ "$(echo -e "${prev_package_ver}\n${cur_package_ver}" | sort -rV | head -n1)" = "${cur_package_ver}" ]; then
						PACKAGE_METADATA["$package_name"]="$package"
					fi
				fi
			fi
		done < <(sed -e "s/^$/\xFF/g" "${BOOTSTRAP_TMPDIR}/packages.${architecture}")
	done
}

download_db_packages_pac() {
	if [ ! -e "${PATH_DB_PACKAGES}" ]; then
		echo "[*] Downloading package list for architecture '${package_arch}'..."
		curl --fail --location \
			--output "${PATH_DB_PACKAGES}" \
			"${REPO_BASE_URL}/${package_arch}/main.json"
	fi
}

read_db_packages_pac() {
	jq -r '."'${package_name}'"."'${1}'" | if type == "array" then .[] else . end' "${PATH_DB_PACKAGES}"
}

print_desc_package_pac() {
	echo -e "%${1}%\n${2}\n"
}

# Download and extract proot from Termux repositories
download_proot() {
	local architecture="$1"
	local proot_tmpdir="${BOOTSTRAP_TMPDIR}/proot"
	mkdir -p "$proot_tmpdir"
	
	echo "[*] Downloading proot for architecture '${architecture}'..."
	
	# Read package list to find proot package
	unset PROOT_METADATA
	declare -A PROOT_METADATA
	
	local pkg_arch
	for pkg_arch in all "$architecture"; do
		if [ ! -e "${proot_tmpdir}/packages.${pkg_arch}" ]; then
			curl --fail --location \
				--output "${proot_tmpdir}/packages.${pkg_arch}" \
				"${REPO_BASE_URL}/dists/stable/main/binary-${pkg_arch}/Packages" || {
				if [ "$pkg_arch" = "all" ]; then
					continue
				fi
				return 1
			}
		fi
		
		while read -r -d $'\xFF' package; do
			if [ -n "$package" ]; then
				local package_name
				package_name=$(echo "$package" | grep -i "^Package:" | awk '{ print $2 }')
				if [ "$package_name" = "proot" ]; then
					PROOT_METADATA["$package_name"]="$package"
					break 2
				fi
			fi
		done < <(sed -e "s/^$/\xFF/g" "${proot_tmpdir}/packages.${pkg_arch}")
	done
	
	if [ -z "${PROOT_METADATA["proot"]}" ]; then
		echo "[!] Failed to find proot package metadata"
		return 1
	fi
	
	local package_url
	package_url="$REPO_BASE_URL/$(echo "${PROOT_METADATA[proot]}" | grep -i "^Filename:" | awk '{ print $2 }')"
	
	echo "[*] Downloading proot package..."
	curl --fail --location --output "$proot_tmpdir/proot.deb" "$package_url"
	
	echo "[*] Extracting proot..."
	(cd "$proot_tmpdir"
		ar x proot.deb
		
		local data_archive
		if [ -f "./data.tar.xz" ]; then
			data_archive="data.tar.xz"
		elif [ -f "./data.tar.gz" ]; then
			data_archive="data.tar.gz"
		else
			echo "[!] No data.tar.* found in proot package"
			return 1
		fi
		
		# Extract proot binary to Termux prefix bin directory
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin"
		tar xf "$data_archive" -C "$BOOTSTRAP_ROOTFS" "./${TERMUX_PREFIX}/bin/proot"
		chmod 755 "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/proot"
	)
}

# Download and extract Debian rootfs
download_debian_rootfs() {
	local architecture="$1"
	local debian_arch="${DEBIAN_ARCH_MAP[$architecture]}"
	
	if [ -z "$debian_arch" ]; then
		echo "[!] Unsupported architecture '$architecture' for Debian rootfs"
		return 1
	fi
	
	echo "[*] Downloading Debian ${DEBIAN_RELEASE} rootfs for ${debian_arch}..."
	
	local rootfs_tmpdir="${BOOTSTRAP_TMPDIR}/debian-rootfs"
	mkdir -p "$rootfs_tmpdir"
	
	# Download debootstrap base system
	# Using minbase variant for minimal installation
	local rootfs_url="http://deb.debian.org/debian/dists/${DEBIAN_RELEASE}/main/binary-${debian_arch}/"
	
	echo "[*] Creating Debian rootfs structure..."
	mkdir -p "${BOOTSTRAP_ROOTFS}/debian-rootfs"
	
	# Create minimal Debian rootfs using debootstrap packages
	# Download essential packages: base-files, base-passwd, bash, coreutils, dpkg, apt
	local essential_packages="base-files base-passwd bash coreutils dpkg apt libc6"
	
	for pkg_name in $essential_packages; do
		echo "[*] Downloading Debian package: $pkg_name..."
		
		# Download Packages list
		if [ ! -e "${rootfs_tmpdir}/Packages" ]; then
			curl --fail --location \
				--output "${rootfs_tmpdir}/Packages" \
				"http://deb.debian.org/debian/dists/${DEBIAN_RELEASE}/main/binary-${debian_arch}/Packages.gz"
			gunzip -f "${rootfs_tmpdir}/Packages.gz" 2>/dev/null || true
		fi
		
		# Find package URL
		local pkg_url
		pkg_url=$(awk -v pkg="$pkg_name" '
			/^Package:/ { name=$2 }
			/^Filename:/ && name == pkg { print $2; exit }
		' "${rootfs_tmpdir}/Packages")
		
		if [ -z "$pkg_url" ]; then
			echo "[!] Failed to find package: $pkg_name"
			continue
		fi
		
		# Download and extract package
		mkdir -p "${rootfs_tmpdir}/${pkg_name}"
		curl --fail --location --output "${rootfs_tmpdir}/${pkg_name}/package.deb" \
			"http://deb.debian.org/debian/${pkg_url}"
		
		(cd "${rootfs_tmpdir}/${pkg_name}"
			ar x package.deb
			
			local data_archive
			if [ -f "./data.tar.xz" ]; then
				data_archive="data.tar.xz"
			elif [ -f "./data.tar.zst" ]; then
				data_archive="data.tar.zst"
			elif [ -f "./data.tar.gz" ]; then
				data_archive="data.tar.gz"
			else
				echo "[!] No data archive found for $pkg_name"
				return 1
			fi
			
			tar xf "$data_archive" -C "${BOOTSTRAP_ROOTFS}/debian-rootfs" 2>/dev/null || {
				# Some packages may have issues, continue
				echo "[!] Warning: Failed to extract $pkg_name"
			}
		)
	done
	
	# Configure Debian apt sources
	echo "[*] Configuring Debian apt sources..."
	mkdir -p "${BOOTSTRAP_ROOTFS}/debian-rootfs/etc/apt"
	cat > "${BOOTSTRAP_ROOTFS}/debian-rootfs/etc/apt/sources.list" <<EOF
# Debian ${DEBIAN_RELEASE} main repositories
deb http://deb.debian.org/debian ${DEBIAN_RELEASE} main contrib non-free
deb http://deb.debian.org/debian ${DEBIAN_RELEASE}-updates main contrib non-free
deb http://deb.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free
EOF
	
	# Create necessary directories
	mkdir -p "${BOOTSTRAP_ROOTFS}/debian-rootfs"/{proc,sys,dev,tmp,root,home}
	
	echo "[*] Debian rootfs setup complete"
}

# Create start-debian.sh script for launching Debian with proot
create_start_debian_script() {
	echo "[*] Creating start-debian.sh script..."
	
	cat > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/start-debian.sh" <<'EOF'
#!/bin/bash

# Start Debian environment using proot
# This script launches a Debian shell using proot without requiring root access

TERMUX_PREFIX="@TERMUX_PREFIX@"
DEBIAN_ROOTFS="${TERMUX_PREFIX}/../debian-rootfs"
PROOT="${TERMUX_PREFIX}/bin/proot"

# Check if proot exists
if [ ! -x "$PROOT" ]; then
    echo "Error: proot not found at $PROOT"
    exit 1
fi

# Check if Debian rootfs exists
if [ ! -d "$DEBIAN_ROOTFS" ]; then
    echo "Error: Debian rootfs not found at $DEBIAN_ROOTFS"
    exit 1
fi

# Set up proot arguments
PROOT_ARGS=(
    --rootfs="$DEBIAN_ROOTFS"
    --bind=/dev
    --bind=/proc
    --bind=/sys
    --bind=/sdcard:/sdcard
    --bind="${HOME}:/root"
    --cwd=/root
    /bin/env -i
    HOME=/root
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    TERM=$TERM
    LANG=C.UTF-8
)

# Launch shell
echo "Starting Debian environment..."
exec "$PROOT" "${PROOT_ARGS[@]}" /bin/bash --login
EOF
	
	sed -i "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/start-debian.sh"
	chmod 755 "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/start-debian.sh"
}

# Download specified package, its dependencies and then extract *.deb or *.pkg.tar.xz files to
# the bootstrap root.
pull_package() {
	local package_name=$1
	local package_tmpdir="${BOOTSTRAP_PKGDIR}/${package_name}"
	mkdir -p "$package_tmpdir"

	if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
		local package_url
		package_url="$REPO_BASE_URL/$(echo "${PACKAGE_METADATA[${package_name}]}" | grep -i "^Filename:" | awk '{ print $2 }')"
		if [ "${package_url}" = "$REPO_BASE_URL" ] || [ "${package_url}" = "${REPO_BASE_URL}/" ]; then
			echo "[!] Failed to determine URL for package '$package_name'."
			exit 1
		fi

		local package_dependencies
		package_dependencies=$(
			while read -r token; do
				echo "$token" | cut -d'|' -f1 | sed -E 's@\(.*\)@@'
			done < <(echo "${PACKAGE_METADATA[${package_name}]}" | grep -i "^Depends:" | sed -E 's@^[Dd]epends:@@' | tr ',' '\n')
		)

		# Recursively handle dependencies.
		if [ -n "$package_dependencies" ]; then
			local dep
			for dep in $package_dependencies; do
				if [ ! -e "${BOOTSTRAP_PKGDIR}/${dep}" ]; then
					pull_package "$dep"
				fi
			done
			unset dep
		fi

		if [ ! -e "$package_tmpdir/package.deb" ]; then
			echo "[*] Downloading '$package_name'..."
			curl --fail --location --output "$package_tmpdir/package.deb" "$package_url"

			echo "[*] Extracting '$package_name'..."
			(cd "$package_tmpdir"
				ar x package.deb

				# data.tar may have extension different from .xz
				if [ -f "./data.tar.xz" ]; then
					data_archive="data.tar.xz"
				elif [ -f "./data.tar.gz" ]; then
					data_archive="data.tar.gz"
				else
					echo "No data.tar.* found in '$package_name'."
					exit 1
				fi

				# Do same for control.tar.
				if [ -f "./control.tar.xz" ]; then
					control_archive="control.tar.xz"
				elif [ -f "./control.tar.gz" ]; then
					control_archive="control.tar.gz"
				else
					echo "No control.tar.* found in '$package_name'."
					exit 1
				fi

				# Extract files.
				tar xf "$data_archive" -C "$BOOTSTRAP_ROOTFS"

				if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
					# Register extracted files.
					tar tf "$data_archive" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${package_name}.list"

					# Generate checksums (md5).
					tar xf "$data_archive"
					find data -type f -print0 | xargs -0 -r md5sum | sed 's@^\.$@@g' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${package_name}.md5sums"

					# Extract metadata.
					tar xf "$control_archive"
					{
						cat control
						echo "Status: install ok installed"
						echo
					} >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"

					# Additional data: conffiles & scripts
					for file in conffiles postinst postrm preinst prerm; do
						if [ -f "${PWD}/${file}" ]; then
							cp "$file" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${package_name}.${file}"
						fi
					done
				fi
			)
		fi
	else
		local package_dependencies=$(read_db_packages_pac "DEPENDS" | sed 's/<.*$//g; s/>.*$//g; s/=.*$//g')

		if [ "$package_dependencies" != "null" ]; then
			local dep
			for dep in $package_dependencies; do
				if [ ! -e "${BOOTSTRAP_PKGDIR}/${dep}" ]; then
					pull_package "$dep"
				fi
			done
			unset dep
		fi

		if [ ! -e "$package_tmpdir/package.pkg.tar.xz" ]; then
			echo "[*] Downloading '$package_name'..."
			local package_filename=$(read_db_packages_pac "FILENAME")
			curl --fail --location --output "$package_tmpdir/package.pkg.tar.xz" "${REPO_BASE_URL}/${package_arch}/${package_filename}"

			echo "[*] Extracting '$package_name'..."
			(cd "$package_tmpdir"
				local package_desc="${package_name}-$(read_db_packages_pac VERSION)"
				mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_desc}"
				{
					echo "%FILES%"
					tar xvf package.pkg.tar.xz -C "$BOOTSTRAP_ROOTFS" .INSTALL .MTREE data 2> /dev/null | grep '^data/' || true
				} >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_desc}/files"
				mv "${BOOTSTRAP_ROOTFS}/.MTREE" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_desc}/mtree"
				if [ -f "${BOOTSTRAP_ROOTFS}/.INSTALL" ]; then
					mv "${BOOTSTRAP_ROOTFS}/.INSTALL" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_desc}/install"
				fi
				{
					local keys_desc="VERSION BASE DESC URL ARCH BUILDDATE PACKAGER ISIZE GROUPS LICENSE REPLACES DEPENDS OPTDEPENDS CONFLICTS PROVIDES"
					for i in "NAME ${package_name}" \
						"INSTALLDATE $(date +%s)" \
						"VALIDATION $(test $(read_db_packages_pac PGPSIG) != 'null' && echo 'pgp' || echo 'sha256')"; do
						print_desc_package_pac ${i}
					done
					jq -r -j '."'${package_name}'" | to_entries | .[] | select(.key | contains('$(sed 's/^/"/; s/ /","/g; s/$/"/' <<< ${keys_desc})')) | "%",(if .key == "ISIZE" then "SIZE" else .key end),"%\n",.value,"\n\n" | if type == "array" then (.| join("\n")) else . end' \
						"${PATH_DB_PACKAGES}"
				} >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/${package_desc}/desc"
			)
		fi
	fi
}

# Add termux bootstrap second stage files
add_termux_bootstrap_second_stage_files() {

	local package_arch="$1"

	echo "[*] Adding termux bootstrap second stage files..."

	mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}"
	sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
		-e "s|@TERMUX_PACKAGE_MANAGER@|${TERMUX_PACKAGE_MANAGER}|g" \
		-e "s|@TERMUX_PACKAGE_ARCH@|${package_arch}|g" \
		-e "s|@TERMUX_APP__NAME@|${TERMUX_APP__NAME}|g" \
		-e "s|@TERMUX_ENV__S_TERMUX@|${TERMUX_ENV__S_TERMUX}|g" \
		"$TERMUX_SCRIPTDIR/scripts/bootstrap/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE" \
		> "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"
	chmod 700 "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"

	# TODO: Remove it when Termux app supports `pacman` bootstraps installation.
	sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
		-e "s|@TERMUX__PREFIX__PROFILE_D_DIR@|${TERMUX__PREFIX__PROFILE_D_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
		"$TERMUX_SCRIPTDIR/scripts/bootstrap/01-termux-bootstrap-second-stage-fallback.sh" \
		> "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/01-termux-bootstrap-second-stage-fallback.sh"
	chmod 600 "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/01-termux-bootstrap-second-stage-fallback.sh"

	# Install su/sudo/tsu wrappers for Debian proot compatibility
	local wrapper_scripts=(
		"termux-su-wrapper.sh:su"
		"termux-sudo-wrapper.sh:sudo"
		"termux-tsu-wrapper.sh:tsu-android"
	)
	for wrapper_entry in "${wrapper_scripts[@]}"; do
		local wrapper_script="${wrapper_entry%%:*}"
		local target_name="${wrapper_entry##*:}"
		local wrapper_script_path="$TERMUX_SCRIPTDIR/scripts/$wrapper_script"
		if [ -f "$wrapper_script_path" ]; then
			cp "$wrapper_script_path" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/$target_name"
			chmod 700 "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/$target_name"
		fi
	done

	# Create environment detection script for profile.d
	cat > "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/02-termux-env-detection.sh" <<'ENVEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Detect and configure environment (Debian proot vs Android native)

# Check if running in proot
if [ -n "$PROOT_VERSION" ] || [ -n "$PROOT_DISTRIBUTION" ] || [ -f "/etc/debian_version" ]; then
    export TERMUX_ENV_TYPE="debian-proot"
    export TERMUX_DEBIAN_ROOT="/debian-rootfs"
    
    # Prepend Debian paths if they exist
    if [ -d "/debian-rootfs/usr/bin" ]; then
        export PATH="/debian-rootfs/usr/bin:/debian-rootfs/bin:$PATH"
    fi
    
    # Use Debian's su/sudo
    if [ -x "/debian-rootfs/usr/bin/su" ]; then
        alias su='/debian-rootfs/usr/bin/su'
    fi
    if [ -x "/debian-rootfs/usr/bin/sudo" ]; then
        alias sudo='/debian-rootfs/usr/bin/sudo'
    fi
else
    export TERMUX_ENV_TYPE="android-native"
fi
ENVEOF
	chmod 600 "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/02-termux-env-detection.sh"

}

# Final stage: generate bootstrap archive and place it to current
# working directory.
# Information about symlinks is stored in file SYMLINKS.txt.
create_bootstrap_archive() {
	echo "[*] Creating 'bootstrap-${1}.zip'..."
	(cd "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
		# Do not store symlinks in bootstrap archive.
		# Instead, put all information to SYMLINKS.txt
		while read -r -d '' link; do
			echo "$(readlink "$link")←${link}" >> SYMLINKS.txt
			rm -f "$link"
		done < <(find . -type l -print0)

		zip -r9 "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" ./*
	)

	mv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" ./
	echo "[*] Finished successfully (${1})."
}

show_usage() {
	echo
	echo "Usage: generate-bootstraps.sh [options]"
	echo
	echo "Generate bootstrap archives for Termux application."
	echo
	echo "Options:"
	echo
	echo " -h, --help                  Show this help."
	echo
	echo " --android10                 Generate bootstrap archives for Android 10."
	echo
	echo " --debian-proot              Generate a Debian-based bootstrap using proot."
	echo "                             Downloads a minimal Debian rootfs and includes"
	echo "                             proot to run it without root access."
	echo
	echo " --debian-release RELEASE    Specify Debian release codename (default: bookworm)."
	echo "                             Used only with --debian-proot."
	echo
	echo " -a, --add PKG_LIST          Specify one or more additional packages"
	echo "                             to include into bootstrap archive."
	echo "                             Multiple packages should be passed as"
	echo "                             comma-separated list."
	echo
	echo " --pm MANAGER                Set up a package manager in bootstrap."
	echo "                             It can only be pacman or apt (the default is apt)."
	echo
	echo " --architectures ARCH_LIST   Override default list of architectures"
	echo "                             for which bootstrap archives will be"
	echo "                             created."
	echo "                             Multiple architectures should be passed"
	echo "                             as comma-separated list."
	echo
	echo " -r, --repository URL        Specify URL for APT repository from"
	echo "                             which packages will be downloaded."
	echo "                             This must be passed after '--pm' option."
	echo
	echo "Architectures: ${TERMUX_ARCHITECTURES[*]}"
	echo "Repository Base Url: ${REPO_BASE_URL}"
	echo "Prefix: ${TERMUX_PREFIX}"
        echo "Package manager: ${TERMUX_PACKAGE_MANAGER}"
	echo
}

while (($# > 0)); do
	case "$1" in
		-h|--help)
			show_usage
			exit 0
			;;
		--android10)
			BOOTSTRAP_ANDROID10_COMPATIBLE=true
			;;
		--debian-proot)
			BOOTSTRAP_DEBIAN_PROOT=true
			;;
		--debian-release)
			if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
				DEBIAN_RELEASE="$2"
				shift 1
			else
				echo "[!] Option '--debian-release' requires an argument." 1>&2
				show_usage
				exit 1
			fi
			;;
		-a|--add)
			if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
				for pkg in $(echo "$2" | tr ',' ' '); do
					ADDITIONAL_PACKAGES+=("$pkg")
				done
				unset pkg
				shift 1
			else
				echo "[!] Option '--add' requires an argument."
				show_usage
				exit 1
			fi
			;;
		--pm)
			if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
				TERMUX_PACKAGE_MANAGER="$2"
				REPO_BASE_URL="${REPO_BASE_URLS[${TERMUX_PACKAGE_MANAGER}]}"
				shift 1
			else
				echo "[!] Option '--pm' requires an argument." 1>&2
				show_usage
				exit 1
			fi
			;;
		--architectures)
			if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
				TERMUX_ARCHITECTURES=()
				for arch in $(echo "$2" | tr ',' ' '); do
					TERMUX_ARCHITECTURES+=("$arch")
				done
				unset arch
				shift 1
			else
				echo "[!] Option '--architectures' requires an argument."
				show_usage
				exit 1
			fi
			;;
		-r|--repository)
			if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
				REPO_BASE_URL="$2"
				shift 1
			else
				echo "[!] Option '--repository' requires an argument."
				show_usage
				exit 1
			fi
			;;
		*)
			echo "[!] Got unknown option '$1'"
			show_usage
			exit 1
			;;
	esac
	shift 1
done

if [[ "$TERMUX_PACKAGE_MANAGER" == *" "* ]] || [[ " ${TERMUX_PACKAGE_MANAGERS[*]} " != *" $TERMUX_PACKAGE_MANAGER "* ]]; then
	echo "[!] Invalid package manager '$TERMUX_PACKAGE_MANAGER'" 1>&2
	echo "Supported package managers: '${TERMUX_PACKAGE_MANAGERS[*]}'" 1>&2
	exit 1
fi

if [ -z "$REPO_BASE_URL" ]; then
	echo "[!] The repository base url is not set." 1>&2
	exit 1
fi

for package_arch in "${TERMUX_ARCHITECTURES[@]}"; do
	PATH_DB_PACKAGES="$BOOTSTRAP_TMPDIR/main_${package_arch}.json"
	BOOTSTRAP_ROOTFS="$BOOTSTRAP_TMPDIR/rootfs-${package_arch}"
	BOOTSTRAP_PKGDIR="$BOOTSTRAP_TMPDIR/packages-${package_arch}"

	# Create initial directories for $TERMUX_PREFIX
	if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
		if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/apt.conf.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/preferences.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/triggers"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/updates"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/log/apt"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/available"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"
		else
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/sync"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local"
			echo "9" >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/pacman/local/ALPM_DB_VERSION"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/cache/pacman/pkg"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/log"
		fi
	fi
	mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/tmp"

	# Read package metadata.
	unset PACKAGE_METADATA
	declare -A PACKAGE_METADATA

	if ${BOOTSTRAP_DEBIAN_PROOT}; then
		# ============================================================
		# DEBIAN PROOT MODE
		# Download proot binary from Termux repos and Debian rootfs
		# from official Debian repositories.
		# ============================================================

		echo "[*] Building Debian proot bootstrap for architecture: ${package_arch}"

		# Create basic directories
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin"
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/lib"
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/tmp"
		mkdir -p "${BOOTSTRAP_ROOTFS}/debian-rootfs"

		# Download proot from Termux repositories
		if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
			read_package_list_deb "$package_arch"
		else
			download_db_packages_pac
		fi
		download_proot "$package_arch"

		# Download Debian rootfs
		download_debian_rootfs "$package_arch"

		# Create start-debian.sh script
		create_start_debian_script

		# Create a second stage script for Debian initialization
		echo "[*] Creating Debian second stage initialization script..."
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin"
		cat > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/debian-second-stage.sh" <<EOF
#!/bin/bash
# Debian second stage initialization script
# Runs inside the Debian rootfs via proot to complete setup

set -e

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export LANG=C.UTF-8
export TERM=xterm-256color

echo "[*] Running Debian second stage initialization..."

# Configure locale
echo "[*] Configuring locales..."
apt-get update -y || true
apt-get install -y locales 2>/dev/null || true
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen 2>/dev/null || true
locale-gen en_US.UTF-8 2>/dev/null || true
export LANG=en_US.UTF-8

# Create necessary device nodes (will be bind-mounted by proot)
echo "[*] Setting up environment..."
mkdir -p /dev /proc /sys /tmp /run

# Configure timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime 2>/dev/null || true

# Set root password
echo 'root:debian' | chpasswd 2>/dev/null || true

# Create a regular user
useradd -m -s /bin/bash termux 2>/dev/null || true
echo 'termux:termux' | chpasswd 2>/dev/null || true

echo "[*] Debian second stage complete!"
echo "[*] You can now use apt-get to install packages."
EOF
		chmod 755 "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin/debian-second-stage.sh"

		# Create bootstrap archive
		echo "[*] Creating Debian proot bootstrap archive..."
		(cd "${BOOTSTRAP_ROOTFS}"
			zip -r9 "${BOOTSTRAP_TMPDIR}/bootstrap-${package_arch}.zip" .
		)
		mv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${package_arch}.zip" ./
		echo "[*] Finished successfully (Debian proot: ${package_arch})."

	else
		# ============================================================
		# ORIGINAL TERMUX BOOTSTRAP MODE
		# ============================================================

	if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
		read_package_list_deb "$package_arch"
	else
		download_db_packages_pac
	fi

	# Package manager.
	if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
		pull_package ${TERMUX_PACKAGE_MANAGER}
	fi

	# Core utilities.
	pull_package bash # Used by `termux-bootstrap-second-stage.sh`
	pull_package bzip2
	if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
		pull_package command-not-found
	else
		pull_package proot
	fi
	pull_package coreutils
	pull_package curl
	pull_package dash
	pull_package diffutils
	pull_package findutils
	pull_package gawk
	pull_package grep
	pull_package gzip
	pull_package less
	pull_package procps
	pull_package psmisc
	pull_package sed
	pull_package tar
	pull_package termux-core
	pull_package termux-exec
	pull_package termux-keyring
	pull_package termux-tools
	pull_package util-linux
	pull_package xz-utils

	# Additional.
	pull_package ed
	if [ ${TERMUX_PACKAGE_MANAGER} = "apt" ]; then
		pull_package debianutils
	fi
	pull_package dos2unix
	pull_package inetutils
	pull_package lsof
	pull_package nano
	pull_package net-tools
	pull_package patch
	pull_package unzip

	# Handle additional packages.
	for add_pkg in "${ADDITIONAL_PACKAGES[@]}"; do
		pull_package "$add_pkg"
	done
	unset add_pkg

	# Add termux bootstrap second stage files
	add_termux_bootstrap_second_stage_files "$package_arch"

	# Create bootstrap archive.
	create_bootstrap_archive "$package_arch"

	fi  # End of debian-proot vs original bootstrap mode

done
