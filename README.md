# dsh-updater

DSH 插件：设置面板里的「更新」页。

一键检查 npm 上的最新 `@deepseek-ai/dsh` 版本，并启动一个**脱离 DSH 进程树**的原地更新器，自动完成：

1. `npm install` 新版本到临时目录（此间 DSH 正常运行）
2. 组装"依赖内嵌"布局（兼容 `~/.dsh/profiles/node_modules` 的 Junction 解析链）
3. 用便携版 node 试跑新版本（不通过就放弃，不动任何文件）
4. 停止 DSH → 改名备份旧包 → 换上新包 → 再次校验（失败自动回滚）
5. 适配启动器 `controller.ps1`（dsh 0.1.5+ 的 token 认证）
6. 重新启动 DSH

更新进程通过 WMI 创建（父进程为 `WmiPrvSE`），`controller.ps1` 用 `taskkill /T` 清理 DSH 进程树时杀不到它——**会话中断不影响更新**。

## 兼容性与升级路径（重要）

插件要求 **dsh 0.1.5+**（token 认证 + 前端依赖预打包结构）。dsh 在 0.1.5 有过一次**破坏性更新**，旧版 dsh（如 0.1.1-rc.2 及更早）与插件**不兼容**，请勿直接安装：

1. **先用脚本升级 dsh**：从 [Release](https://github.com/reimu-create/dsh-updater/releases) 下载 `dsh-updater-tools-v1.0.0.zip`，解压到便携版安装目录的 `_update\` 下，双击 `Update-DSH.bat`（或 PowerShell 运行 `update-dsh.ps1`）把 dsh 升到最新版；
2. **再安装插件**：`dsh plugin --profile web add <本目录>`；
3. 之后日常更新直接在 设置 → 更新 里一键完成即可。

## 安装

```sh
dsh plugin --profile web add D:\dsh-plugins\dsh-updater
```

## 依赖

- 便携版 DeepSeekHarness 安装目录下需存在 `_update\update-dsh.ps1` 与 `_update\Fix-Launcher.ps1`（本仓库 `tools/` 提供了这两份工具，也可直接下载 Release 资产 `dsh-updater-tools-v1.0.0.zip` 解压，部署到安装目录的 `_update\` 即可）。
- 本机需有 `npm`（版本检查走 `npm view @deepseek-ai/dsh version`）。
- Windows 需有 `powershell.exe`（WMI 创建脱离进程）。

## 使用

设置 → 更新：

- 当前运行时 / npm 最新版 / 状态（有新版本可用 / 已是最新）
- `重新检查`：刷新版本信息
- `立即更新`：二次确认后启动更新器；页面随后会断开，约 1 分钟后刷新即可

## 配置

`cordis.patch.yml` 中的 `config`：

| 字段 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 关闭后插件不注册任何路由 |
| `port` | `3080` | DSH 监听端口，传给更新器做精确杀进程 |

## 同源路由

浏览器不接触任何密钥：

- `GET /api/dsh-updater/status` → 版本与更新状态
- `POST /api/dsh-updater/run` → 启动脱离进程的更新器

## 发布

```sh
npm pack
gh release create v1.0.0 ./dsh-updater-1.0.0.tgz --title "dsh-updater v1.0.0" --notes "说明"
```
