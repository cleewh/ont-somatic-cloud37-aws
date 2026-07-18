# cloud37 B1c — align/merge job container: minimap2 + samtools + aws-cli.
# Pinned versions to keep alignment deterministic/concordant with the HealthOmics
# minimap2_alignment step. Built for x86_64 (Batch on-demand EC2).
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

ARG SAMTOOLS_VER=1.20
ARG MINIMAP2_VER=2.28

RUN dnf -y install tar bzip2 gzip xz make gcc gcc-c++ zlib-devel bzip2-devel \
        xz-devel ncurses-devel libcurl-devel openssl-devel unzip which \
    && dnf clean all

# aws-cli v2
RUN curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip

# samtools
RUN curl -sSL "https://github.com/samtools/samtools/releases/download/${SAMTOOLS_VER}/samtools-${SAMTOOLS_VER}.tar.bz2" -o /tmp/st.tar.bz2 \
    && cd /tmp && tar xjf st.tar.bz2 && cd samtools-${SAMTOOLS_VER} \
    && ./configure && make -j4 && make install && cd / && rm -rf /tmp/samtools-${SAMTOOLS_VER} /tmp/st.tar.bz2

# minimap2 (prebuilt x86_64)
RUN curl -sSL "https://github.com/lh3/minimap2/releases/download/v${MINIMAP2_VER}/minimap2-${MINIMAP2_VER}_x64-linux.tar.bz2" -o /tmp/mm2.tar.bz2 \
    && cd /tmp && tar xjf mm2.tar.bz2 && install -m0755 minimap2-${MINIMAP2_VER}_x64-linux/minimap2 /usr/local/bin/minimap2 \
    && rm -rf /tmp/minimap2-${MINIMAP2_VER}_x64-linux /tmp/mm2.tar.bz2

COPY align_job.sh /opt/align_job.sh
COPY merge_job.sh /opt/merge_job.sh
RUN chmod +x /opt/align_job.sh /opt/merge_job.sh

WORKDIR /scratch
