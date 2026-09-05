# HomeServer

Это гайд, который я написал в процессе превращения моего старого полу-мёртвого ноутбука Huawei MateBook 13 (2021) в домашний сервер.

Ноутбук-сервер будет сидеть и управляться по локальной сети.

## Установка и подготовка Ubuntu Server 24.04 LTS
Для первого этапа ставим минимальную серверную OC без графического интерфейса - **Ubuntu Server 24.04 LTS**

[Официальный образ](https://ubuntu.com/download/server)

[Официальная инструкция по установке](https://documentation.ubuntu.com/server/tutorial/basic-installation/)

### 0. Обновление пакетов

Самая базовая вещь после установки свежей оси.

```bash
sudo apt update && sudo apt upgrade -y
```

### 1. Включение удалённого управления по SSH

Так как ноутбук планируется использовать, как сервер, то лучше всего сделать так, чтобы к нему не нужно было прикасаться вообще.

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

Разрешаем SSH в локальной сети:

```bash
sudo ufw allow OpenSSH
sudo ufw enable
```

### 2. Подключаемся по SSH

Далее узнаем свое имя пользователя и адрес проводной сети на ноутбуке:

```bash
whoami
ip -br -4 addr
```

И подключаемся с другого ноутбука:

```bash
ssh <login>@192.168.1.xxx
```

### 3. Отключаем сон при закрытой крышке

Открываем файл:

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
sudo nano /etc/systemd/logind.conf.d/90-server-lid.conf
```

И вписываем в него:

```ini
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
```

Аналогично запретим системе засыпать, даже если графическая оболочка попробует это сделать:

```bash
sudo mkdir -p /etc/systemd/sleep.conf.d
sudo nano /etc/systemd/sleep.conf.d/90-server.conf
```

```ini
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
```

Также отключаем засыпание от бездействия:

```bash
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
gsettings set org.gnome.desktop.session idle-delay 300
```

Отключаем wifi системе:

```bash
sudo nmcli radio wifi off
```

Перезапускаем систему:

```bash
sudo reboot
```


## Установка Docker

Удаление конфликтующих пакетов:
```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y "$pkg"; done
```

Установка необходимых компонентов:
```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

Добавление официального репозитория Docker:
```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

Установка Docker и Docker Compose:
```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Разрешение пользователю управлять Docker без суперправ:
```bash
sudo usermod -aG docker "$USER"
```

После чего нужно перезайти в ssh сессию, чтобы новая группа применилась.

## Создание хранилища

Samba - это сетевая папка, чтобы использовать сервер как облако и перекидывать файлы между устройствами.

### Подготовка локального хранилища

Нужно создать структуру папок, в которой будут хранится файлы:

```bash
sudo mkdir -p /srv/homeserver/appdata
sudo mkdir -p /srv/homeserver/storage/media/movies
sudo mkdir -p /srv/homeserver/storage/media/series
sudo mkdir -p /srv/homeserver/storage/media/anime
sudo mkdir -p /srv/homeserver/storage/downloads/complete
sudo mkdir -p /srv/homeserver/storage/downloads/incomplete
sudo mkdir -p /srv/homeserver/storage/shared/files
sudo mkdir -p /srv/homeserver/storage/shared/photos
sudo mkdir -p /srv/homeserver/storage/backups
```

Выдаём права пользователю:
```bash
sudo chown -R "$USER:$USER" /srv/homeserver
sudo chmod -R u+rwX,g+rwX /srv/homeserver
```

### Установка Samba

Устанавливаем Samba:

```bash
sudo apt install -y samba
```

Добавляем сетевую папку:

```bash
sudo nano /etc/samba/smb.conf
```

В конец файла вставляем:

```ini
[storage]
   comment = <NAME>
   path = /srv/homeserver/storage
   browseable = yes
   read only = no
   valid users = <USERNAME>
   force user = <USERNAME>
   create mask = 0660
   directory mask = 0770
```

где ``<USERNAME>`` меняем на логин пользователя.

Создаём отдельный пароль для доступа к сетевой папке:

```bash
sudo smbpasswd -a <USERNAME>
sudo smbpasswd -e <USERNAME>
```

Проверка и запуск сервиса:
```bash
sudo testparm
sudo systemctl enable --now smbd
sudo systemctl restart smbd
```

Разрешите доступ к Samba только из домашней сети:
```bash
sudo ufw allow from 192.168.1.0/24 to any port 445 proto tcp
```

### Подключение к Samba

С других устройств подключаться к Samba можно через встроенные функции проводника. Например, на Windows 11 вставьте в адресную строку:

```\\192.168.1.xxx\storage```

и введите логин, пароль.

Теперь сервер виден в сети как полноценный сетевой диск.

## Jellyfin - просмотр контента

Создаем папку Docker-конфигурации:

```bash
mkdir -p ~/home-server
cd ~/home-server
```

Создаём файл переменных:

```bash
nano .env
```

```ini
PUID=1000
PGID=1000
TZ=Europe/Moscow
```

Создаём Docker Compose-конфигурацию:

```bash
nano compose.yaml
```

```yaml
services:
  jellyfin:
    image: ghcr.io/jellyfin/jellyfin:latest
    container_name: jellyfin
    user: "${PUID}:${PGID}"
    environment:
      TZ: "${TZ}"
    volumes:
      - /srv/homeserver/appdata/jellyfin/config:/config
      - /srv/homeserver/appdata/jellyfin/cache:/cache
      - /srv/homeserver/storage/media:/media:ro
    ports:
      - "8096:8096"
    restart: unless-stopped
```

Разрешаем Jellyfin в домашней сети и запускаем его:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8096 proto tcp
docker compose pull
docker compose up -d
```

Открываем в браузере ``http://192.168.1.145:8096`` и выполняем мастер-установку.
После установки в Jellyfin создаем Каталоги согласно созданным медиа-папкам. Например Movies -> /media/movies и тд.