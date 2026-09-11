# proxy CLI v2

像包管理器一样管理 Windows 按应用代理（sing-box + ProxyBridge）。

## 工作原理

```
应用 (curl, git, node, chrome ...)
   |
   |--- 模式 A: WinDivert 内核拦截 (按应用透明代理) ---|
   |                                                    v
   |                                           ProxyBridge_CLI.exe
   |                                                    |
   |                                           SOCKS5 转发
   |                                                    v
   |                                           sing-box.exe (127.0.0.1:7890)
   |                                                    |
   |                                                    v
   |                                           远程服务器 / 互联网
   |
   |--- 模式 B: 环境变量注入 (命令代理) ---|
              v
           proxy <command>
              |
              | 设置 ALL_PROXY/HTTP_PROXY/HTTPS_PROXY + 工具参数
              v
           sing-box.exe (127.0.0.1:7890)
              |
              v
           远程服务器 / 互联网
```

**三种代理模式：**

| 模式 | 命令 | 原理 | 适用场景 |
|------|------|------|----------|
| 按应用透明代理 | `proxy add curl` → `proxy start` | ProxyBridge + WinDivert 内核驱动拦截进程网络流量 | 所有应用（curl, git, node, 自定义程序等） |
| 命令代理 | `proxy curl https://...` | 设置 `ALL_PROXY` 环境变量 + curl `--proxy` 参数 | 命令行工具临时走代理 |
| 系统代理 | `proxy system` | 设置 Windows 系统代理注册表 | Chrome/Edge 等浏览器 |

## 安装

### 1. 安装 proxy-cli

```powershell
# 克隆仓库
git clone https://github.com/your-username/proxy-cli-windows-v2.git
cd proxy-cli-windows-v2

# 运行安装脚本（自动添加到 PATH）
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 重新打开终端后生效
```

安装后会自动将 `proxy.ps1` 复制到 `%USERPROFILE%\bin` 并加入 PATH。

### 2. 安装 sing-box

sing-box 是代理核心，负责实际的流量转发（直连、VMess、Trojan、Shadowsocks 等）。

**方式 A：手动下载（推荐）**

