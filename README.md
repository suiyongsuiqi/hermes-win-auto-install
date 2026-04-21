# Hermes Windows 自动安装器

面向 Windows 的 Hermes 一键安装仓库。

它会把 `WSL`、`Hermes`、`API Key 注入`、`微信绑定`、`gateway` 和 `WebUI` 串成一条完整流程，尽量做到直接可用，重启后也能继续跑。

## 功能

- 新建专用 Hermes WSL 环境，尽量不影响你现有的其它发行版
- 或复用已有的 Ubuntu / Debian WSL2
- Windows 侧预下载安装资源，减少重复下载
- 本地弹窗输入 API Key，不把密钥写死在脚本里
- 引导微信扫码绑定并启动 `hermes gateway run`
- 安装并打开本地 WebUI
- 支持中断恢复

## 默认线路

默认 provider 走球球 token 中转站，适合不想自己折腾上游接口的场景。

- 首页：https://qiuqiutoken.com/
- 默认模型：`gpt-5.4`
- 默认 API mode：`codex_responses`

如果你有自己的 OpenAI 兼容接口，也可以在安装界面里改成自定义线路。

## 快速开始

直接双击：

```bat
开始安装.bat
```

或者：

```bat
start-install.bat
```

命令行方式：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows-install-hermes.ps1
```

安装过程中只需要按提示完成几件事：

1. 选择安装方式
2. 选择默认 provider 或自定义接口
3. 输入 API Key
4. 手机微信扫码绑定
5. 安装完成后发一条测试消息

## 安装器会自动完成什么

- 检查 PowerShell 和管理员权限
- 预下载 Ubuntu / Hermes / Node.js / WebUI 资源
- 新建或复用目标 WSL 环境
- 安装 Hermes 并执行基础验证
- 引导微信绑定并启动 gateway
- 安装并打开 `http://localhost:8788`

## 可选配置

如果你想提前覆盖默认值，可以在仓库根目录放一个 `install.env`。

示例：

```env
WSL_DISTRO_NAME=Hermes-Ubuntu-24.04
WSL_USERNAME=hermes
LLM_BASE_URL=https://api.example.com/v1
LLM_MODEL=gpt-5.4
LLM_API_MODE=chat_completions
UBUNTU_APT_PRIMARY_URL=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
UBUNTU_APT_SECURITY_URL=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
NODE_DIST_MIRROR_URL=https://npmmirror.com/mirrors/node
NPM_REGISTRY_URL=https://registry.npmmirror.com
```

支持的主要项：

- `WSL_DISTRO_NAME`
- `WSL_USERNAME`
- `LLM_BASE_URL`
- `LLM_MODEL`
- `LLM_API_MODE`
- `UBUNTU_APT_PRIMARY_URL`
- `UBUNTU_APT_SECURITY_URL`
- `NODE_DIST_MIRROR_URL`
- `NPM_REGISTRY_URL`

说明：

- `LLM_API_KEY` 不会从 `install.env` 读取
- `WSL_PASSWORD` 不会从 `install.env` 读取
- API Key 会在安装流程里通过本地弹窗单独输入

## 常用命令

重新打开 WebUI：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows-webui.ps1 -Action Open
```

启动或检查 WebUI：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows-webui.ps1 -Action Start
powershell -ExecutionPolicy Bypass -File .\scripts\windows-webui.ps1 -Action Status
```

重新拉起 gateway：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows-start-gateway.ps1
```

中途失败后继续安装：

```bat
开始安装.bat
```

## 目录

- [scripts](./scripts)：安装主流程脚本
- `downloads/`：Windows 侧资源缓存
- `install-log-*.log`：安装日志
- `%LOCALAPPDATA%\HermesBootstrap\state.json`：安装状态
- `%LOCALAPPDATA%\HermesBootstrap\webui\`：WebUI 文件

## 注意

- 专用发行版模式更适合小白，隔离性更好
- 复用现有发行版前，建议先自行备份重要数据
- WebUI 默认运行在 `localhost:8788`

## License

见 [LICENSE](./LICENSE)。
