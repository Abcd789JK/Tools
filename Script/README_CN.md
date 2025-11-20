# Linux 系统安装 mihomo 教程

> 温馨提示：
>
> 1.认真看教程，认真看教程，认真看教程，重要事情说三次！
>
> 2.本脚本支持 Arch Alpine Debian Fedora Ubuntu 系统
>
> 3.本脚本优先支持 Debian Ubuntu 系统
>
> 4.本脚本默认支持 tun 模式, 你可以在脚本里面选择 TProxy 模式

## 开启 TUN 模式 {注意：好像需要直通（PVE 虚拟机下操作）}

### 1.PVE 8.X 开启 tun

### 2.在 PVE 虚拟机创建 LXC 容器，创建完成以后不要 启动虚拟机

### 3.选择刚刚创建的 LXC 容器，鼠标依次点击，资源 - 添加 - 直通设备（Device Passthrough） 如下图

![image](https://github.com/user-attachments/assets/f185b446-cc76-4337-817b-0139f688445f)

### 4.在里面填入下面代码 效果如下

```bash
/dev/net/tun
```

![image](https://github.com/user-attachments/assets/7ad8bb51-d593-439a-9fdf-2649d3f44e82)

### 5.如果你是 PVE 7.X 开启 TUN ，如下操作

#### 5.1.在 PVE 里面，依次 节点 - Shell 里面执行，如下图位置

![image](https://github.com/user-attachments/assets/ba043dca-b12b-4b92-963c-4f809305ec11)

#### 5.2.下面的 LXCID 修改成你的实际 ID (比如，我是 100 就改成 nano /etc/pve/lxc/100.conf)

```bash
nano /etc/pve/lxc/LXCID.conf
```

#### 5.3.粘贴下面代码，然后用 Ctrl+X 保存，输入 Y 确认

```bash
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

## 开启 TProxy 模式 不需要其他额外操作，下面步骤都一样

---

## Debian 系统操作流程

### 1.换源 debian 12 (清华源)

```bash
cat << EOF > /etc/apt/sources.list
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
```

### debian 13 (清华源)

```bash
cat << EOF > /etc/apt/sources.list
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware
EOF
```

### 2.更新系统

```bash
apt update && apt full-upgrade -y
```

### 3.安装必须插件

```bash
apt install -y curl git wget nano
```

### 4.因为 PVE 虚拟机容器，默认是没有开启远程 root 登录，如需开启使用下面命令

```bash
apt install -y openssh-server && \
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
systemctl enable ssh && \
systemctl restart ssh
```

---

## Ubuntu 系统操作流程

### 1.换源 (清华源)

```bash
cat << EOF > /etc/apt/sources.list
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ oracular main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ oracular-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ oracular-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ oracular-security main restricted universe multiverse
EOF
```

### 2.更新系统

```bash
apt update && apt full-upgrade -y
```

### 3.安装必须插件

```bash
apt install -y curl git wget nano
```

### 4.因为 PVE 虚拟机容器，默认是没有开启远程 root 登录，如需开启使用下面命令

```bash
apt install -y openssh-server && \
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
systemctl enable ssh && \
systemctl restart ssh
```

---

## Fedora 系统操作流程

### 1.换源 (清华源)

```bash
sed -e 's|^metalink=|#metalink=|g' \
    -e 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl=https://mirrors.tuna.tsinghua.edu.cn/fedora|g' \
    -i.bak \
    /etc/yum.repos.d/fedora.repo \
    /etc/yum.repos.d/fedora-updates.repo
```

### 2.更新系统

```bash
dnf upgrade --refresh -y
```

### 3.安装必须插件

```bash
dnf install -y curl git wget nano bash
```

### 4.因为 PVE 虚拟机容器，默认是没有开启远程 root 登录，如需开启使用下面命令

```bash
dnf install -y openssh-server && \
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
systemctl enable sshd && \
systemctl restart sshd
```

---

## Alpine 系统操作流程

### 1.换源 (清华源)

```bash
sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories
```

### 2.更新系统

```bash
apk update && apk upgrade
```

### 3.安装必须插件

```bash
apk add curl git wget nano bash
```

### 4.因为 PVE 虚拟机容器，默认是没有开启远程 root 登录，如需开启使用下面命令

```bash
apk add --no-cache openssh && \
mkdir -p /etc/ssh && ssh-keygen -A && \
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
rc-update add sshd && \
rc-service sshd restart
```

---

## Arch 系统操作流程

### 1.换源 (清华源 二选一)

```bash
pacman -S --noconfirm reflector && reflector --country China --age 6 --protocol https --sort rate --save /etc/pacman.d/mirrorlist && pacman -Syyu
```

```bash
echo "Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.bfsu.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch
Server = https://mirrors.zju.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.sjtug.sjtu.edu.cn/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist && pacman -Syyu
```

### 2.更新系统

```bash
pacman -Syu --noconfirm
```

### 3.安装必须插件

```bash
pacman -S --noconfirm curl git wget nano bash
```

### 4.因为 PVE 虚拟机容器，默认是没有开启远程 root 登录，如需开启使用下面命令

```bash
pacman -Sy --noconfirm openssh && \
ssh-keygen -A && \
sed -i 's/^#\?Port 22.*/Port 22/' /etc/ssh/sshd_config && \
sed -i 's/^#\?AddressFamily any.*/AddressFamily any/' /etc/ssh/sshd_config && \
sed -i 's/^#\?ListenAddress 0.0.0.0.*/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config && \
sed -i 's/^#\?ListenAddress ::.*/ListenAddress ::/' /etc/ssh/sshd_config && \
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
systemctl enable --now sshd && \
systemctl restart sshd
```

### 5.如何出现 PGP 密钥验证错误(先试试第一组，不行在试试第二组)

```bash
# 第一组
pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm
```

```bash
# 第二组
pacman-key --refresh-keys
pacman -Syu --noconfirm
```

---

### 前期工作准备完毕，下面使用一键脚本安装 mihomo

#### 已经加入自动识别网络环境功能，确保你的设备能正常联网就行

```bash
wget -O install.sh https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/mihomo/install.sh && chmod +x install.sh && ./install.sh
```

#### CND 加速版，主要是下载脚本用的，脚本里面的功能和上面一样（有时候 CND 会失效，等待修复就好）

```bash
wget -O install.sh https://github.boki.moe/https://raw.githubusercontent.com/Abcd789JK/Tools/refs/heads/main/Script/mihomo/install.sh && chmod +x install.sh && ./install.sh
```

## 手动检查、排错

### 使用以下命令，检查 mihomo 的运行状况

```bash
# Debian Ubuntu Fedora 系统
systemctl status mihomo

# Alpine 系统
rc-service mihomo status
```

### 使用以下命令，检查 mihomo 的运行日志

```bash
# Debian Ubuntu Fedora 系统
journalctl -u mihomo -o cat -e
```

## Linux 系统设置上海时区

### 支持 Debian Ubuntu 系统

```bash
# 二选一
ln -sf /usr/share/zoneinfo/Asia/Hong_Kong /etc/localtime
echo "Asia/Hong_Kong" > /etc/timezone

cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" | tee /etc/timezone > /dev/null
```

### 支持 alpine 系统

```bash
apk add --no-cache tzdata && \
ln -sf /usr/share/zoneinfo/Asia/Hong_Kong /etc/localtime && \
echo "Asia/Hong_Kong" > /etc/timezone

```
