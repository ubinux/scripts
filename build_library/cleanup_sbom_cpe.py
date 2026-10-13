#!/usr/bin/env python3
"""Post-process an SPDX SBOM to fix invalid CPE entries for Portage packages.

Syft generates CPE entries for all packages, but for Portage packages it
uses the full category/name as both vendor and product (e.g.
"dev-libs/openssl" -> "cpe:2.3:a:dev-libs\\/openssl:dev-libs\\/openssl..."),
which does not match any entries in the NVD CPE database.

This script corrects CPEs by looking up the correct vendor:product mapping
from a curated CPE_MAP table (see CPE_MAP below).

Virtual and acct-* packages are left untouched since even though they have
no matching NVD entries, keeping their CPEs is harmless.

Usage:
    cleanup_sbom_cpe.py <sbom.json> [output.json]

If output.json is omitted, the input file is modified in-place.
"""

import json
import sys

PORTAGE_SPDX_PREFIX = "SPDXRef-Package-portage-"

# CPE_MAP: Portage bare package name -> (vendor, product) or
# (part, vendor, product) for CPE generation.
# Sources: NVD CPE dictionary (nvd.nist.gov), upstream project names, syft
# dictionary.
CPE_MAP = {
    # GNU project software
    "bash": ("gnu", "bash"),
    "bc": ("gnu", "bc"),
    "binutils": ("gnu", "binutils"),
    "binutils-config": ("gnu", "binutils"),
    "binutils-libs": ("gnu", "binutils"),
    "coreutils": ("gnu", "coreutils"),
    "cpio": ("gnu", "cpio"),
    "diffutils": ("gnu", "diffutils"),
    "findutils": ("gnu", "findutils"),
    "gawk": ("gnu", "gawk"),
    "gdbm": ("gnu", "gdbm"),
    "gettext": ("gnu", "gettext"),
    "glibc": ("gnu", "glibc"),
    "gmp": ("gmplib", "gmp"),
    "gnutls": ("gnu", "gnutls"),
    "grep": ("gnu", "grep"),
    "gzip": ("gnu", "gzip"),
    "less": ("gnu", "less"),
    "libidn2": ("gnu", "libidn2"),
    "libmicrohttpd": ("gnu", "libmicrohttpd"),
    "libtasn1": ("gnu", "libtasn1"),
    "libunistring": ("gnu", "libunistring"),
    "ncurses": ("gnu", "ncurses"),
    "nettle": ("gnu", "nettle"),
    "parted": ("gnu", "parted"),
    "readline": ("gnu", "readline"),
    "sed": ("gnu", "sed"),
    "tar": ("gnu", "tar"),
    "wget": ("gnu", "wget"),

    # GNOME / freedesktop.org
    "dbus": ("freedesktop", "dbus"),
    "dbus-glib": ("freedesktop", "dbus-glib"),
    "glib": ("gnome", "glib"),
    "polkit": ("freedesktop", "policykit"),
    "systemd": ("freedesktop", "systemd"),

    # GnuPG
    "gnupg": ("gnupg", "gnupg"),
    "gpg": ("gnupg", "gnupg"),
    "libassuan": ("gnupg", "libassuan"),
    "libgcrypt": ("gnupg", "libgcrypt"),
    "libgpg-error": ("gnupg", "libgpg-error"),
    "libksba": ("gnupg", "libksba"),
    "npth": ("gnupg", "npth"),
    "pinentry": ("gnupg", "pinentry"),

    # ISC
    "bind": ("isc", "bind"),

    # MIT
    "mit-krb5": ("mit", "kerberos"),
    "libtirpc": ("mit", "libtirpc"),

    # OpenBSD
    "openbsd-netcat": ("openbsd", "netcat"),
    "openssh": ("openbsd", "openssh"),

    # Netfilter
    "conntrack-tools": ("netfilter", "conntrack"),
    "ebtables": ("netfilter", "ebtables"),
    "ipset": ("netfilter", "ipset"),
    "iptables": ("netfilter", "iptables"),
    "libmnl": ("netfilter", "libmnl"),
    "libnetfilter_conntrack": ("netfilter", "libnetfilter_conntrack"),
    "libnetfilter_cthelper": ("netfilter", "libnetfilter_cthelper"),
    "libnetfilter_cttimeout": ("netfilter", "libnetfilter_cttimeout"),
    "libnetfilter_queue": ("netfilter", "libnetfilter_queue"),
    "libnfnetlink": ("netfilter", "libnfnetlink"),
    "libnftnl": ("netfilter", "libnftnl"),
    "nftables": ("netfilter", "nftables"),

    # Linux kernel / kernel-related
    "kmod": ("kernel", "kmod"),
    "linux-headers": ("kernel", "linux-headers"),

    # Samba
    "samba": ("samba", "samba"),
    "talloc": ("samba", "talloc"),
    "tdb": ("samba", "tdb"),
    "tevent": ("samba", "tevent"),

    # libexpat
    "expat": ("libexpat", "expat"),

    # Linux-PAM
    "pam": ("linux-pam", "linux-pam"),
    "pambase": ("linux-pam", "linux-pam"),

    # Cyrus SASL
    "cyrus-sasl": ("cyrus", "cyrus-sasl"),

    # tcpdump.org
    "libpcap": ("tcpdump", "libpcap"),
    "tcpdump": ("tcpdump", "tcpdump"),

    # SELinux
    "checkpolicy": ("selinux", "checkpolicy"),
    "libselinux": ("selinux", "libselinux"),
    "libsemanage": ("selinux", "libsemanage"),
    "libsepol": ("selinux", "libsepol"),
    "policycoreutils": ("selinux", "policycoreutils"),
    "selinux-base": ("selinux", "selinux-base"),
    "selinux-base-policy": ("selinux", "selinux-base-policy"),
    "selinux-container": ("selinux", "selinux-container"),
    "selinux-dbus": ("selinux", "selinux-dbus"),
    "selinux-policykit": ("selinux", "selinux-policykit"),
    "selinux-sssd": ("selinux", "selinux-sssd"),
    "selinux-unconfined": ("selinux", "selinux-unconfined"),
    "semodule-utils": ("selinux", "semodule-utils"),

    # Docker / OCI / Kubernetes
    "containerd": ("containerd", "containerd"),
    "cri-tools": ("kubernetes", "cri-tools"),
    "docker": ("docker", "docker"),
    "docker-buildx": ("docker", "buildx"),
    "docker-cli": ("docker", "docker"),
    "runc": ("runc", "runc"),

    # Cloud / Infrastructure
    "etcd": ("etcd", "etcd"),
    "etcd-wrapper": ("etcd", "etcd"),

    # Security / crypto
    "adcli": ("adcli", "adcli"),
    "google-oslogin": ("google", "oslogin"),
    "argon2": ("argon2", "argon2"),
    "clevis": ("clevis", "clevis"),
    "go-tspi": ("go-tspi", "go-tspi"),
    "libmd": ("libmd", "libmd"),
    "libsodium": ("libsodium", "libsodium"),
    "nss-usrfiles": ("nss", "usrfiles"),
    "openssl": ("openssl", "openssl"),
    "tpmpolicy": ("tpmpolicy", "tpmpolicy"),
    "trousers": ("trousers", "trousers"),

    # Networking
    "c-ares": ("c-ares", "c-ares"),
    "curl": ("curl", "curl"),
    "libnl": ("libnl", "libnl"),
    "libpsl": ("libpsl", "libpsl"),
    "libuv": ("libuv", "libuv"),
    "nghttp2": ("nghttp2", "nghttp2"),
    "ntp": ("ntp", "ntp"),
    "wireguard-tools": ("wireguard-tools", "wireguard-tools"),

    # Compression / Archive
    "bzip2": ("bzip", "bzip2"),
    "lbzip2": ("lbzip2", "lbzip2"),
    "libarchive": ("libarchive", "libarchive"),
    "lz4": ("lz4", "lz4"),
    "ncompress": ("ncompress", "ncompress"),
    "pigz": ("pigz", "pigz"),
    "unzip": ("unzip", "unzip"),
    "xz-utils": ("tukaani", "xz"),
    "zip": ("zip", "zip"),
    "zstd": ("zstd", "zstd"),

    # System libraries
    "cracklib": ("cracklib", "cracklib"),
    "efivar": ("efivar", "efivar"),
    "elfutils": ("elfutils", "elfutils"),
    "inih": ("inih", "inih"),
    "jansson": ("jansson", "jansson"),
    "jose": ("jose", "jose"),
    "json-c": ("json-c", "json-c"),
    "keyutils": ("keyutils", "keyutils"),
    "libaio": ("libaio", "libaio"),
    "libbsd": ("libbsd", "libbsd"),
    "libcap": ("libcap", "libcap"),
    "libcap-ng": ("libcap-ng", "libcap-ng"),
    "libev": ("libev", "libev"),
    "libevent": ("libevent", "libevent"),
    "libffi": ("libffi", "libffi"),
    "libnvme": ("libnvme", "libnvme"),
    "libpcre2": ("pcre", "pcre2"),
    "libpwquality": ("libpwquality", "libpwquality"),
    "libseccomp": ("libseccomp", "libseccomp"),
    "libunwind": ("libunwind", "libunwind"),
    "liburing": ("liburing", "liburing"),
    "libusb": ("libusb", "libusb"),
    "libverto": ("libverto", "libverto"),
    "libxcrypt": ("libxcrypt", "libxcrypt"),
    "libxml2": ("xmlsoft", "libxml2"),
    "lzo": ("lzo", "lzo"),
    "luksmeta": ("luksmeta", "luksmeta"),
    "oniguruma": ("oniguruma", "oniguruma"),
    "popt": ("rpm", "popt"),
    "protobuf": ("google", "protobuf"),
    "sqlite": ("sqlite", "sqlite"),
    "userspace-rcu": ("urcu", "userspace-rcu"),
    "zlib": ("zlib", "zlib"),

    # System utilities
    "acl": ("acl", "acl"),
    "attr": ("attr", "attr"),
    "audit": ("linux", "audit"),
    "bpftool": ("bpftool", "bpftool"),
    "bsdiff": ("bsdiff", "bsdiff"),
    "cryptsetup": ("cryptsetup", "cryptsetup"),
    "ding-libs": ("ding-libs", "ding-libs"),
    "dracut": ("dracut", "dracut"),
    "duktape": ("duktape", "duktape"),
    "e2fsprogs": ("e2fsprogs", "e2fsprogs"),
    "efibootmgr": ("efibootmgr", "efibootmgr"),
    "ethtool": ("ethtool", "ethtool"),
    "gflags": ("gflags", "gflags"),
    "git": ("git", "git"),
    "glog": ("glog", "glog"),
    "gptfdisk": ("gptfdisk", "gptfdisk"),
    "hwdata": ("hwdata", "hwdata"),
    "iproute2": ("iproute2", "iproute2"),
    "iputils": ("iputils", "iputils"),
    "ipvsadm": ("ipvsadm", "ipvsadm"),
    "kbd": ("kbd", "kbd"),
    "kexec-tools": ("kexec-tools", "kexec-tools"),
    "lshw": ("lshw", "lshw"),
    "lsof": ("lsof", "lsof"),
    "lvm2": ("redhat", "lvm2"),
    "mdadm": ("mdadm", "mdadm"),
    "mokutil": ("mokutil", "mokutil"),
    "net-tools": ("net-tools", "net-tools"),
    "nvme-cli": ("nvme-cli", "nvme-cli"),
    "open-iscsi": ("open-iscsi", "open-iscsi"),
    "open-isns": ("open-isns", "open-isns"),
    "pax-utils": ("pax-utils", "pax-utils"),
    "pciutils": ("pciutils", "pciutils"),
    "pkgconf": ("pkgconf", "pkgconf"),
    "procps": ("procps-ng", "procps-ng"),
    "quota": ("quota", "quota"),
    "realmd": ("realmd", "realmd"),
    "rpcbind": ("rpcbind", "rpcbind"),
    "rpcsvc-proto": ("rpcsvc-proto", "rpcsvc-proto"),
    "shadow": ("shadow", "shadow"),
    "sssd": ("sssd", "sssd"),
    "sudo": ("sudo_project", "sudo"),
    "thin-provisioning-tools": ("thin-provisioning-tools", "thin-provisioning-tools"),
    "timezone-data": ("timezone-data", "timezone-data"),
    "traceroute": ("traceroute", "traceroute"),
    "usbutils": ("usbutils", "usbutils"),
    "util-linux": ("util-linux", "util-linux"),
    "which": ("which", "which"),
    "zram-generator": ("zram-generator", "zram-generator"),

    # Network filesystem
    "cifs-utils": ("cifs-utils", "cifs-utils"),
    "nfs-utils": ("nfs-utils", "nfs-utils"),

    # Network services
    "openldap": ("openldap", "openldap"),
    "bridge-utils": ("bridge-utils", "bridge-utils"),
    "ethertypes": ("ethertypes", "ethertypes"),
    "rsync": ("rsync", "rsync"),
    "socat": ("socat", "socat"),
    "whois": ("whois", "whois"),

    # Filesystem
    "btrfs-progs": ("btrfs-progs", "btrfs-progs"),
    "dosfstools": ("dosfstools", "dosfstools"),
    "lsscsi": ("lsscsi", "lsscsi"),
    "multipath-tools": ("multipath-tools", "multipath-tools"),
    "xfsprogs": ("xfsprogs", "xfsprogs"),

    # Virtualization
    "qemu-guest-agent": ("qemu", "qemu"),
    "xenserver-pv-version": ("xen", "xen"),
    "xenstore": ("xen", "xen"),

    # Editors
    "vim": ("vim", "vim"),
    "vim-core": ("vim", "vim"),

    # TPM
    "tpm2-tools": ("tpm2", "tpm2-tools"),
    "tpm2-tss": ("tpm2", "tss"),

    # Misc
    "acpid": ("acpid", "acpid"),
    "c_rehash": ("c_rehash", "c_rehash"),
    "ca-certificates": ("ca-certificates", "ca-certificates"),
    "jq": ("stedolan", "jq"),
    "logrotate": ("logrotate", "logrotate"),
    "p11-kit": ("p11-kit", "p11-kit"),
    "strace": ("strace", "strace"),
    "tini": ("tini", "tini"),

    # Flatcar / CoreOS internal packages
    "afterburn": ("afterburn", "afterburn"),
    "azure-vm-utils": ("flatcar", "azure-vm-utils"),
    "baselayout": ("baselayout", "baselayout"),
    "coreos": ("coreos", "coreos"),
    "coreos-au-key": ("coreos-au-key", "coreos-au-key"),
    "coreos-cloudinit": ("coreos-cloudinit", "coreos-cloudinit"),
    "coreos-firmware": ("coreos-firmware", "coreos-firmware"),
    "coreos-init": ("coreos-init", "coreos-init"),
    "coreos-kernel": ("o", "linux", "linux_kernel"),
    "coreos-modules": ("coreos-modules", "coreos-modules"),
    "flannel-wrapper": ("flannel-wrapper", "flannel-wrapper"),
    "gentoo-functions": ("gentoo-functions", "gentoo-functions"),
    "ignition": ("ignition", "ignition"),
    "locksmith": ("locksmith", "locksmith"),
    "mayday": ("mayday", "mayday"),
    "misc-files": ("misc-files", "misc-files"),
    "nvidia-drivers-service": ("nvidia", "nvidia-drivers"),
    "sdnotify-proxy": ("sdnotify-proxy", "sdnotify-proxy"),
    "seismograph": ("seismograph", "seismograph"),
    "toolbox": ("toolbox", "toolbox"),
    "ue-rs": ("ue-rs", "ue-rs"),
    "update-ssh-keys": ("update-ssh-keys", "update-ssh-keys"),
    "update_engine": ("flatcar", "update_engine"),

    # Gentoo alternatives (virtual-like, no real NVD entries)
    "awk": ("awk", "awk"),
}


