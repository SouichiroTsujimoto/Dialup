const Dialup = (() => {
    let socket = null;
    let currentPath = null;
    // redo/undo による遷移かどうかのフラグ
    let isPopstateNavigation = false;

    function send(event, value) {
        if (socket && socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({ event, value }));
        }
    }

    // idiomorph による差分適用
    function applyHtml(html) {
        const root = document.getElementById("dialup-root");
        if (root) {
            Idiomorph.morph(root, html, { morphStyle: "innerHTML" });
        }
    }

    function navigate(path) {
        if (path === currentPath) return;
        send("__navigate", path);
    }

    function setupDelegation() {
        const root = document.getElementById("dialup-root");
        if (!root) return;

        root.addEventListener("click", (e) => {
            // ws-href
            const linkEl = e.target.closest("[ws-href]");
            if (linkEl) {
                e.preventDefault();
                navigate(linkEl.getAttribute("ws-href"));
                return;
            }

            // ws-event
            const eventEl = e.target.closest("[ws-event]");
            if (eventEl) {
                e.preventDefault();
                const event = eventEl.getAttribute("ws-event");
                const value = eventEl.getAttribute("ws-value") ?? "";
                send(event, value);
            }
        });
    }

    // redo/undo
    function setupPopstate() {
        window.addEventListener("popstate", (e) => {
            const path = e.state?.path ?? window.location.pathname;
            isPopstateNavigation = true;
            send("__navigate", path);
        });
    }

    function setStatus(text) {
        const el = document.getElementById("ws-status");
        if (el) el.textContent = text;
    }

    function connect(initialPath) {
        currentPath = initialPath;

        history.replaceState({ path: initialPath }, "", initialPath);

        const proto = location.protocol === "https:" ? "wss:" : "ws:";
        const url = `${proto}//${location.host}/ws`;

        socket = new WebSocket(url);

        socket.onopen = () => {
            setStatus("接続済み ✓");
            send("__init", currentPath);
        };

        socket.onmessage = (e) => {
            const msg = JSON.parse(e.data);

            if (msg.target) {
                // 指定IDの要素だけを更新
                const el = document.getElementById(msg.target);
                if (el) Idiomorph.morph(el, msg.html);

            } else if (msg.html !== undefined && msg.path !== undefined) {
                // #dialup-root 全体を差し替え
                applyHtml(msg.html);

                if (msg.path !== currentPath) {
                    if (!isPopstateNavigation) {
                        history.pushState({ path: msg.path }, "", msg.path);
                    }
                    currentPath = msg.path;
                }
                isPopstateNavigation = false;
            }
        };

        socket.onclose = () => {
            setStatus("切断されました。再読み込みしてください。");
        };

        socket.onerror = () => {
            setStatus("接続エラー");
        };

        setupPopstate();
        setupDelegation();
    }

    return { connect };
})();
