// Frontend logic for the URL shortener UI (vanilla JS, no build step).
// Author: Nihal Singh Atwal (student ID 49299175, nihalsingh.atwal@student.uq.edu.au)
// AI declaration: Written with assistance from Claude Code (Anthropic); reviewed and tested by the author.
const $ = (id) => document.getElementById(id);
let token = localStorage.getItem('token');
let links = [];

const ICONS = {
  link: 'M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z',
  bar: 'M5 9.2h3V19H5zM10.6 5h2.8v14h-2.8zm5.6 8H19v6h-2.8z',
  add: 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z',
  copy: 'M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z',
  qr: 'M3 11h8V3H3v8zm2-6h4v4H5V5zM3 21h8v-8H3v8zm2-6h4v4H5v-4zM13 3v8h8V3h-8zm6 6h-4V5h4v4zM13 13h2v2h-2zM15 15h2v2h-2zM13 17h2v2h-2zM17 13h2v2h-2zM19 15h2v2h-2zM17 17h2v2h-2zM19 19h2v2h-2zM15 19h2v2h-2z',
  download: 'M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z',
  edit: 'M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a1 1 0 0 0 0-1.41l-2.34-2.34a1 1 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z',
  del: 'M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z',
  logout: 'M17 7l-1.41 1.41L18.17 11H8v2h10.17l-2.58 2.58L17 17l5-5zM4 5h8V3H4c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h8v-2H4V5z',
  search: 'M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z',
};
const SVGNS = 'http://www.w3.org/2000/svg';

function svg(tag, attrs, text) {
  const e = document.createElementNS(SVGNS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (text !== undefined) e.textContent = text;
  return e;
}

function icon(name) {
  const s = svg('svg', { viewBox: '0 0 24 24' });
  s.appendChild(svg('path', { d: ICONS[name] }));
  return s;
}

function el(tag, text, attrs) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  Object.assign(e, attrs || {});
  return e;
}

function msg(text) { document.querySelectorAll('.msg').forEach((m) => { m.textContent = text || ''; }); }

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
  $('app').hidden = !loggedIn;
  if (!loggedIn) document.querySelectorAll('dialog[open]').forEach((d) => d.close());
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

const isExpired = (l) => l.expires_at && new Date(l.expires_at) < new Date();
const fmt = (ts) => ts.slice(0, 16).replace('T', ' ');

async function refresh() {
  const [list, top] = await Promise.all([api('GET', '/api/links'), api('GET', '/api/stats/top')]);
  links = list;
  renderLinks();
  const tbody = $('top');
  tbody.replaceChildren();
  const max = Math.max(1, ...top.map((t) => t.click_count));
  top.forEach((t, i) => {
    const tr = el('tr');
    tr.append(el('td', String(i + 1)));
    const td = el('td');
    td.append(el('b', t.code), el('div', t.url, { className: 'target' }));
    tr.append(td, el('td', String(t.click_count)));
    const bar = el('td');
    bar.style.width = '35%';
    const m = el('div', '', { className: 'meter' });
    m.style.width = Math.round((t.click_count / max) * 100) + '%';
    bar.append(m);
    tr.append(bar);
    tbody.append(tr);
  });
}

function renderLinks() {
  $('c-links').textContent = links.length;
  $('c-clicks').textContent = links.reduce((n, l) => n + l.click_count, 0);
  $('c-active').textContent = links.filter((l) => !isExpired(l)).length;
  const q = $('search').value.trim().toLowerCase();
  const tbody = $('links');
  tbody.replaceChildren();
  links.filter((l) => !q || l.code.toLowerCase().includes(q) || l.url.toLowerCase().includes(q))
    .forEach((l) => tbody.append(row(l)));
}

