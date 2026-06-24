---
title: OAuth authorization server
api: true
content_type: application/json; charset=utf-8
search: false
---
{
  "issuer": "[% site_url %]",
  "authorization_endpoint": "[% site_url %]/cgi-bin/lazysite-oauth.pl?action=authorize",
  "token_endpoint": "[% site_url %]/cgi-bin/lazysite-oauth.pl?action=token",
  "registration_endpoint": "[% site_url %]/cgi-bin/lazysite-oauth.pl?action=register",
  "scopes_supported": ["mcp"],
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"]
}
