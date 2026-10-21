const $ = (id) => document.getElementById(id);
let token = localStorage.getItem('token');

function el(tag, text, attrs) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  Object.assign(e, attrs || {});
  return e;
}

function msg(text) { $('msg').textContent = text || ''; }

// All API calls go through here: adds auth header, parses JSON, handles 401
async function api(method, path, body) {
  const headers = {};
  if (body) headers['Content-Type'] = 'application/json';
  if (token) headers['Authorization'] = 'Bearer ' + token;
  const r = await fetch(path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const by = r.headers.get('X-Served-By');
  if (by) $('served').textContent = by + ' (' + r.headers.get('X-App-Version') + ')';
  const data = r.status === 204 ? null : await r.json().catch(() => null);
  if (r.status === 401 && token) { setToken(null); show(false); }
  if (!r.ok) throw new Error((data && data.error) || r.statusText);
  return data;
}

function setToken(t) {
  token = t;
  if (t) localStorage.setItem('token', t); else localStorage.removeItem('token');
}

function show(loggedIn) {
  $('out').hidden = loggedIn;
  $('in').hidden = !loggedIn;
  if (!loggedIn) $('stats').hidden = true;
}

// Run an async handler and show any error in the message line
function run(fn) {
  return async (ev) => {
    if (ev) ev.preventDefault();
    msg('');
    try { await fn(ev); } catch (e) { msg(e.message); }
  };
}

async function enter(username) {
  $('who').textContent = username;
  show(true);
  await refresh();
}

async function login(username, password) {
  const d = await api('POST', '/api/auth/login', { username, password });
  setToken(d.token);
  await enter(d.username);
}

async function refresh() {
  const [links, top] = await Promise.all([api('GET', '/api/links'), api('GET', '/api/stats/top')]);
  const tbody = $('links');
  tbody.replaceChildren();
  links.forEach((l) => tbody.appendChild(row(l)));
  const ol = $('top');
  ol.replaceChildren();
  top.forEach((t) => ol.appendChild(el('li', `${t.code} (${t.click_count} clicks) ${t.url.slice(0, 60)}`)));
}

function row(l) {
  const tr = el('tr');
  const a = el('a', l.short_url, { href: l.short_url, target: '_blank', rel: 'noopener' });
  tr.appendChild(el('td')).appendChild(a);
  tr.appendChild(el('td', l.url.length > 60 ? l.url.slice(0, 60) + '...' : l.url, { title: l.url }));
  tr.appendChild(el('td', String(l.click_count)));
  tr.appendChild(el('td', l.created_at));
  const actions = el('td');
  const btn = (label, fn) => {
    const b = el('button', label);
    b.onclick = run(fn);
    actions.append(b, ' ');
  };
  btn('copy', () => navigator.clipboard.writeText(l.short_url).then(() => msg('copied ' + l.short_url)));
  btn('stats', () => showStats(l.code));
  btn('delete', async () => {
    if (!confirm('Delete ' + l.code + '?')) return;
    await api('DELETE', '/api/links/' + l.code);
    await refresh();
  });
  tr.appendChild(actions);
  return tr;
}

async function showStats(code) {
  const s = await api('GET', '/api/stats/' + code);
  $('stats-code').textContent = code;
  $('stats-total').textContent = s.total_clicks;
  $('stats-last').textContent = s.last_click_at || 'never';
  const max = Math.max(1, ...s.daily.map((d) => d.clicks));
  $('stats-chart').textContent = s.daily
    .map((d) => `${d.date} ${'█'.repeat(Math.round((d.clicks / max) * 40))} ${d.clicks}`)
    .join('\n');
  $('stats').hidden = false;
}

$('login-form').onsubmit = run((ev) => login(ev.target.username.value, ev.target.password.value));

$('register-form').onsubmit = run(async (ev) => {
  const { username, password } = ev.target;
  await api('POST', '/api/auth/register', { username: username.value, password: password.value });
  await login(username.value, password.value);
});

$('logout').onclick = run(async () => {
  try { await api('POST', '/api/auth/logout'); } finally { setToken(null); show(false); }
});

$('create-form').onsubmit = run(async (ev) => {
  const l = await api('POST', '/api/links', { url: ev.target.url.value });
  ev.target.reset();
  msg('created: ' + l.short_url);
  await refresh();
});

$('refresh').onclick = run(refresh);
$('stats-close').onclick = () => { $('stats').hidden = true; };

(async () => {
  if (!token) return show(false);
  try {
    const me = await api('GET', '/api/auth/me');
    await enter(me.username);
  } catch (e) { setToken(null); show(false); }
})();
