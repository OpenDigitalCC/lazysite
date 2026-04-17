---
title: Search Index
api: true
content_type: application/json; charset=utf-8
search: false
ttl: 3600
tt_page_var:
  all_pages: scan:/**/*.md filter=searchable:true sort=date desc
---
[% USE JSON.Escape %]
[% all_pages.json %]
