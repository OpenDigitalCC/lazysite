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
  "endpoints": {
    "webdav": "[% site_url %]/dav/",
    "exchange": "[% site_url %]/cgi-bin/lazysite-auth.pl?action=exchange",
    "rotate": "[% site_url %]/cgi-bin/lazysite-auth.pl?action=rotate",
    "control": "[% site_url %]/cgi-bin/lazysite-manager-api.pl",
    "mcp": "[% site_url %]/cgi-bin/lazysite-mcp.pl"
  },
  "modes": {
    "api": "WebDAV (file ops, bulk) + control API (theme/layout/acl/config) over Basic auth; the full surface, best for scripted builds.",
    "mcp": "Remote MCP server at the mcp endpoint exposing the maintenance verbs as tools; add as a connector with bearer auth '<partner-id>:<lzs_ token>'. Best for an MCP-capable agent; one file per write call."
  },
  "auth": {
    "scheme": "basic",
    "token_prefix": "lzs_",
    "note": "Basic auth: username = your partner id from your onboarding brief, password = the lzs_ access token. Exchange the operator-issued pairing key (lzp_) at the exchange endpoint for {token, expires_at}; rotate before expiry. One live credential per account."
  },
  "capabilities": ["webdav", "manage_themes", "manage_layouts", "manage_config"],
  "scope": {
    "webdav": "content, assets, layout/theme files under lazysite/layouts/, and lazysite/nav.conf (the last with manage_config)",
    "control_api": "config keys, theme/layout activation, HTML-cache clear (manage_config / manage_themes / manage_layouts)",
    "deny": ["/cgi-bin/", "/manager/", "/lazysite/auth/", "/lazysite/forms/smtp.conf", "/lazysite/forms/handlers.conf", "/lazysite/forms/submissions/", "/lazysite/cache/", "/lazysite/logs/", "/lazysite/manager/", "/lazysite/templates/", "/lazysite/lazysite.conf", "*.pl"]
  },
  "docs": [
    "[% site_url %]/docs/ai-briefing-publishing",
    "[% site_url %]/docs/reference",
    "[% site_url %]/docs/ai-briefing-authoring",
    "[% site_url %]/docs/ai-briefing-configuration",
    "[% site_url %]/docs/ai-briefing-layouts",
    "[% site_url %]/llms.txt"
  ]
}