function row(l) {
  const tr = el('tr');
  const td = el('td');
  td.append(el('a', l.short_url.replace(/^https?:\/\//, ''), { href: l.short_url, target: '_blank', rel: 'noopener' }),
    el('div', l.url, { className: 'target', title: l.url }));
  tr.append(td, el('td', String(l.click_count)));
  const st = el('td');
  st.append(el('span', isExpired(l) ? 'Expired' : 'Active', { className: 'chip' + (isExpired(l) ? ' off' : '') }));
  tr.append(st, el('td', l.created_at.slice(0, 10)), el('td', l.expires_at ? fmt(l.expires_at) : '—'));
  const acts = el('td', undefined, { className: 'acts' });
  const btn = (name, label, fn, cls) => {
    const b = el('button', undefined, { className: 'icon ' + (cls || ''), title: label });
    b.setAttribute('aria-label', label);
    b.append(icon(name));
    b.onclick = run(fn);
    acts.append(b);
  };
  btn('qr', 'View QR', async () => showQr(l.code));
  const dl = el('a', undefined, { className: 'btn icon', title: 'Download QR', href: '/api/links/' + l.code + '/qr', download: 'qr-' + l.code + '.svg' });
  dl.setAttribute('aria-label', 'Download QR');
  dl.append(icon('download'));
  acts.append(dl);
  btn('bar', 'Stats (web vs QR)', () => showStats(l));
  btn('edit', 'Edit', async () => {
    $('edit-code').textContent = 'Edit ' + l.code;
    $('edit-url').value = l.url;
    $('edit-form').dataset.code = l.code;
    $('edit-form').expires.value = 'keep';
    msg('');
    $('d-edit').showModal();
  });
  btn('del', 'Delete', async () => {
    if (!confirm('Delete ' + l.code + '?')) return;
    await api('DELETE', '/api/links/' + l.code);
    await refresh();
  }, 'del');
  tr.append(acts);
  return tr;
}

function showQr(code) {
  $('qr-code').textContent = code;
  $('qr-img').src = '/api/links/' + code + '/qr';
  $('qr-dl').href = '/api/links/' + code + '/qr';
  $('d-qr').showModal();
}

async function showStats(l) {
  const s = await api('GET', '/api/stats/' + l.code);
  $('stats-code').textContent = l.short_url.replace(/^https?:\/\//, '');
  $('stats-url').textContent = l.url;
  $('s-total').textContent = s.total_clicks;
  $('s-web').textContent = s.total_clicks - s.qr_clicks;
  $('s-qr').textContent = s.qr_clicks;
  $('s-last').textContent = s.last_click_at ? fmt(s.last_click_at) : 'never';
  $('chart').replaceChildren(chart(s.daily));
  $('d-stats').showModal();
}

// Stacked column chart: web clicks (bottom) + QR scans (top), one column per day
function chart(daily) {
  const W = 640, H = 260, L = 36, R = 8, T = 18, B = 34, iw = W - L - R, ih = H - T - B;
  const max = Math.max(1, ...daily.map((d) => d.clicks));
  const raw = max / 4, pow = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = Math.max(1, pow * ([1, 2, 5, 10].find((n) => raw / pow <= n)));
  const top = step * Math.ceil(max / step);
  const y = (v) => T + ih - (v / top) * ih;
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': 'Clicks per day, last 7 days' });
  for (let v = 0; v <= top; v += step) {
    s.append(svg('line', { class: 'grid', x1: L, x2: W - R, y1: y(v), y2: y(v) }));
    s.append(svg('text', { class: 'axis', x: L - 6, y: y(v) + 4, 'text-anchor': 'end' }, v));
  }
  const col = iw / daily.length, bw = col * 0.5;
  daily.forEach((d, i) => {
    const x = L + i * col + (col - bw) / 2, web = d.clicks - d.qr_clicks;
    const g = svg('g');
    g.append(svg('title', {}, `${d.date}: ${d.clicks} clicks (web ${web}, QR ${d.qr_clicks})`));
    if (web) g.append(svg('rect', { class: 'b-web', x, y: y(web), width: bw, height: y(0) - y(web), rx: 2 }));
    if (d.qr_clicks) g.append(svg('rect', { class: 'b-qr', x, y: y(d.clicks), width: bw, height: y(web) - y(d.clicks), rx: 2 }));
    if (d.clicks) g.append(svg('text', { class: 'val', x: x + bw / 2, y: y(d.clicks) - 5, 'text-anchor': 'middle' }, d.clicks));
    const dt = new Date(d.date + 'T00:00:00Z');
    g.append(svg('text', { class: 'axis', x: x + bw / 2, y: H - 12, 'text-anchor': 'middle' },
      dt.toLocaleDateString('en', { weekday: 'short', timeZone: 'UTC' }) + ' ' + dt.getUTCDate()));
    s.append(g);
  });
  return s;
}

document.querySelectorAll('[data-i]').forEach((i) => i.append(icon(i.dataset.i)));
document.querySelectorAll('[data-close]').forEach((b) => { b.onclick = () => b.closest('dialog').close(); });
document.querySelectorAll('nav button').forEach((b) => {
  b.onclick = () => {
    document.querySelectorAll('nav button').forEach((n) => n.classList.toggle('active', n === b));
    $('v-links').hidden = b.dataset.view !== 'links';
    $('v-top').hidden = b.dataset.view !== 'top';
    $('title').textContent = b.textContent;
  };
});

$('login-form').onsubmit = run((ev) => login(ev.target.username.value, ev.target.password.value));

$('register-form').onsubmit = run(async (ev) => {
  const { username, password } = ev.target;
  await api('POST', '/api/auth/register', { username: username.value, password: password.value });
  await login(username.value, password.value);
});

$('logout').onclick = run(async () => {
  try { await api('POST', '/api/auth/logout'); } finally { setToken(null); show(false); }
});

$('new').onclick = () => { msg(''); $('d-create').showModal(); $('in-url').focus(); };
$('edit-form').onsubmit = run(async (ev) => {
  const f = ev.target, e = f.expires.value, body = { url: f.url.value };
  if (e !== 'keep') body.expires_in_hours = e === 'none' ? null : Number(e);
  await api('PATCH', '/api/links/' + f.dataset.code, body);
  $('d-edit').close();
  await refresh();
  msg('Updated ' + f.dataset.code);
});
$('search').oninput = renderLinks;

$('create-form').onsubmit = run(async (ev) => {
  const hours = ev.target.expires.value;
  const l = await api('POST', '/api/links', { url: ev.target.url.value, expires_in_hours: hours ? Number(hours) : undefined });
  ev.target.reset();
  $('d-create').close();
  await refresh();
  msg('Created ' + l.short_url);
});

(async () => {
  if (!token) return show(false);
  try {
    const me = await api('GET', '/api/auth/me');
    await enter(me.username);
  } catch (e) { setToken(null); show(false); }
})();
