# DeepSeek Harness 一键安装器（GUI）

面向 Windows 的DSH安装脚本:
自动检查运行环境 → 自动补齐缺失环境 →
选择安装目录 → 克隆并构建 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) →
生成启动脚本和带图标的桌面快捷方式。

只依赖 Windows 自带的 Windows PowerShell 5.1 与 .NET Framework，**不需要预装任何运行库或模块**。

---

## 使用方式

### 方式一：单文件 exe（急速使用）

**`DSH安装器.exe`** —— 0.9 MB，图标、脚本、管理员清单全部内置，拷到任何 Win7 SP1+ 机器上双击即可：

```
DSH安装器.exe            # 双击运行，自动请求管理员权限（UAC）
DSH安装器.exe -SelfTest  # 不弹窗口，只做自检并打印结果
```

运行时会把内置脚本释放到 `%LOCALAPPDATA%\DeepSeekHarnessInstaller\`（固定目录，内容一致时不重写），
再用隐藏窗口的 PowerShell 拉起图形向导。首次运行需要能访问网络（克隆源码、装依赖）。

### 方式二：脚本版（便于查看和修改）

| 文件 | 说明 |
| --- | --- |
| `一键安装DSH.bat` | 双击启动（自动请求管理员权限） |
| `DSHInstaller.ps1` | 主程序，纯文本，可直接编辑 |
| `deepseek.ico` | 默认快捷方式图标 |

> 脚本版和 exe 版跑的是同一份 `DSHInstaller.ps1`，行为完全一致。改完脚本后重新执行
> `build\build-exe.ps1` 即可让 exe 用上新版本。

---

## 运行逻辑

### 1 · 环境检测

在**全新的 PowerShell 进程**里检测 5 项环境，并从注册表重新读取 `PATH`
（这一步很关键：刚安装完的程序，在当前进程里是看不到的，必须重开进程才会刷新环境变量）：

| 检查项 | 要求 |
| --- | --- |
| Chocolatey | 缺失时优先自动安装（后续用它装别的软件） |
| Git | 用于 `git clone` |
| Node.js | `22.19+` 或 `24+` |
| npm | 随 Node.js 提供 |
| pnpm | 缺失时用 `npm i -g pnpm` 安装 |

- 状态标签：**已安装** / **缺失** / **需升级** / **处理中**
- 点“一键修复环境”会自动按顺序安装缺失项：优先 Chocolatey，再用 choco 安装 Git、Node.js LTS，
  最后用 npm 安装 pnpm。**每一步都是新开的 PowerShell 进程**，保证环境变量是最新的。
- 全部通过后“下一步”才会亮起。

### 2 · 安装位置

- 默认选**剩余空间大于8GB的非系统盘**（如 `D:\DSH`），可手动输入或点“浏览…”用系统文件夹选择器。
- 会自动提示剩余空间、路径是否含中文、目标目录是否已存在仓库。
- 可勾选：创建桌面快捷方式 / 安装完成后立即启动 DSH Web。
- 可**导入自定义图标**（`.ico` / `.png` / `.jpg` / `.bmp`，图片会自动转成 256×256 的 `.ico`），
  也可以点“恢复默认”用自带的 `deepseek.ico`。

### 3 · 执行安装

按官方 README 的源码运行方式依次执行，每步都是新进程 + 实时日志：

```
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
```


注:程序会按仓库 `package.json` 里的 `packageManager` 字段**对齐 pnpm 版本**（如 `pnpm@11.7.0`）。(这可能会导致pnpm版本回退，如果有更高版本要求请手动回滚原版本)

### 4 · 完成

安装成功后会在安装目录生成：

```
D:\DSH\
├─ deepseek-harness\        # 源码与依赖
├─ 启动DSH-Web.bat          # 启动脚本
├─ dsh.ico                  # 快捷方式用的图标
└─ install.log              # 本次安装日志
```

`启动DSH-Web.bat` 内容就是固定的三条命令：

```bat
cd /d 安装盘
cd /d 安装路径
call pnpm dsh web
```

同时在桌面生成 **DeepSeek Harness Web.lnk**，已指向该 `.bat` 并设置了图标。
页面上还可以“打开目录 / 重建快捷方式 / **购买鱼粮** / 启动 DSH Web / 完成”。

> **购买鱼粮**：安装成功后显示的琥珀色按钮，点击用默认浏览器打开
> <https://platform.deepseek.com/usage>（DeepSeek 开放平台的用量 / 充值页面）。
> 安装失败时该按钮不显示。若系统没有可用的浏览器关联，会弹窗提示手动访问该地址。

Web UI 默认地址：<http://127.0.0.1:3080>

---

## 自己重新打包 exe

`build\` 目录里是打包用的源码，只用系统自带的 C# 编译器（`%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`），
**不需要装 SDK、不需要联网**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-exe.ps1
# 需要“不强制提权”的版本（由脚本自己按需提权，已是管理员时不会弹 UAC）：
powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-exe.ps1 -AsInvoker
```

