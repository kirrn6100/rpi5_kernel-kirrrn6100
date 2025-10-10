#!/bin/bash

# --- Настройки репозитория ---
KERNEL_GIT_URL="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-6.12.y" # Вернулись к выбранной вами ветке
# --- Настройки локальной среды ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
DOCKER_IMAGE_NAME="rpi5-kernel-builder"
CONTAINER_NAME="rpi5-kernel-build-temp"
KERNEL_DIR="$SCRIPT_DIR/raspberrypi-linux"
CONFIG_FILE="$SCRIPT_DIR/.config"
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
    # --single-branch для ускорения клонирования
    git clone --depth 1 --branch $KERNEL_BRANCH --single-branch $KERNEL_GIT_URL $KERNEL_DIR || exit 1
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
# *** ИСПРАВЛЕНО: Раскомментирована команда docker build ***
docker build -t "$DOCKER_IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR" || exit 1

# --- 3. Запуск контейнера для сборки ---
echo "--- 3. Запуск сборки DEB-пакетов внутри контейнера ---"

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
    
    # 1. Если не задан, удалить строку "is not set" и добавить новую
    if grep -q "^# \$key is not set" "\$CONFIG_PATH"; then
        sed -i "/^# \$key is not set/d" "\$CONFIG_PATH"
        echo "\$full_setting" >> "\$CONFIG_PATH"
    # 2. Если задан, заменить значение
    elif grep -q "^\$key=" "\$CONFIG_PATH"; then
        sed -i "s/^\$key=.*/\$full_setting/" "\$CONFIG_PATH"
    # 3. Если не найден (редко), добавить в конец
    else
        echo "\$full_setting" >> "\$CONFIG_PATH"
    fi
}

# Применение конфигурации (IOSM и WPA3)
for setting in "\${REQUIRED_CONFIGS[@]}"; do
    set_config "\$setting"
done

# Определение числа потоков
NPROCS=\$(nproc)
echo "--> Начинаем сборку DEB-пакетов с использованием \$NPROCS потоков."

# --- ЗАПУСК СБОРКИ DEB-ПАКЕТОВ ---
# Обновляем версию, чтобы соответствовать ветке 6.12.y
export KDEB_PKGVERSION="6.12.y-custom-rpi5-$(date +%Y%m%d%H%M)"
export DEB_BUILD_OPTIONS='nocheck nodoc'
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j\$NPROCS bindeb-pkg

# --- 4. Копирование готовых пакетов ---
echo "--> Копирование готовых DEB-пакетов в /tmp/output..."
# DEB-пакеты создаются в родительском каталоге исходников ядра
# Копируем все *.deb файлы из /usr/src/ (родительский каталог для /usr/src/linux)
cp /usr/src/*.deb /tmp/output/ || true

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

# --- 5. Проверка и завершение ---
if [ $BUILD_STATUS -eq 0 ]; then
    echo "--- УСПЕХ: Файлы сборки доступны ---"
    echo "DEB-пакеты ядра и модулей сохранены в локальной папке $OUTPUT_DIR/"
    echo "Ищите файлы с расширением *.deb"
else
    echo "!!! КРИТИЧЕСКАЯ ОШИБКА СБОРКИ. Код ошибки: $BUILD_STATUS !!!"
    echo "Проверьте вывод Docker на предмет ошибок компиляции."
fi
