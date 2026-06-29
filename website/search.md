---
title: Search
subtitle: Search the lazysite site.
search: false
register:
  - sitemap.xml
---

<div class="search-page">
<input type="search" id="sq" placeholder="Search lazysite..." autocomplete="off" autofocus>
<div class="search-status" id="sstatus"></div>
<div id="sresults"></div>
</div>

<style>.search-page input[type=search]{width:100%;box-sizing:border-box;padding:.75rem 1rem;font-size:1.05rem;border:1px solid var(--theme-colours-border,#ddd);border-radius:8px;margin:1.2rem 0 .5rem}.search-status{color:var(--theme-colours-muted,#666);font-size:.9rem;margin:.3rem 0 1rem}.s-result{border-bottom:1px solid var(--theme-colours-border,#eee);padding:.9rem 0}.s-result h3{margin:0 0 .25rem;font-size:1.05rem}.s-result h3 a{text-decoration:none}.s-result p{margin:.2rem 0;font-size:.9rem;line-height:1.5}.s-result .s-sub{opacity:.7}mark{background:#fff3cd;padding:0 .1em}</style>

<script>
(function(){
  var idx=null, loadingP=null,
      q=document.getElementById('sq'),
      out=document.getElementById('sresults'),
      st=document.getElementById('sstatus');

  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}

  // Reduce stored Markdown/HTML to readable plain text (drop style/script, tags, code, md syntax).
  function clean(s){
    s=String(s==null?'':s);
    s=s.replace(/\[%[\s\S]*?%\]/g,' ');
    s=s.replace(/<style[\s\S]*?<\/style>/gi,' ').replace(/<script[\s\S]*?<\/script>/gi,' ');
    s=s.replace(/<[^>]+>/g,' ').replace(/<[^>]*$/,' ').replace(/[<>]/g,' ');
    s=s.replace(/```[\s\S]*?```/g,' ').replace(/`[^`]*`/g,' ');
    s=s.replace(/!\[[^\]]*\]\([^)]*\)/g,' ').replace(/\[([^\]]*)\]\([^)]*\)/g,'$1');
    s=s.replace(/^#{1,6}\s+/gm,'').replace(/^\s*[>\-\*\+]\s+/gm,'');
    s=s.replace(/\*\*|__|~~|\*|_/g,'');
    s=s.replace(/&[a-z]+;/gi,' ');
    return s.replace(/\s+/g,' ').trim();
  }
  function snippet(s,n){ s=clean(s); return s.length>n ? s.slice(0,n).replace(/\s+\S*$/,'')+'...' : s; }
  function hl(s,t){ s=esc(s); if(!t) return s; try{ return s.replace(new RegExp('('+t.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+')','ig'),'<mark>$1</mark>'); }catch(e){ return s; } }

  // Single fetch shared by the background prefetch and any live search.
  function load(){
    if(idx) return Promise.resolve(idx);
    if(!loadingP) loadingP=fetch('/search-index').then(function(r){return r.json();}).then(function(d){idx=d;return d;});
    return loadingP;
  }

  function run(){
    var t=q.value.trim();
    if(!t){ out.innerHTML=''; st.textContent=''; return; }
    if(!idx) st.textContent='Searching...';
    var lt=t.toLowerCase();
    load().then(function(){
      if(q.value.trim()!==t) return; // a newer keystroke is in flight
      var res=idx.filter(function(p){ return ((p.title||'')+' '+(p.subtitle||'')+' '+(p.excerpt||'')+' '+(p.tags||'')+' '+(p.url||'')).toLowerCase().indexOf(lt)>-1; }).slice(0,40);
      st.textContent=res.length+(res.length===1?' result':' results')+' for "'+t+'"';
      out.innerHTML=res.map(function(p){
        var ex=snippet(p.excerpt,200); if(ex.length<15) ex='';
        return '<div class="s-result"><h3><a href="'+esc(p.url)+'">'+hl(clean(p.title)||p.url,t)+'</a></h3>'
          +(p.subtitle?'<p class="s-sub">'+hl(clean(p.subtitle),t)+'</p>':'')
          +(ex?'<p>'+hl(ex,t)+'</p>':'')+'</div>';
      }).join('');
    }).catch(function(){ st.textContent='Search is unavailable right now.'; });
  }

  q.addEventListener('input',run);

  // Warm the index AFTER first paint, so it never delays time-to-display.
  function prefetch(){ load().catch(function(){}); }
  if('requestIdleCallback' in window){ requestIdleCallback(prefetch,{timeout:2500}); }
  else { window.addEventListener('load', function(){ setTimeout(prefetch, 200); }); }

  // Honour ?q= (e.g. from a future header search box) without blocking paint.
  var m=location.search.match(/[?&]q=([^&]*)/);
  if(m){ q.value=decodeURIComponent(m[1].replace(/\+/g,' ')); setTimeout(run,0); }
})();
</script>
