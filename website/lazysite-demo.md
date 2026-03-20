<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[% page_title %][% IF site_name %] — [% site_name %][% END %]</title>
    <meta name="description" content="[% IF page_subtitle %][% page_subtitle %][% ELSE %][% site_tagline %][% END %]">
    <style>
        /* ── Tokens — edit here to retheme ── */
        :root {
            --bg:          #ffffff;
            --bg-subtle:   #f6f8fa;
            --border:      #e2e6ea;
            --text:        #24292f;
            --text-muted:  #656d76;
            --accent:      #0969da;
            --accent-bg:   #dbeafe;
            --heading:     #1a1f24;
            --code-text:   #e44c3a;
            --font-sans:   system-ui, -apple-system, 'Segoe UI', sans-serif;
            --font-mono:   ui-monospace, 'SF Mono', 'Cascadia Mono', 'Fira Code', monospace;
            --measure:     70ch;
            --gutter:      clamp(1rem, 5vw, 2rem);
        }

        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        html { font-size: 16px; scroll-behavior: smooth; }

        body {
            background: var(--bg);
            color: var(--text);
            font-family: var(--font-sans);
            font-size: 1rem;
            line-height: 1.75;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
        }

        /* ── Header ── */
        header {
            border-bottom: 1px solid var(--border);
            padding: 0 var(--gutter);
        }

        .header-inner {
            max-width: calc(var(--measure) + 6rem);
            margin: 0 auto;
            display: flex;
            align-items: center;
            height: 3.25rem;
            gap: 1.5rem;
        }

        .site-name {
            font-family: var(--font-mono);
            font-size: 0.9rem;
            font-weight: 600;
            color: var(--heading);
            text-decoration: none;
            flex-shrink: 0;
        }

        nav {
            margin-left: auto;
            display: flex;
            align-items: center;
            gap: 0.25rem;
        }

        nav a {
            color: var(--text-muted);
            text-decoration: none;
            font-size: 0.875rem;
            padding: 0.3rem 0.6rem;
            border-radius: 4px;
            transition: color 0.1s, background 0.1s;
        }

        nav a:hover { color: var(--text); background: var(--bg-subtle); }

        nav a[aria-current="page"] {
            color: var(--accent);
            background: var(--accent-bg);
        }

        nav .github-link {
            border: 1px solid var(--border);
            color: var(--text-muted);
            margin-left: 0.5rem;
        }

        nav .github-link:hover { color: var(--text); border-color: var(--text-muted); background: var(--bg); }

        /* ── Main ── */
        main {
            flex: 1;
            padding: clamp(2rem, 5vw, 3.5rem) var(--gutter);
        }

        .content {
            max-width: var(--measure);
            margin: 0 auto;
        }

        /* ── Page header ── */
        .page-header {
            margin-bottom: 2rem;
            padding-bottom: 1.5rem;
            border-bottom: 1px solid var(--border);
        }

        .page-header h1 {
            font-size: clamp(1.5rem, 4vw, 2rem);
            font-weight: 700;
            color: var(--heading);
            line-height: 1.25;
            letter-spacing: -0.02em;
        }

        .page-header .subtitle {
            margin-top: 0.4rem;
            color: var(--text-muted);
            font-size: 1rem;
        }

        /* ── Typography ── */
        .content h2 {
            font-size: 1.2rem;
            font-weight: 600;
            color: var(--heading);
            margin-top: 2.25rem;
            margin-bottom: 0.6rem;
            letter-spacing: -0.01em;
        }

        .content h3 {
            font-size: 1rem;
            font-weight: 600;
            color: var(--heading);
            margin-top: 1.75rem;
            margin-bottom: 0.4rem;
        }

        .content h4 {
            font-size: 0.8rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.06em;
            color: var(--text-muted);
            margin-top: 1.5rem;
            margin-bottom: 0.4rem;
        }

        .content p { margin-bottom: 1rem; }

        .content a {
            color: var(--accent);
            text-decoration: underline;
            text-underline-offset: 2px;
            text-decoration-thickness: 1px;
        }

        .content a:hover { text-decoration-thickness: 2px; }

        .content ul, .content ol {
            padding-left: 1.5rem;
            margin-bottom: 1rem;
        }

        .content li { margin-bottom: 0.25rem; }

        /* ── Definition lists ── */
        .content dl { margin-bottom: 1rem; }

        .content dt {
            font-weight: 600;
            color: var(--heading);
            margin-top: 0.75rem;
        }

        .content dd {
            margin-left: 1.25rem;
        }

        /* ── Code ── */
        .content code {
            font-family: var(--font-mono);
            font-size: 0.85em;
            color: var(--code-text);
            background: var(--bg-subtle);
            padding: 0.15em 0.35em;
            border-radius: 3px;
            border: 1px solid var(--border);
        }

        .content pre {
            background: var(--bg-subtle);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 1rem 1.25rem;
            overflow-x: auto;
            margin-bottom: 1.25rem;
            font-size: 0.875rem;
            line-height: 1.6;
        }

        .content pre code {
            color: var(--text);
            background: none;
            border: none;
            padding: 0;
            font-size: inherit;
        }

        /* ── Blockquote ── */
        .content blockquote {
            border-left: 3px solid var(--border);
            padding-left: 1rem;
            color: var(--text-muted);
            margin-bottom: 1rem;
        }

        /* ── Tables ── */
        .content table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 1.25rem;
            font-size: 0.9rem;
        }

        .content th {
            text-align: left;
            padding: 0.5rem 0.75rem;
            background: var(--bg-subtle);
            border: 1px solid var(--border);
            font-size: 0.8rem;
            font-weight: 600;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.04em;
        }

        .content td {
            padding: 0.5rem 0.75rem;
            border: 1px solid var(--border);
            vertical-align: top;
        }

        .content tr:nth-child(even) td { background: var(--bg-subtle); }

        /* ── Fenced divs ── */
        .content .widebox {
            background: var(--bg-subtle);
            border-left: 3px solid var(--accent);
            padding: 1rem 1.25rem;
            margin: 1.5rem 0;
            border-radius: 0 4px 4px 0;
        }

        .content .textbox {
            background: var(--accent-bg);
            border: 1px solid #bfdbfe;
            padding: 0.875rem 1.1rem;
            margin: 1.25rem 0;
            border-radius: 4px;
            max-width: 60%;
        }

        .content .marginbox {
            float: right;
            width: 13rem;
            margin: 0 0 1.25rem 1.5rem;
            background: var(--bg-subtle);
            border: 1px solid var(--border);
            padding: 0.875rem;
            font-size: 0.875rem;
            border-radius: 4px;
            color: var(--text-muted);
            font-style: italic;
        }

        .content .examplebox {
            background: var(--bg-subtle);
            border: 1px solid var(--border);
            border-top: 2px solid var(--text-muted);
            padding: 1rem 1.25rem;
            margin: 1.25rem 0;
            border-radius: 0 0 4px 4px;
            font-size: 0.925rem;
        }

        /* ── Footer ── */
        footer {
            border-top: 1px solid var(--border);
            padding: 1rem var(--gutter);
            background: var(--bg-subtle);
        }

        .footer-inner {
            max-width: calc(var(--measure) + 6rem);
            margin: 0 auto;
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 1rem;
            flex-wrap: wrap;
            font-size: 0.8rem;
            color: var(--text-muted);
        }

        footer a { color: var(--text-muted); text-decoration: none; }
        footer a:hover { color: var(--accent); text-decoration: underline; }

        /* ── Mobile ── */
        @media (max-width: 600px) {
            .content .textbox   { max-width: 100%; }
            .content .marginbox { float: none; width: 100%; margin: 1rem 0; }
            .content table      { font-size: 0.8rem; }
            .content th,
            .content td         { padding: 0.4rem 0.5rem; }
        }
    </style>
</head>
<body>

<header>
    <div class="header-inner">
        <a href="/" class="site-name">[% site_name %]</a>
        <nav>
            <a href="/"[% IF REDIRECT_URL == '/' || REDIRECT_URL == '/index' %] aria-current="page"[% END %]>home</a>
            <a href="/motivation"[% IF REDIRECT_URL == '/motivation' %] aria-current="page"[% END %]>why</a>
            <a href="/docs"[% IF REDIRECT_URL == '/docs' %] aria-current="page"[% END %]>docs</a>
            <a href="[% github_url %]" class="github-link">github</a>
        </nav>
    </div>
</header>

<main>
    <div class="content">
        <div class="page-header">
            <h1>[% page_title %]</h1>
            [% IF page_subtitle %]<p class="subtitle">[% page_subtitle %]</p>[% END %]
        </div>
        [% content %]
    </div>
</main>

<footer>
    <div class="footer-inner">
        <span>[% site_name %] — MIT licence</span>
        <span>
            <a href="[% github_url %]">source on github</a>
            &nbsp;·&nbsp;
            <a href="/docs">docs</a>
            &nbsp;·&nbsp;
            <a href="/lazysite-demo">demo</a>
        </span>
    </div>
</footer>

</body>
</html>
