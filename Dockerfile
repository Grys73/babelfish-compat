# Based on https://github.com/jonathanpotts/docker-babelfishpg (MIT, see LICENSE).
# Changes: Babelfish 5.6.0 assembled from source tags, compatibility patches, init.sql, settings in start.sh.

FROM ubuntu:22.04 AS base

# Build stage
FROM base AS builder

# Specify babelfish version by using a tag from:
# https://github.com/babelfish-for-postgresql/babelfish-for-postgresql/tags
ARG BABELFISH_VERSION=BABEL_5_6_0__PG_17_10

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt update && apt install -y --no-install-recommends\
	build-essential flex libxml2-dev libxml2-utils\
	libxslt-dev libssl-dev libreadline-dev zlib1g-dev\
	libldap2-dev libpam0g-dev gettext uuid uuid-dev\
	cmake lld apt-utils libossp-uuid-dev gnulib bison\
	xsltproc icu-devtools libicu70\
	libicu-dev gawk\
	curl openjdk-21-jre openssl\
	g++ libssl-dev python-dev-is-python3 libpq-dev\
	pkg-config libutfcpp-dev\
	gnupg unixodbc-dev net-tools unzip wget

# Download babelfish sources
WORKDIR /workplace

# No official 5.6.0 release bundle: assemble it like the bundle is made,
# modified PostgreSQL source + babelfish_extensions/contrib copied into contrib.
ARG PG_TAG=BABEL_5_6_0__PG_17_10
ARG EXT_TAG=BABEL_5_6_0
ENV GH=https://github.com/babelfish-for-postgresql
RUN wget -O pg.tar.gz ${GH}/postgresql_modified_for_babelfish/archive/refs/tags/${PG_TAG}.tar.gz  && wget -O ext.tar.gz ${GH}/babelfish_extensions/archive/refs/tags/${EXT_TAG}.tar.gz  && mkdir pg ext && tar -xzf pg.tar.gz -C pg --strip-components=1 && tar -xzf ext.tar.gz -C ext --strip-components=1  && cp -r ext/contrib/babelfishpg_* pg/contrib/ && mv pg ${BABELFISH_VERSION} && rm -rf ext pg.tar.gz ext.tar.gz

# Compatibility patches on top of the tags (see README, 'Patches').
COPY patches/*.patch /workplace/patches/
RUN apt-get install -y patch && cd ${BABELFISH_VERSION} && for p in /workplace/patches/*.patch; do patch -p1 < $p || exit 1; done

# Set environment variables
ENV JOBS=16
ENV BABELFISH_HOME=/opt/babelfish
ENV PG_CONFIG=${BABELFISH_HOME}/bin/pg_config
ENV PG_SRC=/workplace/${BABELFISH_VERSION}

WORKDIR ${PG_SRC}

ENV PG_CONFIG=${BABELFISH_HOME}/bin/pg_config

# Compile ANTLR 4
ENV ANTLR4_VERSION=4.13.2
ENV ANTLR4_JAVA_BIN=/usr/bin/java
ENV ANTLR4_RUNTIME_LIBRARIES=/usr/include/antlr4-runtime
ENV ANTLR_FILE=antlr-${ANTLR4_VERSION}-complete.jar
ENV ANTLR_EXECUTABLE=/usr/local/lib/${ANTLR_FILE}
ENV ANTLR_CONTRIB=${PG_SRC}/contrib/babelfishpg_tsql/antlr/thirdparty/antlr
ENV ANTLR_RUNTIME=/workplace/antlr4

RUN cp ${ANTLR_CONTRIB}/${ANTLR_FILE} /usr/local/lib

WORKDIR /workplace

ENV ANTLR_DOWNLOAD=http://www.antlr.org/download
ENV ANTLR_CPP_SOURCE=antlr4-cpp-runtime-${ANTLR4_VERSION}-source.zip

RUN wget ${ANTLR_DOWNLOAD}/${ANTLR_CPP_SOURCE}
RUN unzip -d ${ANTLR_RUNTIME} ${ANTLR_CPP_SOURCE}

WORKDIR ${ANTLR_RUNTIME}/build

RUN cmake .. -D\
	ANTLR_JAR_LOCATION=${ANTLR_EXECUTABLE}\
	-DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_DEMO=True
RUN make -j ${JOBS} && make install

# Build modified PostgreSQL for Babelfish
WORKDIR ${PG_SRC}

RUN ./configure CFLAGS="-ggdb"\
	--prefix=${BABELFISH_HOME}/\
	--enable-debug\
	--with-ldap\
	--with-libxml\
	--with-pam\
	--with-uuid=ossp\
	--enable-nls\
	--with-libxslt\
	--with-icu\
	--with-openssl

RUN make DESTDIR=${BABELFISH_HOME}/ -j ${JOBS} 2>error.txt && make install

WORKDIR ${PG_SRC}/contrib
RUN make -j ${JOBS} && make install

# Compile the ANTLR parser generator
RUN cp /usr/local/lib/libantlr4-runtime.so.${ANTLR4_VERSION}\
	${BABELFISH_HOME}/lib

WORKDIR ${PG_SRC}/contrib/babelfishpg_tsql/antlr
RUN cmake -Wno-dev .
RUN make all

# Compile the contrib modules and build Babelfish
WORKDIR ${PG_SRC}/contrib/babelfishpg_common
RUN make -j ${JOBS} && make PG_CONFIG=${PG_CONFIG} install

WORKDIR ${PG_SRC}/contrib/babelfishpg_money
RUN make -j ${JOBS} && make PG_CONFIG=${PG_CONFIG} install

WORKDIR ${PG_SRC}/contrib/babelfishpg_tds
RUN make -j ${JOBS} && make PG_CONFIG=${PG_CONFIG} install

WORKDIR ${PG_SRC}/contrib/babelfishpg_tsql
RUN make -j ${JOBS} && make PG_CONFIG=${PG_CONFIG} install

# Run stage
FROM base AS runner
ENV BABELFISH_HOME=/opt/babelfish
ENV POSTGRES_USER_HOME=/var/lib/babelfish
EXPOSE 1433 5432
ENTRYPOINT [ "/start.sh" ]

# Install runtime dependencies
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt update && apt install -y --no-install-recommends\
	libssl3 openssl libldap-2.5-0 libxml2 libpam0g uuid libossp-uuid16\
	libxslt1.1 libicu70 libpq5 unixodbc

RUN adduser postgres --home ${POSTGRES_USER_HOME}

# Copy binaries to run stage
COPY --chmod=755 start.sh /
COPY init.sql /
WORKDIR ${BABELFISH_HOME}
COPY --from=builder --chown=postgres ${BABELFISH_HOME} .

# Enable data volume
ENV BABELFISH_DATA=${POSTGRES_USER_HOME}/data
RUN install -d -o postgres -g postgres ${BABELFISH_DATA}
VOLUME ${BABELFISH_DATA}

# Switch runtime user in container
USER postgres