1. 前往 [sing-box GitHub Releases](https://github.com/SagerNet/sing-box/releases)
2. 下载 `sing-box-{version}-windows-amd64.zip`
3. 解压到一个目录，例如 `C:\sing-box\`
4. 记住 `sing-box.exe` 的完整路径和你的配置文件路径

**方式 B：使用 scoop**

```powershell
scoop install sing-box
```

**方式 C：使用 winget**

```powershell
winget install sagernet.sing-box
```

安装后需要准备一个 sing-box 配置文件。proxy CLI 不生成 sing-box 配置，你需要自己提供。

### 3. 安装 ProxyBridge

ProxyBridge 负责按应用分流，通过 WinDivert 内核驱动拦截指定进程的网络流量。

**方式 A：下载安装包（推荐）**

1. 前往 [ProxyBridge GitHub Releases](https://github.com/InterceptSuite/ProxyBridge/releases)
2. 下载 `ProxyBridge-Setup-{version}.exe`
3. 安装到默认目录（例如 `C:\Program Files\ProxyBridge\`）
4. 安装完成后记下安装目录路径

**方式 B：下载便携版**

1. 前往 [ProxyBridge GitHub Releases](https://github.com/InterceptSuite/ProxyBridge/releases)
2. 下载便携版 zip
3. 解压到任意目录（例如 `D:\ProxyBridge\`）

安装后需要确保以下文件在同一目录：
- `ProxyBridge_CLI.exe`（CLI 版本）
- `ProxyBridgeCore.dll`（核心库）
- `WinDivert.dll`（WinDivert 库）
- `WinDivert64.sys`（WinDivert 驱动）

## 配置

### 1. 初始化配置

```powershell
proxy init
```

这会创建 `%USERPROFILE%\.proxy\config.json` 默认配置文件。

### 2. 配置 sing-box

```powershell
# 告诉 proxy CLI 你的 sing-box 在哪里
proxy singbox config "C:\path\to\sing-box.exe" "C:\path\to\config.json"
```

### 3. 配置代理端口

代理端口必须与 sing-box 配置文件中入站（inbound）的端口一致：

```powershell
# 查看当前配置
proxy config show

# 设置代理端口（默认 7891，通常改为 7890 或 1080）
proxy config set socks5 127.0.0.1 7890
```

### 4. 添加应用（可选）

如果你想让某些应用自动走代理（透明代理模式）：

```powershell
proxy add curl.exe         # 添加 curl
proxy add git.exe          # 添加 git
proxy add chrome.exe       # 添加 Chrome
proxy add node.exe         # 添加 node（慎用，会影响所有 Node 程序）
```

### 5. 启动服务

```powershell
proxy start
```

这会自动按顺序启动：
1. sing-box（代理核心）
2. ProxyBridge（WinDivert 拦截）

### 6. 验证

```powershell
# 检查状态
proxy status

# 测试连接
proxy test

# 完整诊断
proxy doctor
```

## 快速开始（完整流程）

```powershell
# 1. 安装
git clone https://github.com/your-username/proxy-cli-windows-v2.git
cd proxy-cli-windows-v2
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 2. 重新打开终端后
proxy init

# 3. 配置 sing-box 路径
proxy singbox config "C:\Program Files\sing-box\sing-box.exe" "C:\Users\你\sing-box-config.json"

# 4. 配置代理端口
proxy config set socks5 127.0.0.1 7890

# 5. 添加需要代理的应用
proxy add curl.exe
proxy add git.exe

# 6. 启动服务
proxy start

# 7. 验证
proxy status
curl https://httpbin.org/ip   # 应返回代理 IP
proxy curl https://httpbin.org/ip  # 也返回代理 IP
```

## 使用

### 按应用透明代理

```powershell
proxy add curl.exe         # 添加 curl
proxy add git.exe          # 添加 git
proxy add chrome.exe       # 添加 Chrome
proxy on git.exe           # 启用代理
proxy off git.exe          # 禁用代理
proxy rm git.exe           # 删除应用
proxy ls                   # 列出所有应用
```

启动 `proxy start` 后，已添加应用的所有网络连接会自动通过 ProxyBridge + WinDivert 拦截并转发到 sing-box。应用本身无需任何配置。

```powershell
proxy start                # 启动服务
curl https://www.google.com # 直接 curl 即走代理
git pull                    # 直接 git 即走代理
```

### 命令代理

任何不在内置命令列表中的命令会自动通过代理执行：

```powershell
proxy curl https://www.google.com
proxy git pull
proxy npm install
proxy node app.js
proxy python script.py
proxy pip install -r requirements.txt
proxy run <任意命令> [args...]
```

原理：临时设置 `ALL_PROXY`、`HTTP_PROXY`、`HTTPS_PROXY` 环境变量，并为 curl/git 等工具注入代理参数（`--proxy`/`-c`），命令结束后自动恢复。

### 浏览器代理

Chrome/Edge 等浏览器不支持 `ALL_PROXY` 环境变量，需要特殊处理：

```powershell
proxy system          # 设置系统代理（Chrome/Edge 自动走代理）
proxy system off      # 关闭系统代理
```

或：

```powershell
proxy chrome           # 启动 Chrome 走代理（独立 profile）
```

或手动启动：

```powershell
chrome.exe --proxy-server="socks5://127.0.0.1:7890" --user-data-dir="C:\temp\chrome-proxy"
```

或安装 Chrome 扩展 [FoxyProxy](https://chrome.google.com/webstore/detail/foxyproxy-premium/ljfdkafmojknkokmokjnjajkogmpkiel) / [SwitchyOmega](https://chrome.google.com/webstore/detail/switchyomega/padekgcemlokbadohgkifiiomjicklek)，配置 SOCKS5 代理 `127.0.0.1:7890`。

## sing-box 管理

```powershell
proxy singbox config <exe路径> <配置文件路径>  # 配置 sing-box
proxy singbox start                  # 仅启动 sing-box
proxy singbox stop                   # 仅停止 sing-box
proxy singbox status                 # 显示 sing-box 状态
```

`proxy start` 会自动先启动 sing-box，再启动 ProxyBridge。`proxy stop` 反序关闭。

sing-box 配置文件由用户提供，proxy CLI 不生成 sing-box 配置。

## 完整命令列表

```
# 初始化
proxy init                          # 初始化配置

# 配置
proxy config show                   # 显示代理配置
proxy config set socks5 127.0.0.1 7890  # 设置代理端口

# 应用管理
proxy add <name|exe|path>           # 添加应用
proxy rm <name>                     # 删除应用
proxy ls / list                     # 列出应用
proxy on <name>                     # 启用代理
proxy off <name>                    # 禁用代理
proxy which <name>                  # 解析命令信息
proxy tree <name>                   # 显示命令调用链

# sing-box 管理
proxy singbox config <exe> <cfg>    # 配置 sing-box 路径
proxy singbox start                 # 仅启动 sing-box
proxy singbox stop                  # 仅停止 sing-box
proxy singbox status                # 显示 sing-box 状态

# 服务控制
proxy start                         # 启动 sing-box + ProxyBridge
proxy stop                          # 停止 ProxyBridge + sing-box
proxy restart                       # 重启全部
proxy status                        # 显示状态
proxy test                          # 测试代理连接
proxy doctor                        # 完整诊断

# 命令代理
proxy run <command> [args...]       # 通过代理执行任意命令
proxy curl https://example.com      # curl 走代理
proxy git pull                      # git 走代理

# 浏览器代理
proxy chrome                        # 启动 Chrome 走代理（独立 profile）
proxy system                        # 设置系统代理（Chrome/Edge 自动走代理）
proxy system off                    # 关闭系统代理

# 其他
proxy update                        # 重新生成 profile
proxy profile                       # 显示并生成 profile
proxy help                          # 显示帮助
```

## Node CLI

对于 Claude/OpenCode/npm/npx 等 Node CLI，**不要直接**：

```powershell
proxy add node.exe   # 不要这样做！
```

否则所有 Node 程序都可能被代理。

正确做法：

```powershell
proxy which claude   # 查看实际可执行文件
proxy tree claude    # 查看调用链
```

v2 会识别 `.cmd/.bat/.ps1` wrapper，拒绝自动产生 `node.exe` 全局规则。确认真实程序路径后再精确添加。

## 文件说明

```
%USERPROFILE%\.proxy\config.json           # 主配置（代理端口、应用列表、sing-box 路径）
%USERPROFILE%\.proxy\proxybridge.pbprofile # ProxyBridge 配置（由 proxy CLI 自动生成）
%USERPROFILE%\.proxy\proxybridge.pid       # ProxyBridge 进程 PID
%USERPROFILE%\.proxy\proxybridge.log       # 操作日志
%USERPROFILE%\.proxy\singbox.pid           # sing-box 进程 PID
%USERPROFILE%\.proxy\singbox.log           # sing-box 日志
```

## 颜色说明

| 颜色 | 含义 |
|------|------|
| 绿色 | 成功 / 已启用 / 运行中 |
| 红色 | 失败 / 错误 / 已停止 |
| 黄色 | 已配置但未启用 / 警告 |
| 青色 | 信息 / 状态 |

## 依赖

- Windows 10/11
- PowerShell 5.1+（需要管理员权限）
- [ProxyBridge](https://github.com/InterceptSuite/ProxyBridge) V4.0.0+ — 按应用透明代理（WinDivert 内核驱动）
- [sing-box](https://github.com/SagerNet/sing-box) — 代理核心（需用户提供配置文件）

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

卸载不会删除 `%USERPROFILE%\.proxy` 目录。如需删除全部数据：

```powershell
Remove-Item $env:USERPROFILE\.proxy -Recurse -Force
```
