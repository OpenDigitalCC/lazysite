---
title: Domains
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<p style="font-size:0.85em;color:#888;margin:0 0 12px;">
Domains served by this instance. Aliases are configured in
<code>lazysite/lazysite.conf</code> (<code>alias_hosts</code> and
<code>alias.&lt;host&gt;.&lt;key&gt;</code>) &mdash; this view is read&#8209;only.
A grey value is inherited from the default; a solid value is a per&#8209;domain
override. Give a domain its own <code>content_root</code> to serve it as a
first&#8209;class site (its own home, sitemap, feeds and search); point DNS and
TLS at this site to route it.
</p>

<div id="domains-list">
  <div class="mg-status">Loading&hellip;</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

function esc(s) {
  var d = document.createElement('div');
  d.textContent = (s == null ? '' : String(s));
  return d.innerHTML;
}

function loadDomains() {
  fetch(API + '?action=domains-list')
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var host = document.getElementById('domains-list');
      if (!d || !d.ok) {
        host.innerHTML = '<div class="mg-status">Could not load domains.</div>';
        return;
      }
      var keys = d.keys || [];
      var rows = d.domains || [];
      var html = '<table class="mg-file-table"><thead><tr><th>Host</th>';
      keys.forEach(function (k) { html += '<th>' + esc(k) + '</th>'; });
      html += '</tr></thead><tbody>';
      rows.forEach(function (row) {
        html += '<tr><td class="mg-file-name"><strong>' + esc(row.host) + '</strong>'
              + (row.is_primary ? ' <span style="color:#888;font-weight:400">primary</span>' : '')
              + '</td>';
        keys.forEach(function (k) {
          var v = row[k];
          var inherited = row[k + '_inherited'];
          var cell;
          if (!v) {
            cell = '<span style="color:#ccc">&mdash;</span>';
          } else if (inherited) {
            cell = '<span style="color:#999" title="inherited from the default host">' + esc(v) + '</span>';
          } else {
            cell = esc(v);
          }
          html += '<td>' + cell + '</td>';
        });
        html += '</tr>';
      });
      html += '</tbody></table>';
      if (rows.length <= 1) {
        html += '<p style="font-size:0.85em;color:#888;margin-top:10px;">'
              + 'No alias domains configured. Add <code>alias_hosts</code> and '
              + '<code>alias.&lt;host&gt;.content_root</code> in lazysite.conf to host '
              + 'several first-class sites from this one instance.</p>';
      }
      host.innerHTML = html;
    })
    .catch(function () {
      document.getElementById('domains-list').innerHTML =
        '<div class="mg-status">Error loading domains.</div>';
    });
}

loadDomains();
</script>