def cpe23(vendor, product, version, part="a"):
    """Build a CPE 2.3 URI string."""
    return f"cpe:2.3:{part}:{vendor}:{product}:{version}:*:*:*:*:*:*:*"


def main():
    if len(sys.argv) not in (2, 3):
        print(f"Usage: {sys.argv[0]} <sbom.json> [output.json]", file=sys.stderr)
        print(f"  If output.json is omitted, writes to input path in-place.", file=sys.stderr)
        sys.exit(1)

    in_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) == 3 else in_path

    with open(in_path) as f:
        data = json.load(f)

    stats = {"corrected": 0, "skipped": 0}

    for pkg in data.get("packages", []):
        name = pkg.get("name", "")
        spdxid = pkg.get("SPDXID", "")
        version = pkg.get("versionInfo", "")

        refs = pkg.get("externalRefs", [])

        if not (spdxid.startswith(PORTAGE_SPDX_PREFIX) and "/" in name):
            stats["skipped"] += 1
            continue

        bare_name = name.split("/", 1)[1]
        if not bare_name or bare_name not in CPE_MAP:
            stats["skipped"] += 1
            continue

        # Replace SECURITY refs with a single correct CPE
        mapping = CPE_MAP[bare_name]
        if len(mapping) == 2:
            vendor, product = mapping
            part = "a"
        elif len(mapping) == 3:
            part, vendor, product = mapping
        else:
            stats["skipped"] += 1
            continue

        new_refs = [
            r for r in refs if r.get("referenceCategory") != "SECURITY"
        ]
        new_refs.append({
            "referenceCategory": "SECURITY",
            "referenceType": "cpe23Type",
            "referenceLocator": cpe23(vendor, product, version, part=part),
        })
        pkg["externalRefs"] = new_refs
        stats["corrected"] += 1

    with open(out_path, "w") as f:
        json.dump(data, f, indent=2)

    print(
        f"[INFO] SBOM CPE cleanup: {stats['corrected']} packages corrected, "
        f"{stats['skipped']} non-portage / virtual / acct packages skipped",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
