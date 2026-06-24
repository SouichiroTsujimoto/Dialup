const Dialup = (() => {
    let socket = null;
    let currentPath = null;
    let isPopstateNavigation = false;
    let isReconnecting = false;
    let reconnectAttempts = 0;
    let reconnectTimer = null;
    let hooks = {};
    const debounceTimers = new WeakMap();

    const tabId = crypto.randomUUID();

    function send(event, value) {
        if (socket && socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({ event, value }));
            return true;
        }
        return false;
    }

    function callHook(el, lifecycle) {
        const name = el.getAttribute("ws-hook");
        if (!name) return;
        const hook = hooks[name];
        if (hook && typeof hook === "object" && typeof hook[lifecycle] === "function") {
            hook[lifecycle](el);
        }
    }

    function applyHtml(html) {
        const root = document.getElementById("dialup-root");
        if (root) {
            Idiomorph.morph(root, html, {
                morphStyle: "innerHTML",
                callbacks: {
                    afterNodeAdded(node) {
                        if (node.getAttribute?.("ws-hook")) callHook(node, "mounted");
                    },
                    afterNodeMorphed(_old, node) {
                        if (node.getAttribute?.("ws-hook")) callHook(node, "updated");
                    },
                    beforeNodeRemoved(node) {
                        if (node.getAttribute?.("ws-hook")) callHook(node, "destroyed");
                    }
                }
            });
        }
    }

    function applyUpdate(html, path, pushEvent, payload) {
        const isNavigation = path !== currentPath;

        applyHtml(html);
        setConnectionState(socket?.readyState === WebSocket.OPEN);
        if (isNavigation) window.scrollTo(0, 0);
        if (pushEvent) {
            const handler = hooks[pushEvent];
            if (typeof handler === "function") handler(payload ?? {});
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
            const linkEl = e.target.closest("[ws-href]");
            if (linkEl) {
                e.preventDefault();
                navigate(linkEl.getAttribute("ws-href"));
                return;
            }

            const eventEl = e.target.closest("[ws-event]");
            if (eventEl) {
                e.preventDefault();
                const event = eventEl.getAttribute("ws-event");
                const encodedParams = eventEl.getAttribute("data-dialup-params");
                let value = eventEl.getAttribute("ws-value") ?? "";
                if (encodedParams) {
                    try { value = JSON.parse(encodedParams); } catch (_error) {}
                }
                send(event, value);
            }
        });

        root.addEventListener("submit", (e) => {
            const formEl = e.target.closest("[ws-submit]");
            if (formEl) {
                e.preventDefault();
                const event = formEl.getAttribute("ws-submit");
                const value = Object.fromEntries(new FormData(formEl));
                send(event, value);
            }
        });

        root.addEventListener("input", (e) => {
            const inputEl = e.target.closest("[ws-change]");
            if (inputEl) {
                const event = inputEl.getAttribute("ws-change");
                const debounceMs = parseInt(inputEl.getAttribute("ws-debounce"), 10);

                if (debounceMs > 0) {
                    const prev = debounceTimers.get(inputEl);
                    if (prev) clearTimeout(prev);
                    debounceTimers.set(inputEl, setTimeout(() => {
                        debounceTimers.delete(inputEl);
                        send(event, e.target.value);
                    }, debounceMs));
                } else {
                    send(event, e.target.value);
                }
            }
        });
    }

    function setupPopstate() {
        window.addEventListener("popstate", (e) => {
            const path = e.state?.path ?? window.location.pathname;
            isPopstateNavigation = true;
            send("__navigate", path);
        });
    }

    function setConnectionState(connected) {
        const el = document.getElementById("ws-status");
        if (el) el.dataset.wsState = connected ? "connected" : "disconnected";
    }

    function connectSocket(opts = {}) {
        const proto = location.protocol === "https:" ? "wss:" : "ws:";
        const url = `${proto}//${location.host}/ws?tab_id=${encodeURIComponent(tabId)}`;

        socket = new WebSocket(url);

        socket.onopen = () => {
            if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
            reconnectAttempts = 0;
            setConnectionState(true);

            if (isReconnecting) {
                if (opts.onReconnect) opts.onReconnect();
                send("__reconnect", currentPath);
                isReconnecting = false;
            } else {
                if (opts.onConnect) opts.onConnect();
                send("__init", currentPath);
            }
        };

        socket.onmessage = (e) => {
            const msg = JSON.parse(e.data);

            if (msg.target) {
                const el = document.getElementById(msg.target);
                if (el) Idiomorph.morph(el, msg.html);
            } else if (msg.html !== undefined && msg.path !== undefined) {
                if (msg.path !== currentPath) {
                    if (!isPopstateNavigation) {
                        history.pushState({ path: msg.path }, "", msg.path);
                    }
                }
                isPopstateNavigation = false;

                applyUpdate(msg.html, msg.path, msg.push_event, msg.payload);
                if (msg.title !== undefined) document.title = msg.title;
                currentPath = msg.path;
            }
        };

        socket.onclose = () => {
            isReconnecting = true;
            scheduleReconnect(opts);
        };

        socket.onerror = () => {};
    }

    function scheduleReconnect(opts) {
        const delay = Math.min(1000 * (2 ** reconnectAttempts), 30000);
        reconnectAttempts++;
        setConnectionState(false);
        if (opts.onDisconnect) opts.onDisconnect(reconnectAttempts);
        reconnectTimer = setTimeout(() => connectSocket(opts), delay);
    }

    function connect(opts = {}) {
        hooks = opts.hooks ?? {};
        currentPath = window.location.pathname;
        history.replaceState({ path: currentPath }, "", currentPath);
        setupPopstate();
        setupDelegation();
        connectSocket(opts);
    }

    return { connect, send, navigate, tabId };
})();
