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

## 快速开始

```powershell
# 安装
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 重新打开终端后
proxy init

# 配置 sing-box（指向你已有的配置文件）
proxy singbox config "C:\path\to\sing-box.exe" "C:\path\to\config.json"

# 配置代理端口（与 sing-box 的入站端口一致）
proxy config set socks5 127.0.0.1 7890

# 测试连接
proxy test

# 启动全部服务
proxy start

# 验证 WinDivert 透明代理
curl https://httpbin.org/ip   # 应返回代理 IP
```

## 按应用透明代理

```powershell
proxy add curl.exe         # 添加 curl
proxy add git.exe          # 添加 git
proxy add chrome.exe       # 添加 Chrome
proxy add node.exe         # 添加 node
proxy on git.exe           # 启用代理
proxy off git.exe          # 禁用代理
proxy rm git.exe           # 删除应用
proxy ls                   # 列出所有应用
```

启动 `proxy start` 后，ProxyBridge 通过 WinDivert 内核驱动拦截已添加应用的所有网络连接，透明转发到 sing-box。应用本身无需任何配置。

```powershell
proxy start                # 启动服务（自动加载代理规则）
curl https://www.google.com # 直接 curl 即走代理
git pull                    # 直接 git 即走代理
```

## 命令代理

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

## 浏览器代理

Chrome/Edge 等浏览器不支持 `ALL_PROXY` 环境变量，需要特殊处理：

### 方法 1：系统代理（推荐）

```powershell
proxy system          # 设置系统代理（Chrome/Edge 自动走代理）
proxy system off      # 关闭系统代理
```

设置后，Chrome/Edge 等浏览器会自动使用系统代理设置。

### 方法 2：Chrome 独立启动

```powershell
proxy chrome           # 启动 Chrome 走代理（独立 profile）
```

会创建一个独立的 Chrome profile（`~\.proxy\chrome-proxy-profile`），与你的主 Chrome 完全隔离。每次使用 `proxy chrome` 启动即可。

### 方法 3：手动启动 Chrome

```powershell
chrome.exe --proxy-server="socks5://127.0.0.1:7890" --user-data-dir="C:\temp\chrome-proxy"
```

### 方法 4：Chrome 扩展

安装 [FoxyProxy](https://chrome.google.com/webstore/detail/foxyproxy-premium/ljfdkafmojknkokmokjnjajkogmpkiel) 或 [SwitchyOmega](https://chrome.google.com/webstore/detail/switchyomega/padekgcemlokbadohgkifiiomjicklek)，配置 SOCKS5 代理 `127.0.0.1:7890`。

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
