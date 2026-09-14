/**
 * DSH 更新器 — Host 半（标准 ESM bundle）
 *
 * 提供两个同源路由（浏览器不接触任何密钥）：
 *   GET  /api/dsh-updater/status  → 当前运行时版本 / npm 最新版 / 是否有更新
 *   POST /api/dsh-updater/run     → 通过 WMI 创建脱离 DSH 进程树的更新进程
 *
 * 关键设计：controller.ps1 清理时会执行 taskkill /PID <3080> /T /F，
 * 按进程树连坐杀子进程。因此更新器不能由本进程直接 spawn——用
 * Invoke-CimMethod Win32_Process Create 创建，父进程变成 WmiPrvSE，
 * DSH 被杀时更新照常进行。
 */
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'

export const name = 'dsh-updater'
export const inject = ['webServer']

const NPM_PACKAGE = '@deepseek-ai/dsh'
const FALLBACK_ROOT = 'C:\\Users\\86191\\Desktop\\DeepSeekHarness'

const DEFAULT_CONFIG = {
  enabled: true,
  port: 3080,
}

function sendJson(res, code, payload) {
  try {
    res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' })
    res.end(JSON.stringify(payload))
  } catch {
    /* 写响应失败静默 */
  }
}

// controller.ps1 固定以 dsh 包目录为工作目录启动：
//   <root>\runtime\node_modules\@deepseek-ai\dsh
// 上溯三级即安装根；探测失败回退到配置或默认路径。
function detectInstallRoot(cfg) {
  try {
    const candidate = resolve(process.cwd(), '..', '..', '..')
    if (existsSync(join(candidate, 'controller.ps1'))) return candidate
  } catch {
    /* 回退 */
  }
  return typeof cfg.installRoot === 'string' && cfg.installRoot
    ? cfg.installRoot
    : FALLBACK_ROOT
}

async function readInstalledVersion(root) {
  try {
    const text = await readFile(
      join(root, 'runtime', 'node_modules', '@deepseek-ai', 'dsh', 'package.json'),
      'utf8',
    )
    const found = /"version"\s*:\s*"([^"]+)"/.exec(text)
    if (!found) return { version: null, error: 'package.json 缺少 version 字段' }
    return { version: found[1], error: null }
  } catch (error) {
    return { version: null, error: String((error && error.message) || error) }
  }
}

function readLatestVersion() {
  return new Promise((resolvePromise) => {
    execFile('npm.cmd', ['view', NPM_PACKAGE, 'version'], {
      cwd: FALLBACK_ROOT,
      windowsHide: true,
      timeout: 30000,
      maxBuffer: 65536,
    }, (error, stdout, stderr) => {
      if (error) {
        resolvePromise({
          version: null,
          error: String(stderr || error.message || error).slice(0, 300),
        })
        return
      }
      const found = /(\d+\.\d+\.\d+[-0-9A-Za-z.]*)/.exec(String(stdout))
      if (!found) resolvePromise({ version: null, error: 'npm 未返回版本号' })
      else resolvePromise({ version: found[1], error: null })
    })
  })
}

function launchUpdater(root, port) {
  return new Promise((resolvePromise) => {
    const updater = join(root, '_update', 'update-dsh.ps1')
    if (!existsSync(updater)) {
      resolvePromise({ started: false, error: '未找到更新器：' + updater })
      return
    }
    const childCommand =
      'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + updater + '" -Port ' + port
    const wmiArgs = "@{CommandLine='" + childCommand.replace(/'/g, "''") + "'}"
    const script =
      'Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments ' +
      wmiArgs +
      ' | Select-Object -ExpandProperty ProcessId'
    execFile('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], {
      cwd: root,
      windowsHide: true,
      timeout: 20000,
      maxBuffer: 65536,
    }, (error, stdout, stderr) => {
      if (error) {
        resolvePromise({
          started: false,
          error: String(stderr || error.message || error).slice(0, 300),
        })
        return
      }
      const pid = parseInt(String(stdout).trim().split(/\s+/).filter(Boolean).pop() || '', 10)
      if (!pid || Number.isNaN(pid)) {
        resolvePromise({
          started: false,
          error: String(stderr || stdout || 'WMI 未返回进程号').slice(0, 300),
        })
        return
      }
      resolvePromise({ started: true, pid })
    })
  })
}

export function apply(ctx, config) {
  const cfg = { ...DEFAULT_CONFIG, ...(config ?? {}) }
  if (cfg.enabled === false) return
  const root = detectInstallRoot(cfg)

  ctx.webServer.register({
    kind: 'exact',
    path: '/api/dsh-updater/status',
    handler: async (req, res) => {
      const installed = await readInstalledVersion(root)
      const latest = await readLatestVersion()
      sendJson(res, 200, {
        installRoot: root,
        current: installed.version,
        latest: latest.version,
        currentError: installed.error,
        latestError: latest.error,
        updateAvailable: !!(
          installed.version && latest.version && installed.version !== latest.version
        ),
      })
    },
  })

  ctx.webServer.register({
    kind: 'exact',
    path: '/api/dsh-updater/run',
    handler: async (req, res) => {
      if ((req.method ?? '') !== 'POST') {
        sendJson(res, 400, { started: false, error: 'expected POST' })
        return
      }
      const result = await launchUpdater(root, cfg.port)
      sendJson(res, result.started ? 200 : 500, result)
    },
  })
}
