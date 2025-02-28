# hadolint global ignore=DL3018
FROM alpine:3.17.2 as build

ARG SQUID_VER=5.8

RUN set -x && \
    apk add --no-cache \
        gcc \
        g++ \
        libc-dev \
        curl \
        gnupg \
        libldap \
        openldap-dev \
        openssl-dev \
        openssl-libs-static \
        perl-dev \
        autoconf \
        automake \
        make \
        pkgconfig \
        heimdal-dev \
        libtool \
        libcap-dev \
        linux-headers

WORKDIR /tmp/build

RUN set -x && \
    curl -fsSL -o squid-${SQUID_VER}.tar.gz http://www.squid-cache.org/Versions/v${SQUID_VER%%.*}/squid-${SQUID_VER}.tar.gz && \
    curl -fsSL -o squid-${SQUID_VER}.tar.gz.asc http://www.squid-cache.org/Versions/v${SQUID_VER%%.*}/squid-${SQUID_VER}.tar.gz.asc

COPY squid-keys.asc /tmp/build

RUN set -x && \
    GNUPGHOME="$(mktemp -d)" && \
    export GNUPGHOME && \
    gpg --import squid-keys.asc && \
    gpg --batch --verify squid-${SQUID_VER}.tar.gz.asc squid-${SQUID_VER}.tar.gz && \
    rm -rf "$GNUPGHOME"

RUN set -x && \
    tar --strip 1 -xzf "squid-${SQUID_VER}.tar.gz" && \
    \
    MACHINE=$(uname -m) && \
    \
    CFLAGS="-g0 -O2" \
    CXXFLAGS="-g0 -O2" \
    LDFLAGS="-s" \
    \
    ./configure \
        --build="$MACHINE" \
        --host="$MACHINE" \
        --prefix=/usr \
        --datadir=/usr/share/squid \
        --sysconfdir=/etc/squid \
        --libexecdir=/usr/lib/squid \
        --localstatedir=/var \
        --with-logdir=/var/log/squid \
        --disable-strict-error-checking \
        --disable-arch-native \
        --enable-removal-policies="lru,heap" \
        --enable-auth-digest="LDAP" \
        --enable-auth-basic="getpwnam,DB,LDAP,NCSA" \
        --enable-basic-auth-helpers="DB" \
        --enable-epoll \
        --enable-external-acl-helpers="file_userip,unix_group,wbinfo_group" \
        --enable-auth-ntlm="fake" \
        --enable-auth-negotiate="kerberos,wrapper" \
        --enable-silent-rules \
        --disable-mit \
        --enable-heimdal \
        --enable-delay-pools \
        --enable-arp-acl \
        --enable-openssl \
        --enable-ssl-crtd \
        --enable-security-cert-generators="file" \
        --enable-ident-lookups \
        --enable-useragent-log \
        --enable-cache-digests \
        --enable-referer-log \
        --enable-async-io \
        --enable-truncate \
        --enable-arp-acl \
        --enable-htcp \
        --enable-carp \
        --enable-follow-x-forwarded-for \
        --enable-storeio="diskd rock" \
        --enable-ipv6 \
        --enable-translation \
        --disable-snmp \
        --disable-dependency-tracking \
        --with-large-files \
        --with-default-user=squid \
        --with-openssl \
        --with-pidfile=/var/run/squid/squid.pid

RUN set -x && \
    nproc=$(n=$(nproc) ; max_n=6 ; echo $(( n <= max_n ? n : max_n )) ) && \
    make -j $nproc && \
    make install

WORKDIR /tmp/build/tools/squidclient
RUN make && make install-strip

RUN sed -i '/localnet/s/^# //g' /etc/squid/squid.conf && \
    sed -i '1s;^;include /etc/squid/conf.d/*.conf\n;' /etc/squid/squid.conf && \
    echo 'include /etc/squid/conf.d.tail/*.conf' >> /etc/squid/squid.conf

# --- --- --- --- --- --- --- --- ---

FROM alpine:3.17.2

ENV SQUID_CONFIG_FILE /etc/squid/squid.conf
ENV TZ Europe/Moscow

RUN set -x && \
    deluser squid 2>/dev/null; delgroup squid 2>/dev/null; \
    addgroup -S squid -g 3128 && \
    adduser -S -u 3128 -G squid -g squid -H -D -s /bin/false -h /var/cache/squid squid

RUN set -x && \
    apk add --no-cache \
        libstdc++ \
        heimdal-libs \
        libldap \
        libcap \
        libltdl && \
    apk add --no-cache --virtual .tz alpine-conf tzdata && \ 
    /sbin/setup-timezone -z $TZ && \
    apk del .tz

COPY --from=build /etc/squid/ /etc/squid/
COPY --from=build /usr/lib/squid/ /usr/lib/squid/
COPY --from=build /usr/share/squid/ /usr/share/squid/
COPY --from=build /usr/sbin/squid /usr/sbin/squid
COPY --from=build /usr/bin/squidclient /usr/bin/squidclient

RUN install -d -o squid -g squid \
        /var/cache/squid \
        /var/log/squid \
        /var/run/squid && \
    chmod +x /usr/lib/squid/* && \
    install -d -m 755 -o squid -g squid \
        /etc/squid/conf.d \
        /etc/squid/conf.d.tail && \
    touch /etc/squid/conf.d/placeholder.conf

COPY squid-log.conf /etc/squid/conf.d.tail/

USER squid

EXPOSE 3128/tcp

VOLUME ["/var/cache/squid"]

CMD ["sh", "-c", "/usr/sbin/squid -f ${SQUID_CONFIG_FILE} --foreground -z && exec /usr/sbin/squid -f ${SQUID_CONFIG_FILE} --foreground -YCd 1"]
