---
title: AI partner bootstrap
api: true
content_type: application/json; charset=utf-8
search: false
register:
  - llms.txt
---
{
  "site": "[% site_url %]",
  "self": "[% site_url %]/.well-known/ai-partner",
  "note": "This bootstrap is served dynamically from the live configuration (SM190): fetch it over HTTP and it lists only the endpoints whose service is enabled. This static page exists so the URL is registered in llms.txt; the processor code-serves the real document."
}
