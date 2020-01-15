FROM alpine:3.10 AS build-qemu

MAINTAINER Martin Kjellstrand [https://github.com/madworx]

ARG QEMU_RELEASE="v4.0.0"

ARG QEMU_BUILD_PKGS="build-base lzo-dev jpeg-dev sdl2-dev libcap-ng-dev \
                     git-email xen-dev bison libssh2-dev cyrus-sasl-dev \
                     ncurses-dev libnfs-dev  libseccomp-dev  libaio-dev \
                     flex bash curl-dev libcap-dev snappy-dev bzip2-dev \
                     sed"

ARG QEMU_DISABLE_FEATURES="lzo capstone libssh2 smartcard opengl gcrypt \
                           cocoa sdl nettle guest-agent-msi guest-agent \
                           brlapi glusterfs xen-pci-passthrough  xfsctl \
                           vxhs replication crypto-afalg qom-cast-debug \
                           bzip2 bsd-user rdma usb-redir user debug-tcg \
                           vhost-net  tools  virglrenderer  tpm  gnutls \
                           linux-user snappy docs  gtk  libiscsi  bluez \
                           debug-info xen libnfs modules vte numa mpath \
                           live-block-migration spice"

ARG RETAIN_BIOSES="vgabios-stdvga.bin \ 
                   bios-256k.bin      \
                   efi-e1000.rom      \
                   kvmvapic.bin"

RUN apk add --no-cache ${QEMU_BUILD_PKGS}

SHELL [ "/bin/bash", "-c" ]

#
# We need to patch  a few things in Alpine linux  header files to make
# qemu compile. We'll do it the fugly way...
#
RUN echo "#include <sys/timex.h>" >> /usr/include/time.h
  
RUN adduser -S bob \
    && mkdir -p /build \
    && chown bob /build

USER bob
  
RUN cd /build \
    && git clone --depth 1 --single-branch \
           -b ${QEMU_RELEASE} \
           git://git.qemu-project.org/qemu.git

#
# Apply or a-little-bit-more structured patches:
#
COPY patches/*.patch /build/qemu/

RUN cd /build/qemu \
    && patch -p1 < qemu-root-path.patch \
    && patch -p1 < qemu-clientid-bootfile-handling.patch \
    && patch -p1 < qemu-envcmdline.patch \
    && patch -p1 < qemu-4.0-alpine-compilefix.patch \
    && sed -e '1i#include <pty.h>' -i util/qemu-openpty.c \
    && sed -e '1i#include <linux/limits.h>' -i hw/9pfs/9p.c \
    && sed -e '/^#define PAGE_SIZE/d' -i accel/kvm/kvm-all.c \
    && sed -e 's/#include <sys\/signal.h>/#include <signal.h>/' \
           -i util/oslib-posix.c

RUN cd /build/qemu \
    && set -x \
    && ./configure \
           $(echo "${QEMU_DISABLE_FEATURES}" | \
             sed -e 's#^\|  *# --disable-#g') \
           --target-list=$(uname -m)-softmmu \
           --prefix=/usr \
           --sysconfdir=/etc

USER root
RUN cd /build/qemu \
    && make -j$(nproc) \
    && make qemu-img

USER root
RUN cd /build/qemu \
    && DESTDIR=/tmp/qemu make install \
    && cp qemu-img /tmp/qemu/usr/bin/

# Let's trim up the toupé!
RUN find /tmp/qemu/usr/share/qemu/ -type f -maxdepth 1 \
    | egrep -v "/($(echo ${RETAIN_BIOSES} | sed 's#  *#|#g'))\$" \
    | xargs -r rm && \
    find /tmp/qemu/usr/share/qemu/keymaps/ -type f \
    | egrep -v '/en-gb$' | xargs -r rm

# Build our patched copy of unfs3
FROM alpine:3.11 AS build-unfs3

RUN apk add alpine-sdk gawk
WORKDIR /build/
RUN git clone --depth=1 --single-branch https://git.alpinelinux.org/aports
WORKDIR /build/aports/main/unfs3
COPY patches/unfs3-0.9.22-listen.patch .
RUN sed -e '/^\t.*[.]patch$/a \        unfs3-0.9.22-listen.patch' -i APKBUILD
RUN gawk -i inplace '/^pkgrel=/{FS="=";$0=$0;$0=$1 FS $2+1} //' APKBUILD
RUN adduser -D -G abuild abuild \
    && chown -R abuild /build \
    && mkdir -p /var/cache/distfiles \
    && chmod a+w /var/cache/distfiles \
    && su - abuild sh -c "cd ${PWD} && abuild-keygen -a && /usr/bin/abuild checksum && /usr/bin/abuild -r"

RUN find / -name '*.apk'

# Preferrably we would have built an Alpine 'apk' package here instead.

FROM alpine:3.11

ARG QEMU_RUNTIME_PKGS="busybox-extras libpng pixman libseccomp  openssh \
                       bash curl libjpeg libaio cyrus-sasl \
                       libgcc glib"

COPY --from=build-unfs3 /home/abuild/packages/main/*/unfs3-*.apk /tmp/
RUN apk add --no-cache ${QEMU_RUNTIME_PKGS} \
    && apk add --allow-untrusted /tmp/unfs3-*.apk \
    && rm /tmp/unfs3-*.apk

COPY --from=build-qemu /tmp/qemu/* /usr/
