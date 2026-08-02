# TongYi-Lite Flutter 构建 Makefile (Git Bash / MINGW64)
# 用法: make [target]

ADB      := C:/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe
FLUTTER  := C:/dev-tools/flutter/bin/flutter.bat
KEY_SRC  ?= C:/Users/jianz/Documents/xwechat_files/love2bloved_ac69/msg/file/2026-08/key.properties
KEY_DST  := android/key.properties
APP_ID   := com.dgxspark.tongyilite
APK_DIR  := build/app/outputs/flutter-apk

DEVICE   := $(shell $(ADB) devices 2>/dev/null | grep -v "List" | grep "device" | head -1 | awk '{print $$1}')

.PHONY: all build install open-dir clean help

# 一键打包：复制key → 清除旧版 → 构建 → 安装 → 打开文件夹
all: install
	@start "" explorer "$(CURDIR)/$(APK_DIR)"

build:
	@"$(FLUTTER)" build apk --debug

install: build
	@if [ -z "$(DEVICE)" ]; then echo "❌ No device found"; exit 1; fi
	@echo "📱 Device: $(DEVICE)"
	@$(ADB) -s $(DEVICE) uninstall $(APP_ID) 2>/dev/null || true
	@cp -f "$(KEY_SRC)" "$(KEY_DST)" && echo "✅ key.properties deployed"
	@$(ADB) -s $(DEVICE) install -r "$(APK_DIR)/app-debug.apk"

open-dir:
	@start "" explorer "$(CURDIR)/$(APK_DIR)"

clean:
	@"$(FLUTTER)" clean

help:
	@echo "可用命令:"
	@echo "  make        - 一键打包（清除→构建→安装→打开文件夹）"
	@echo "  make build  - 仅构建 Debug APK"
	@echo "  make install- key → 构建 → 安装到设备"
	@echo "  make open-dir   - 打开 APK 输出目录"
	@echo "  make clean    - 清理构建产物"
	@echo ""
	@echo "环境变量:"
	@echo "  TONGYI_KEY_PATH=<路径>  指定 key.properties 源路径"
