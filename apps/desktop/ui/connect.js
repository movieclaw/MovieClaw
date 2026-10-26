async function callTauri(cmd, args) {
    if (window.__TAURI__?.core?.invoke) return window.__TAURI__.core.invoke(cmd, args);
    if (window.__TAURI_INTERNALS__?.invoke) return window.__TAURI_INTERNALS__.invoke(cmd, args);
    throw new Error('Tauri API 不可用');
  }

  function setStatus(msg, cls) {
    const el = document.getElementById('status');
    el.textContent = msg;
    el.className = 'status ' + cls;
  }

  async function loadSaved() {
    try {
      const saved = await callTauri('load_server_url');
      if (saved) document.getElementById('server-url').value = saved;
    } catch {}
  }

  async function doProbe() {
    const url = document.getElementById('server-url').value.trim();
    if (!url) { setStatus('请输入服务器地址', 'err'); return; }
    setStatus('正在测试连接...', 'loading');
    try {
      const r = await callTauri('probe_server', { url });
      setStatus(r.message, r.ok ? 'ok' : 'err');
    } catch (e) {
      setStatus('测试失败: ' + e, 'err');
    }
  }

  async function doConnect() {
    const url = document.getElementById('server-url').value.trim();
    if (!url) { setStatus('请输入服务器地址', 'err'); return; }
    setStatus('正在连接...', 'loading');
    try {
      await callTauri('save_server_url', { url });
      const r = await callTauri('probe_server', { url });
      if (r.ok) {
        setStatus('连接成功，正在跳转...', 'ok');
        window.location.href = 'desktop/index.html';
      } else {
        setStatus(r.message, 'err');
      }
    } catch (e) {
      setStatus('连接失败: ' + e, 'err');
    }
  }

  async function doDiscover() {
    setStatus('正在搜索局域网服务器...', 'loading');
    document.getElementById('discovered-list').style.display = 'none';
    try {
      const servers = await callTauri('discover_servers');
      if (servers && servers.length > 0) {
        setStatus(`找到 ${servers.length} 台服务器`, 'ok');
        const list = document.getElementById('discovered-list');
        list.style.display = 'block';
        list.replaceChildren();
        servers.forEach(server => {
          const row = document.createElement('button');
          row.className = 'btn btn-secondary';
          row.style.textAlign = 'left';
          row.textContent = `${server.name || 'MovieClaw'} · ${server.url} · ${server.version || '?'}`;
          row.addEventListener('click', () => selectServer(server.url));
          list.appendChild(row);
        });
      } else {
        setStatus('未找到服务器，请手动输入地址', 'err');
      }
    } catch (e) {
      setStatus('搜索失败: ' + e, 'err');
    }
  }

  function selectServer(url) {
    document.getElementById('server-url').value = url;
    doConnect();
  }

  document.getElementById('server-url').addEventListener('keydown', e => {
    if (e.key === 'Enter') doConnect();
  });

  document.getElementById('btn-connect').addEventListener('click', doConnect);
  document.getElementById('btn-probe').addEventListener('click', doProbe);
  document.getElementById('btn-discover').addEventListener('click', doDiscover);
  loadSaved().then(() => callTauri('native_ready')).catch(() => {});
