#!/bin/bash

# --- Настройки репозитория ---
KERNEL_GIT_URL="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-6.1.y" # Используем актуальную ветку RPi

# --- Настройки локальной среды ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
DOCKER_IMAGE_NAME="rpi5-kernel-builder"
CONTAINER_NAME="rpi5-kernel-build-temp"
KERNEL_DIR="$SCRIPT_DIR/raspberrypi-linux"
CONFIG_FILE="$SCRIPT_DIR/.config"
MODULES_ARCHIVE="modules_rpi5.tar.gz"
OUTPUT_DIR="$SCRIPT_DIR/output"

# --- Требуемые конфигурации для IOSM и WPA3/SAE ---
REQUIRED_CONFIGS=(
    "CONFIG_IOSM=m"
    "CONFIG_MAC80211_SAE=y"
    "CONFIG_CFG80211=y"
    "CONFIG_MAC80211=y"
)

# --- 1. Подготовка локальной среды (клонирование и проверка .config) ---
echo "--- 1. Подготовка: Клонирование репозитория и проверка .config ---"

# Клонирование, если репозиторий еще не существует
if [ ! -d "$KERNEL_DIR" ]; then
    echo "Клонирование репозитория $KERNEL_GIT_URL..."
    git clone --depth 1 --branch $KERNEL_BRANCH $KERNEL_GIT_URL $KERNEL_DIR || exit 1
else
    echo "Репозиторий уже существует. Обновление..."
    cd $KERNEL_DIR && git pull origin $KERNEL_BRANCH || exit 1
fi

# Проверка и копирование .config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Ошибка: Файл .config не найден в $SCRIPT_DIR."
    echo "Пожалуйста, скопируйте ваш .config файл в корневой каталог сборки."
    exit 1
fi

# Создание директории для артефактов
mkdir -p "$OUTPUT_DIR"

# --- 2. Сборка Docker-образа ---
echo "--- 2. Сборка Docker-образа '$DOCKER_IMAGE_NAME' ---"
docker build -t "$DOCKER_IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" || exit 1

# --- 3. Запуск контейнера для сборки ---
echo "--- 3. Запуск сборки ядра внутри контейнера ---"

# Копирование .config в папку ядра
cp "$CONFIG_FILE" "$KERNEL_DIR/.config"

# Объединяем команды в один скрипт для Docker
DOCKER_BUILD_SCRIPT=$(cat <<EOF
#!/bin/bash
set -e

# Установка требуемых параметров в .config
echo "--> Проверка и корректировка .config внутри контейнера..."
cd /usr/src/linux
CONFIG_PATH="/usr/src/linux/.config"

set_config() {
    local full_setting="\$1"
    local key=\$(echo "\$full_setting" | cut -d'=' -f1)
    
    if grep -q "^# \$key is not set" "\$CONFIG_PATH"; then
        sed -i "/^# \$key is not set/d" "\$CONFIG_PATH"
        echo "\$full_setting" >> "\$CONFIG_PATH"
    elif grep -q "^\$key=" "\$CONFIG_PATH"; then
        sed -i "s/^\$key=.*/\$full_setting/" "\$CONFIG_PATH"
    else
        echo "\$full_setting" >> "\$CONFIG_PATH"
    fi
}

# Применение конфигурации (IOSM и WPA3)
REQUIRED_CONFIGS=(
    "CONFIG_IOSM=m"
    "CONFIG_MAC80211_SAE=y"
    "CONFIG_CFG80211=y"
    "CONFIG_MAC80211=y"
)
for setting in "\${REQUIRED_CONFIGS[@]}"; do
    set_config "\$setting"
done

# Определение числа потоков
NPROCS=\$(nproc)
echo "--> Начинаем сборку с использованием \$NPROCS потоков."

# 3.1. Прямая сборка ядра и DTB
make Image dtbs -j\$NPROCS

# 3.2. Сборка модулей
make modules -j\$NPROCS

# --- 4. Установка модулей и упаковка ---
MODULES_STAGING_DIR="/tmp/rpi5_modules_staging"
mkdir -p \$MODULES_STAGING_DIR

# Установка модулей во временный каталог
make modules_install INSTALL_MOD_PATH=\$MODULES_STAGING_DIR

# Перемещение ядра, DTB и создание tar-архива модулей
echo "--> Копирование артефактов в /tmp/output..."
mkdir -p /tmp/output
cp arch/arm64/boot/Image /tmp/output/kernel_2712.img
cp arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dtb /tmp/output/bcm2712-rpi-5-b.dtb

# Создание tar-архива модулей
cd \$MODULES_STAGING_DIR/..
tar -czvf /tmp/output/${MODULES_ARCHIVE} lib/

echo "СБОРКА УСПЕШНО ЗАВЕРШЕНА В КОНТЕЙНЕРЕ!"
EOF
)

# Запуск контейнера с монтированием исходников
docker run --rm \
    --name "$CONTAINER_NAME" \
    -v "$KERNEL_DIR:/usr/src/linux" \
    -v "$OUTPUT_DIR:/tmp/output" \
    "$DOCKER_IMAGE_NAME" \
    bash -c "$DOCKER_BUILD_SCRIPT"

BUILD_STATUS=$?

# --- 4. Проверка и завершение ---
if [ $BUILD_STATUS -eq 0 ]; then
    echo "--- УСПЕХ: Файлы сборки доступны ---"
    echo "Ядро и модули сохранены в локальной папке $OUTPUT_DIR/"
    echo "1. kernel_2712.img"
    echo "2. bcm2712-rpi-5-b.dtb"
    echo "3. modules_rpi5.tar.gz"
    echo "Теперь вы можете загрузить эти файлы на SD-карту."
else
    echo "!!! КРИТИЧЕСКАЯ ОШИБКА СБОРКИ. Код ошибки: $BUILD_STATUS !!!"
    echo "Проверьте вывод Docker на предмет ошибок компиляции."
fi