| 文件 | 作用 |
| --- | --- |
| `build\Launcher.cs` | exe 主体：释放内置脚本、拉起隐藏窗口的 PowerShell、转发命令行参数 |
| `build\build-exe.ps1` | 生成 `app.manifest` 并调用 csc 编译、校验产物 |
| `build\app.manifest` | 编译时自动生成（申请管理员权限、声明兼容 Win7~Win11） |

编译脚本会自动检查 `DSHInstaller.ps1` 的 UTF-8 BOM（缺了就补上，否则 PS 5.1 按 ANSI 读会导致中文乱码），
并在打包后校验清单和两个嵌入资源是否真的写进了 exe。

---

## 常见问题
**Q:下载速度极慢怎么办?**
本脚本并没有配置镜像源,全部下载都是从海外服务器拉取的,需要魔法上网
**Q:exe 会被杀毒软件误报吗？**
打包出来的 exe 未做代码签名，而“释放脚本 + 调 PowerShell”这个行为本身容易被启发式规则盯上。
它是本地用系统自带编译器直出的，不含任何混淆或网络下载行为，一般不会报；如果被拦，把 exe 加白或直接用
`一键安装DSH.bat` + `DSHInstaller.ps1` 的脚本版即可（功能完全一样）。介意的话可以自己用
`build-exe.ps1` 重新编译一份。

**Q:必须用管理员身份吗？**
装 Chocolatey 和用 choco 装软件都需要管理员权限，所以 exe 默认在清单里申请提权（双击即弹 UAC）。
如果环境本来就齐全、想免 UAC，用 `-AsInvoker` 重新打包，或直接用脚本版——脚本版会先以普通权限打开界面，
只有在点“一键修复环境”时才需要提权，没提权时该按钮会给出提示。

**Q:exe 会把文件写到哪？**
只写两处：安装目录（你选的，默认 `D:\DSH`）、桌面快捷方式；另外把内置脚本释放到
`%LOCALAPPDATA%\DeepSeekHarnessInstaller\`。不写系统 PATH，不动注册表（除了长路径支持项）。

**Q:安装到一半失败了怎么办？**
窗口会切到失败页并给出原因和日志路径。排查后点“返回重试”，已克隆的代码和已下载的依赖会复用
（第 1 步的“准备安装目录”会检测到已存在的仓库并执行 `git pull` 更新）。

**Q:想换目录 / 换图标？**
重新运行安装器，在第 2 步改即可。移动安装目录后，请重新运行一次安装器来重新生成 `.bat` 和快捷方式
（`.bat` 里写的是绝对路径）。

**Q:不想要了怎么卸载？**
删掉安装目录（如 `D:\DSH`）、桌面快捷方式和 `%LOCALAPPDATA%\DeepSeekHarnessInstaller\` 即可；
安装器不在系统里留下其它东西（只额外设置了 `LongPathsEnabled` 注册表项，如需还原可改回 0）。

**Q:命令行下能自检吗？**
可以，不弹窗口，只检查语法 / XAML / 环境 / 产物：

```powershell
.\DSH安装器.exe -SelfTest
# 或
powershell -NoProfile -ExecutionPolicy Bypass -File .\DSHInstaller.ps1 -SelfTest
```

---

## 目录结构说明

```
DSHinstaller\
├─ DSH安装器.exe           # 单文件成品
├─ 一键安装DSH.bat         # 脚本版启动器
├─ DSHInstaller.ps1        # 主程序
├─ deepseek.ico            # 图标
├─ README.md
└─ build\                  # 打包 exe 用的源码
   ├─ Launcher.cs
   └─ build-exe.ps1
```

mamajunya
QQ群(问题反馈):1093254086(想聊天也可以的喵)

