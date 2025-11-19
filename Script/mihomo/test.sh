#!/bin/bash

# ---------------------------------
# script : mihomo 一键安装脚本
# desc   : 安装 & 配置
# date   : 2025-11-19 19:33:15
# author : ChatGPT
# ---------------------------------

# 终止脚本执行遇到错误时退出, 并启用管道错误检测
set -e -o pipefail

# 颜色变量
red="\033[31m"    # 红色
green="\033[32m"  # 绿色
yellow="\033[33m" # 黄色
blue="\033[34m"   # 蓝色
cyan="\033[36m"   # 青色
reset="\033[0m"   # 重置

# 全局变量
sh_ver="1.0.5"
use_cdn=false
arch_raw=""       # 架构

