# Используем минимальный образ Ubuntu для экономии места
FROM ubuntu:24.04

# Установка зависимостей, необходимых для сборки ядра
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        build-essential \
        automake \
        bison \
        flex \
        libncurses-dev \
        libssl-dev \
        libelf-dev \
        fakeroot \
        xz-utils \
        bc \
        rsync \
        pkg-config \
        crossbuild-essential-arm64 \
        debhelper \
        kmod \
        cpio && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Директория для исходников ядра
WORKDIR /usr/src/linux

# Переменные среды для кросс-компиляции
ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-

# Точка входа в контейнер (переопределяется скриптом)
CMD ["bash"]
