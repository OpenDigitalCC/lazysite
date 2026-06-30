---
title: How lazysite compares
subtitle: Pick the tools to compare lazysite against - one or several at once.
register:
  - sitemap.xml
  - llms.txt
---

<div id="cmp-app" data-src="/data/comparisons.json">
<p id="cmp-intro"></p>
<div id="cmp-picker" class="cmp-picker"></div>
<div id="cmp-out"></div>
<noscript>Enable JavaScript to choose comparisons interactively, or browse the data at <a href="/data/comparisons.json">comparisons.json</a>.</noscript>
</div>

<style>.cmp-picker{display:flex;flex-wrap:wrap;gap:10px 14px;margin:1.2rem 0 1.4rem;align-items:center}.cmp-picker .cmp-lead{font-weight:600;opacity:.7}.cmp-picker label{display:inline-flex;align-items:center;gap:6px;font-weight:600;cursor:pointer;border:1px solid var(--theme-colours-border,#ddd);border-radius:8px;padding:6px 12px}.cmp-picker input{accent-color:var(--primary,#16a34a)}.cmp-tbl{width:100%;border-collapse:collapse;font-size:.92rem;margin:.5rem 0 1.4rem}.cmp-tbl th,.cmp-tbl td{text-align:left;vertical-align:top;padding:9px 12px;border-bottom:1px solid var(--theme-colours-border,#e3e3e3)}.cmp-tbl thead th{font-weight:700;border-bottom:2px solid var(--theme-colours-border,#cfcfcf)}.cmp-tbl tbody th{font-weight:600;width:22%}.cmp-tbl tr.cmp-grp th{background:rgba(0,0,0,.03);font-size:.78rem;text-transform:uppercase;letter-spacing:.05em}.cmp-tbl col.lz{background:rgba(22,163,74,.06)}.cmp-tbl td.lz{font-weight:500}.cmp-tbl a.src{font-size:.7em;opacity:.45;text-decoration:none;margin-left:3px}.cmp-tbl a.src:hover{opacity:1}.cmp-tbl thead th a.src{opacity:.6}.cmp-hint{font-size:.82rem;opacity:.6;margin:0 0 .6rem}@media(max-width:640px){.cmp-tbl{font-size:.82rem}.cmp-tbl th,.cmp-tbl td{padding:7px}}</style>

<script>
(function(){
  var app=document.getElementById('cmp-app'); if(!app) return;
  var picker=document.getElementById('cmp-picker'), out=document.getElementById('cmp-out');
  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
  function src(u){ return u?'<a class="src" href="'+esc(u)+'" target="_blank" rel="noopener" title="Source: '+esc(u)+'">[src]</a>':''; }
  fetch(app.getAttribute('data-src')).then(function(r){return r.json();}).then(function(d){
    var lz=d.lazysite_key||'lazysite';
    var lzSys=d.systems.filter(function(s){return s.key===lz;})[0];
    var others=d.systems.filter(function(s){return s.key!==lz;});
    var intro=document.getElementById('cmp-intro'); if(intro) intro.textContent=d.intro||'';
    var sel={}; if(others[0]) sel[others[0].key]=true;
    var lead=document.createElement('span'); lead.className='cmp-lead'; lead.textContent='Compare with:'; picker.appendChild(lead);
    others.forEach(function(s){
      var lbl=document.createElement('label');
      lbl.innerHTML='<input type="checkbox" '+(sel[s.key]?'checked':'')+'> '+esc(s.name);
      lbl.querySelector('input').addEventListener('change',function(e){ sel[s.key]=e.target.checked; render(); });
      picker.appendChild(lbl);
    });
    function cell(v,isLz){ var t=v?(esc(v.text)+src(v.source)):'-'; return '<td'+(isLz?' class="lz"':'')+(v&&v.source?' title="Source: '+esc(v.source)+'"':'')+'>'+t+'</td>'; }
    function render(){
      var cols=[lzSys].concat(others.filter(function(s){return sel[s.key];}));
      var n=cols.length+1;
      var cg='<colgroup><col>'+cols.map(function(s){return s.key===lz?'<col class="lz">':'<col>';}).join('')+'</colgroup>';
      var head='<thead><tr><th>Feature</th>'+cols.map(function(s){return '<th>'+esc(s.name)+' '+src(s.source)+'</th>';}).join('')+'</tr></thead>';
      var body='', lastG=null;
      d.items.forEach(function(it){
        if(it.group!==lastG){ body+='<tr class="cmp-grp"><th colspan="'+n+'">'+esc(it.group)+'</th></tr>'; lastG=it.group; }
        body+='<tr><th>'+esc(it.label)+src(it.source)+'</th>'+cols.map(function(s){ return cell(it.values[s.key], s.key===lz); }).join('')+'</tr>';
      });
      out.innerHTML='<p class="cmp-hint">lazysite is always the first column. Hover a value, or click [src], for its source.</p><table class="cmp-tbl">'+cg+head+'<tbody>'+body+'</tbody></table>';
    }
    render();
  }).catch(function(){ out.innerHTML='<p>Could not load the comparison data. Browse it at <a href="/data/comparisons.json">comparisons.json</a>.</p>'; });
})();
</script>
