/**
 * DSH 更新器 — Client 半（手写 ModuleLoader bundle，格式与 uiopt/官方 client-* 包一致）
 *
 * 职责：设置 → 更新 页面。显示当前运行时版本与 npm 最新版，提供"重新检查"
 * 与"立即更新"（二次确认）。数据经同源路由 /api/dsh-updater/* 与 host 通信，
 * 浏览器不接触任何密钥。
 */
window.__ModuleLoader__.load({
  id: "dsh-updater",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
    let react = require("react");

    const wrap = { display: "flex", flexDirection: "column", gap: 14, padding: "2px", fontSize: 13, color: "var(--dsw-alias-label-primary)" };
    const card = { border: "1px solid var(--dsw-alias-border-l1)", borderRadius: 10, padding: "14px 16px", background: "var(--dsw-alias-bg-layer-1)", display: "flex", flexDirection: "column", gap: 10 };
    const row = { display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12 };
    const keyLabel = { color: "var(--dsw-alias-label-secondary)" };
    const mono = { fontFamily: "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace" };
    const actions = { display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" };
    const btn = { appearance: "none", border: "1px solid var(--dsw-alias-border-l2)", background: "transparent", color: "var(--dsw-alias-label-primary)", borderRadius: 8, padding: "7px 14px", fontSize: 13, cursor: "pointer" };
    const btnPrimary = Object.assign({}, btn, { borderColor: "var(--dsw-alias-brand-primary)", color: "var(--dsw-alias-brand-primary)", fontWeight: 600 });
    const note = { color: "var(--dsw-alias-label-secondary)", lineHeight: 1.65 };
    const warn = { color: "var(--dsw-alias-state-warn-primary)" };
    const err = { color: "var(--dsw-alias-state-error-primary)" };
    const ok = { color: "var(--dsw-alias-state-success-primary)" };

    function Panel() {
      const [state, setState] = react.useState({ phase: "loading", info: null, message: null, tone: null, confirm: false });

      const check = () => {
        setState({ phase: "loading", info: null, message: null, tone: null, confirm: false });
        fetch("/api/dsh-updater/status", { cache: "no-store" })
          .then((r) => r.json())
          .then((info) => setState({ phase: "ready", info: info, message: null, tone: null, confirm: false }))
          .catch((e) => setState({ phase: "ready", info: null, message: "检查失败：" + String((e && e.message) || e), tone: "err", confirm: false }));
      };

      react.useEffect(() => { check(); }, []);

      const start = () => {
        if (!state.confirm) {
          setState(Object.assign({}, state, { confirm: true, tone: "warn", message: "再点一次确认更新。更新器会先下载并校验新版本（期间 DSH 正常运行），随后自动停止 DSH、替换运行时、适配启动器并重新启动。" }));
          return;
        }
        setState(Object.assign({}, state, { phase: "running", message: "正在启动更新进程…", tone: null, confirm: false }));
        fetch("/api/dsh-updater/run", { method: "POST" })
          .then((r) => r.json())
          .then((result) => {
            if (result && result.started) {
              setState(Object.assign({}, state, { phase: "started", tone: "ok", confirm: false, message: "更新进程已启动（PID " + result.pid + "，已脱离 DSH 进程树）。它会先下载并校验新版本，此间 DSH 照常运行；随后自动停止 DSH、完成替换、适配启动器并重新启动。约 1 分钟后刷新本页即可。" }));
            } else {
              setState(Object.assign({}, state, { phase: "ready", tone: "err", confirm: false, message: "启动失败：" + ((result && result.error) || "未知错误") }));
            }
          })
          .catch((e) => setState(Object.assign({}, state, { phase: "ready", tone: "err", confirm: false, message: "启动失败：" + String((e && e.message) || e) })));
      };

      const info = state.info;
      const rows = [];
      rows.push(react.createElement("div", { key: "cur", style: row },
        react.createElement("span", { style: keyLabel }, "当前运行时"),
        react.createElement("span", { style: mono }, info && info.current ? info.current : (state.phase === "loading" ? "读取中…" : "未知"))));
      rows.push(react.createElement("div", { key: "lat", style: row },
        react.createElement("span", { style: keyLabel }, "npm 最新版"),
        react.createElement("span", { style: mono }, info && info.latest ? info.latest : (state.phase === "loading" ? "查询中…" : "未知"))));
      rows.push(react.createElement("div", { key: "state", style: row },
        react.createElement("span", { style: keyLabel }, "状态"),
        react.createElement("span", { style: info && info.updateAvailable ? warn : ok },
          info ? (info.updateAvailable ? "有新版本可用" : "已是最新") : "—")));

      const nodes = [react.createElement("div", { key: "card", style: card }, rows)];
      if (info && info.currentError) {
        nodes.push(react.createElement("div", { key: "ce", style: Object.assign({}, note, err) }, "读取本地版本失败：" + info.currentError));
      }
      if (info && info.latestError) {
        nodes.push(react.createElement("div", { key: "le", style: Object.assign({}, note, err) }, "查询最新版本失败：" + info.latestError));
      }
      if (state.message) {
        nodes.push(react.createElement("div", { key: "msg", style: Object.assign({}, note, state.tone === "err" ? err : state.tone === "warn" ? warn : state.tone === "ok" ? ok : {}) }, state.message));
      }

      const busy = state.phase === "loading" || state.phase === "running";
      nodes.push(react.createElement("div", { key: "act", style: actions },
        react.createElement("button", { key: "chk", style: btn, disabled: busy, onClick: check }, "重新检查"),
        react.createElement("button", { key: "run", style: btnPrimary, disabled: busy || state.phase === "started", onClick: start }, state.confirm ? "确认更新" : "立即更新")));
      nodes.push(react.createElement("div", { key: "root", style: Object.assign({}, note, mono) },
        info && info.installRoot ? info.installRoot + "\\_update" : " "));

      return react.createElement("div", { style: wrap }, nodes);
    }

    const entry = {
      name: "dsh-updater",
      inject: ["slots"],
      apply(ctx) {
        ctx.slots.inject("settings.section", () => ctx.slots.register(
          { name: "settings.section", id: "dsh-updater", order: 25, label: "更新" },
          () => react.createElement(Panel, null)
        ));
	      }
	    };
	    exports.default = entry;
	    exports.name = entry.name;
	    exports.inject = entry.inject;
	    exports.apply = entry.apply;
	    return module.exports;
	  }
});
