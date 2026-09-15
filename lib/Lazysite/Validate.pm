package Lazysite::Validate;

# SM887 F2: PAGE VALIDATION IS SOMETHING THE ENGINE OFFERS, not something one
# surface owns.
#
# Ruled 2026-09-15: build it as an ENGINE CAPABILITY rather than as a
# dependency of the claude.ai skill that asked for it. The narrower option -
# shape it around what that skill needs - was refused for the reason worth
# keeping: a second consumer would want it reshaped, and reshaping something
# already shipped is a breaking change to a contract.
#
# WHERE IT CAME FROM. Every check below was already written, and lived inside
# `_validate_page` in lazysite-mcp.pl - reachable only by an authenticated MCP
# partner over HTTP, against a live docroot. Nothing else in the tree could ask:
# not the manager editor, not the control API, not CI, not a pre-commit hook,
# not a person with a file. This module is that code MOVED, not copied; MCP
# now calls it, so there is one implementation and one answer.
#
# THE TWO CHECKS THAT NEED A SITE SAY SO RATHER THAN GUESSING. `db:` bindings
# need the table descriptors and a bound form needs lazysite/forms/<name>.conf,
# so both take the docroot as a parameter. Without one they report that they
# could not check, which is the honest third state - a validator that silently
# skips a check is a validator that passes a page it never read.
#
# SEVERITY IS A FIELD NOW. It used to be positional: which of the two arrays a
# message landed in. Both are returned still, because that is the shape MCP
# partners already parse, but every message also carries `severity`, and
# `file` when the caller knew one - so a caller collecting messages from
# several pages does not have to remember which array they came out of.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    validate_content validate_file
    split_front_matter parse_front_matter
);

use Lazysite::Manager::Common ();

# Rules a form field may carry. A word outside this list is a typo, and a typo
# in a rule is silently ignored at render time - which is why it is worth
# naming before publish.
my %FORM_FLAGS = map { $_ => 1 }
    qw(required optional email tel date time number url password textarea);

# --- front matter ------------------------------------------------------------
#
# These live here rather than in the MCP script because the validator is now
# the thing that defines what a page's front matter IS, and two spellings of
# "split the front matter" is how a checker comes to check a different page
# from the one the engine renders.

sub split_front_matter {
    my ($c) = @_;
    return ( $1, $2 ) if $c =~ /\A---[ \t]*\n(.*?)\n?---[ \t]*\n?(.*)\z/s;
    return ( '', $c );
}

sub parse_front_matter {
    my ($fm) = @_;
    my %h;
    for my $line ( split /\n/, $fm ) {
        next unless $line =~ /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/;
        my ( $k, $v ) = ( $1, $2 );
        $v =~ s/\s+$//;
        if ( $v =~ /^\[(.*)\]$/ ) { $h{$k} = [ grep { length } map { s/^\s+|\s+$|["']//gr } split /,/, $1 ]; }
        else                      { $v =~ s/^["']|["']$//g; $h{$k} = $v; }
    }
    return \%h;
}

# SM488: a warning's line number counts from the top of the FILE, so a scan
# over the BODY (which split_front_matter returns without its --- fences) has
# to start at the front matter's line count plus the two fences. Written twice
# with two spellings before SM516.
sub _fm_line_offset {
    my ($fm) = @_;
    return 0 unless length $fm;
    return ( ( () = $fm =~ /\n/g ) + 1 ) + 2;
}

# MC-10: _validate_page was 285 lines of seven unrelated checks sharing two
# arrays. Each check is its own named sub, called in the ORDER IT WAS WRITTEN
# IN - the issue and warning lists are ordered and an agent reads them
# top-down, so the order is part of the answer, not an accident of layout.

sub _check_front_matter {
    my ( $issues, $warnings, $content, $h ) = @_;
    # Front matter: opened-but-unterminated, and missing title.
    if ( $content =~ /\A---\s*\n/ && $content !~ /\A---\s*\n.*?\n---\s*\n/s ) {
        push @$issues, { kind => 'front-matter-unterminated',
            message => 'front matter opened with --- but never closed' };
    }
    push @$warnings, { kind => 'no-title', message => 'page has no title in front matter' }
        unless length( $h->{title} // '' );

    # SM228: a raw/api page declaring a script-capable content_type is refused at
    # write time and downgraded to text/plain at serve time (ADR 0006). Pages
    # written before that refusal existed are still on disk, still serving as
    # plain text, and nothing told their author why. Report them here with the
    # same remedy the write path gives, so an existing page can be found without
    # loading each one.
    if ( my $raw = Lazysite::Manager::Common::raw_html_page_refusal($content) ) {
        push @$issues, { kind => 'raw-html-page', message => $raw };
    }
    return;
}

sub _check_fences {
    my ( $warnings, $fm, $body ) = @_;
    # GS11 (SM492): AN OPENING FENCE THAT IS NEVER CLOSED SAYS SO, HERE.
    #
    # The processor leaves an unbalanced `::: name` in the page as literal text
    # and logs a WARN the author cannot read over MCP. The symptom on the page
    # is three colons and a word where a hero should be. Reported at the line
    # counted from the top of the FILE (SM488), naming the fence, so the
    # reader's cursor lands on the fence that was opened and never closed.
    #
    # Lines inside ``` code blocks are skipped: a page that DOCUMENTS fences
    # would otherwise trip the check that exists to make fences safe.
    {
        my $off = _fm_line_offset($fm);
        my ( @open, $in_code );
        my $n = 0;
        for my $line ( split /\n/, ( $body // '' ) ) {
            $n++;
            if ( $line =~ /^[ \t]{0,3}(?:```|~~~)/ ) { $in_code = !$in_code; next }
            next if $in_code;
            if    ( $line =~ /^:::[ \t]+([\w-]+)/ ) { push @open, [ $1, $n + $off ] }
            elsif ( $line =~ /^:::[ \t]*$/ ) {
                if (@open) { pop @open }
                else {
                    push @$warnings, { kind => 'fence-close-unmatched', line => $n + $off,
                        message => 'a closing ::: with no open fence above it. It renders '
                            . 'as literal text; remove it or find the opening line it '
                            . 'was meant to close' };
                }
            }
        }
        for my $o (@open) {
            push @$warnings, { kind => 'component-fence-unmatched', line => $o->[1],
                fence   => $o->[0],
                message => "the '::: $o->[0]' fence opened here is never closed. The "
                    . 'processor leaves it in the page as literal text and the block '
                    . 'is not rendered as a component or a div; add the closing ::: '
                    . '(count them when you nest)' };
        }
    }
    return;
}

sub _check_db_bindings {
    my ( $issues, $warnings, $fm, $docroot ) = @_;
    # SM481: A `db:` BINDING THAT WILL RENDER NOTHING SAYS SO, HERE.
    #
    # The engine already logs the reason - "it may not be published (set
    # public: true) or this visitor may not be allowed to read it" - and it
    # logs it to STDERR, which on a real install is the web server's error log.
    # An agent working over MCP cannot read that, and a site agent lost an
    # afternoon to a page rendering zero rows while the API returned three from
    # the same table at the same moment. They said it exactly right: nothing in
    # the empty result said "this table is not published".
    #
    # A diagnostic the person who needs it cannot reach is not a diagnostic. So
    # it is answered where they are already looking, and STATICALLY - the
    # descriptor says whether a visitor would see anything, without rendering.
    #
    # Read from the front-matter TEXT rather than the parsed hash: tt_page_var
    # is nested, parse_front_matter is deliberately flat, and a checker that
    # silently saw no bindings would be a check that always passes.
    my $have_tables;
    for my $line ( split /\n/, ( $fm // '' ) ) {
        next unless $line =~ /:\s*db:([a-z][a-z0-9_]*)/;
        my $table = $1;

        # SM887 F2: NO DOCROOT, NO ANSWER - AND IT SAYS SO. Validating a file
        # in isolation (a pre-commit hook, the claude.ai skill before the site
        # context arrives) cannot reach the table descriptors, and reporting
        # "fine" would be a check that passes because it never ran.
        unless ( defined $docroot && length $docroot ) {
            push @$warnings, { kind => 'db-binding-unchecked',
                message => "could not check the table '$table' - no site was "
                    . 'given, so the descriptor could not be read. Re-run '
                    . 'against the site to check it.' };
            next;
        }

        # MCO-2: `require` is a no-op after the first load, but the eval and
        # the lookup are not free and the answer cannot change between two
        # bindings on the same page. Asked on the first binding, not on each
        # - and still not at all on a page that binds nothing, which is why
        # it is lazy here rather than hoisted to the top of the sub.
        $have_tables //= eval { require Lazysite::Data::Tables; 1 } ? 1 : 0;
        my $d = $have_tables
            ? eval { Lazysite::Data::Tables::load_table( $docroot, $table ) }
            : undef;
        unless ( ref $d eq 'HASH' ) {
            push @$warnings, { kind => 'db-binding-unchecked',
                message => "could not check the table '$table' - the data "
                    . 'modules are not available here' };
            next;
        }

        unless ( $d->{ok} ) {
            push @$issues, { kind => 'db-table-missing',
                message => "this page binds db:$table, and $d->{error}. The "
                    . 'binding will render nothing.' };
            next;
        }

        # THE ONE THAT COST THE AFTERNOON. An unpublished table answers a
        # visitor exactly as a table that was never declared does - which is
        # deliberate, and is why nothing on the page could say which it was.
        unless ( $d->{public} ) {
            push @$issues, { kind => 'db-table-not-published',
                message => "this page binds db:$table, which is NOT PUBLISHED. "
                    . 'An anonymous visitor sees no rows and no sign the table '
                    . 'exists, while the API and the manager still read it - so '
                    . 'the page looks broken and the data looks fine. Add '
                    . "public: true to the $table descriptor." };
        }
    }
    return;
}

sub _check_form_rules {
    my ( $issues, $content ) = @_;
    # Form-field rules (catch typos/unsupported rules before publish).
    if ( $content =~ /:::\s*form\b(.*?):::/s ) {
        for my $line ( split /\n/, $1 ) {
            $line =~ s/^\s+|\s+$//g;
            next unless length $line;
            my ( $name, undef, $rules ) = split /\s*\|\s*/, $line, 3;
            next if !defined $name || $name eq 'submit' || !defined $rules;
            # select: takes the rest of the line (its options are not rules and may
            # contain spaces) - drop it before checking the remaining rule tokens.
            ( my $check = $rules ) =~ s/\bselect:.*$//s;
            for my $tok ( split /\s+/, $check ) {
                next if $FORM_FLAGS{$tok} || $tok =~ /^[a-z]+:/; # known flag or key:value
                next if $tok                      !~ /^[a-z]+$/; # only flag plain words
                push @$issues, { kind => 'invalid-form-rule',
                    message => "unknown form rule '$tok' on field '$name'" };
            }
        }
    }
    return;
}

sub _check_html_in_page {
    my ( $warnings, $body, $h ) = @_;
    # SM243: warn at the moment of writing, not only in a briefing the agent read
    # once. The site briefings already say all of this; the problem is that an
    # agent reads them at the start and then works through a tool surface that
    # cheerfully accepts the thing the briefing warned against. write_file and
    # create_page already surface these warnings from here, so a check added here
    # reaches the write path for free.
    #
    # WARN, never refuse. A hand-written HTML page is occasionally the right
    # answer and the platform should not pretend otherwise - the complaint is
    # silence, not permissiveness. (SM228's REFUSAL is different in kind: it
    # catches a page that would be served as plain text, which is always broken.)
    if ( $body =~ /<!DOCTYPE\b/i || $body =~ /<html\b/i || $body =~ /<head\b/i ) {
        push @$warnings, { kind => 'document-in-page',
            message => 'this page body contains a whole HTML document. The layout '
                . 'is then bypassed, the processor mangles the block tags, and the '
                . 'page cannot be maintained as content. Author the body as Markdown '
                . 'and let the layout and theme supply the structure and styling; if '
                . 'you genuinely need a self-contained HTML file served unchanged, '
                . 'publish it as a STATIC FILE (a .html with no .md source is served '
                . 'byte-for-byte).' };
    }
    if ( $body =~ /<style[\s>]/i ) {
        push @$warnings, { kind => 'style-block-in-page',
            message => 'a <style> block in page content styles one page and leaves '
                . 'the rest of the site inconsistent. Put the rules in the theme, '
                . 'where every page gets them and a restyle is one change.' };
    }
    # A raw/api page carrying a document is the shape SM228 refuses only when it
    # also declares an HTML content type; without that it is merely wrong, so it
    # warns here.
    if ( ( $h->{api} // '' ) =~ /^true$/i
        && ( $body =~ /<!DOCTYPE\b/i || $body =~ /<html\b/i ) )
    {
        push @$warnings, { kind => 'api-page-is-a-document',
            message => 'api: true marks this page as a DATA artifact, but the body '
                . 'is an HTML document. api: is for JSON/CSV/text endpoints; a page '
                . 'for people belongs in the layout, and a self-contained HTML file '
                . 'belongs in a static file.' };
    }
    # Page-baked chrome plus a theme that hides the layout's is how a site ends up
    # with unreachable navigation: the operator sets nav items that never appear.
    if ( $body =~ m{<nav[\s>]}i || $body =~ m{<footer[\s>]}i ) {
        push @$warnings, { kind => 'chrome-in-page',
            message => 'this page carries its own <nav> or <footer>. Those are the '
                . 'layout\'s job - a page that bakes its own chrome duplicates the '
                . 'layout\'s, and hiding one with CSS is what makes site navigation '
                . 'unreachable while looking fine.' };
    }

    # SM249: there was a warning here telling authors that theme_assets,
    # theme_css, theme_name and theme are LAYOUT scope and resolve to nothing in
    # a page body. That was true, and it is not any more - the engine now
    # resolves the layout and the active theme BEFORE rendering the body, so the
    # pattern the warning forbade is the pattern that works.
    #
    # The warning is gone rather than softened. A warning that describes a
    # constraint the engine no longer has is worse than none: it teaches an
    # author to write the literal path, which then goes stale when the site's
    # theme changes, in order to avoid a failure that cannot happen.
    #
    # t/unit/mcp/15 now asserts the ABSENCE of that warning, so reintroducing it
    # fails, and t/unit/processor/19 asserts the variables actually resolve in a
    # body - the fact the warning existed to work around.
    return;
}

sub _check_form_delivery {
    my ( $warnings, $content, $body, $h, $path, $lazysite_dir ) = @_;
    # SM161: forms must be native (a :::form block bound to a sysop-vetted
    # handler), never hand-written HTML or a third-party form service.
    my $has_fenced_form = $content =~ /^:::[ \t]*form\b/m;
    if ( $body =~ /<form\b/i || $body =~ /<input\b/i || $body =~ /<textarea\b/i ) {
        push @$warnings, { kind => 'hand-authored-form',
            message => 'hand-written <form>/<input> HTML detected - it has no delivery '
                . 'handler and ships DEAD. Use a native :::form block (fields as '
                . '"name | Label | rules" lines) and wire delivery with bind_form.' };
    }
    if ( $body =~ /action\s*=\s*["']\s*mailto:/i ) {
        push @$warnings, { kind => 'form-mailto',
            message => 'a mailto: form action exposes an address and routes visitor '
                . 'data around the sysop-vetted handlers - use a :::form + bind_form.' };
    }
    if ( $body =~ m{
            action \s* = \s* ["'] \s* https?://
            (?:[\w.-]*\.)?
            (?: formspree\.io | docs\.google\.com | forms\.gle | jotform\.
              | typeform\. | wufoo\. | getform\. | form\.io )
        }ix )
    {
        push @$warnings, { kind => 'form-third-party',
            message => 'a third-party form endpoint routes visitor data OFF this '
                . 'instance, around the operator-vetted handlers (a data-governance '
                . 'leak, not a style choice) - use a :::form + bind_form instead.' };
    }
    # A native :::form that renders but was never bound to a handler does not
    # deliver. It is bound by front matter "form: NAME" + a lazysite/forms/NAME.conf
    # (written by bind_form); warn when the block is present but unbound.
    if ($has_fenced_form) {
        my $fname = $h->{form};
        if ( !defined $fname || !length $fname ) {
            push @$warnings, { kind => 'form-unnamed',
                message => 'a :::form block has no "form: NAME" in the front matter, so '
                    . 'it cannot be bound to a handler and will not deliver - add it, then bind_form.' };
        }
        elsif ( defined $path && length $path ) {
            # SM887 F2: the binding lives in the SITE, so without one this is
            # unanswerable rather than fine.
            unless ( defined $lazysite_dir && length $lazysite_dir ) {
                push @$warnings, { kind => 'form-binding-unchecked',
                    message => "could not check whether the form '$fname' is bound "
                        . 'to a delivery handler - no site was given. Re-run '
                        . 'against the site to check it.' };
                return;
            }
            my $conf = "$lazysite_dir/forms/$fname.conf";
            push @$warnings, { kind => 'form-unbound',
                message => "the form '$fname' is not bound to a delivery handler yet "
                    . '(it renders but does not deliver) - call bind_form(form, handler).' }
                unless -f $conf;
        }
    }
    return;
}

sub _check_public_data {
    my ( $warnings, $fm, $body ) = @_;
    # Public-data warnings - private/operational details that should not be
    # published accidentally (guest-instruction uploads carry these).
    # SM488: LINE NUMBERS ARE REPORTED AGAINST THE WHOLE PAGE, not the body.
    # The scan runs over $body, which split_front_matter returns WITHOUT its
    # fences, so a counter starting at zero here named every line short by
    # the front matter plus two. The field agent measured it exactly: reported
    # 15/58/59, actual 24/67/68, delta 9 - seven lines of front matter and two
    # fences. A warning that points at the wrong line is worse than none: the
    # reader opens line 15, finds a canonical link, and concludes the tool is
    # broken - which is nearly right and completely useless.
    my $ln = _fm_line_offset($fm);
    for my $line ( split /\n/, $body ) {
        $ln++;
        push @$warnings, { kind => 'public-credential', line => $ln,
            message => 'possible Wi-Fi / password value - confirm this should be public' }
            if $line =~ /\b(?:wi-?fi|password|passphrase|wpa2?|psk)\b\s*[:=]/i;
        push @$warnings, { kind => 'public-postcode', line => $ln,
            message => 'looks like a UK postcode - confirm the full address should be public' }
            if $line =~ /\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b/;
        # SM488: AN ISO DATE IS NOT A PHONE NUMBER. /\d[\d\s().-]{8,}\d/ matched
        # 2026-08-22 - ten characters of digits and hyphens - so a page with
        # three dates produced three phone warnings, two of them the filenames
        # of this project's own inbox filings. Dates are stripped from the line
        # before the phone pattern runs; a real number beside a date still
        # fires, because only the date is removed, not the line.
        ( my $undated = $line ) =~ s/\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?\b//g;
        push @$warnings, { kind => 'public-phone', line => $ln,
            message => 'contains a phone number - fine for a contact CTA, not for a private number' }
            if $undated =~ /\+?\d[\d\s().-]{8,}\d/ && $undated =~ /\d{3}/;
    }
    return;
}

# Validate page source held in memory.
#
#   content       the page source (required)
#   path          the page's path, when it has one - only the form-binding
#                 check uses it, and it says so when it is absent
#   docroot       the site, when there is one
#   lazysite_dir  the engine tree; derived from the docroot when not given
#   file          a label for the messages (the CLI puts the filename here)
#
# Returns { valid, issues => [], warnings => [] }. `valid` is false iff there
# is at least one ISSUE: a warning is a judgement call the author may have made
# deliberately, and a validator that failed on those would teach people to stop
# reading it.
sub validate_content {
    my (%o) = @_;
    my $content = $o{content};
    return { valid => 0,
        issues => [ { kind => 'no-content', severity => 'issue',
                message => 'no content to validate' } ],
        warnings => [] }
        unless defined $content;

    my $docroot = $o{docroot};
    my $lz      = $o{lazysite_dir};
    if ( !defined $lz && defined $docroot && length $docroot ) {

        # THE RESOLVER, never "$docroot/lazysite" by hand (SM850, t/lint/37):
        # a migrated site's engine tree is a SIBLING of the docroot, so a
        # hand-built path points at a directory that is not there and every
        # form would be reported unbound. Unresolvable leaves it undef, and the
        # form check then says it could not check - which is true.
        $lz = eval { require Lazysite::Paths; Lazysite::Paths::lazysite_dir($docroot) };
    }

    my ( @issues, @warnings );
    my ( $fm, $body ) = split_front_matter($content);
    my $h = parse_front_matter($fm);

    _check_front_matter( \@issues, \@warnings, $content, $h );
    _check_fences( \@warnings, $fm, $body );
    push @issues, Lazysite::Manager::Common::page_parse_issues($body);
    _check_db_bindings( \@issues, \@warnings, $fm, $docroot );
    _check_form_rules( \@issues, $content );
    _check_html_in_page( \@warnings, $body, $h );
    _check_form_delivery( \@warnings, $content, $body, $h, $o{path}, $lz );
    _check_public_data( \@warnings, $fm, $body );

    # SM887 F2: severity as a FIELD, not as which array it came out of, and the
    # file beside it. A caller gathering messages from twenty pages then has
    # everything it needs in the message itself.
    for my $m (@issues)   { $m->{severity} = 'issue' }
    for my $m (@warnings) { $m->{severity} = 'warning' }
    if ( defined $o{file} && length $o{file} ) {
        $_->{file} = $o{file} for ( @issues, @warnings );
    }

    return { valid => ( @issues ? 0 : 1 ), issues => \@issues, warnings => \@warnings };
}

# The same, for a file on disk. Unreadable is an ISSUE rather than a die: a run
# over twenty pages should report the one it could not open and carry on.
sub validate_file {
    my ( $file, %o ) = @_;
    open my $fh, '<:utf8', $file
        or return { valid => 0, warnings => [],
        issues => [ { kind => 'unreadable', severity => 'issue', file => $file,
                message => "cannot read $file: $!" } ] };
    my $content = do { local $/; <$fh> };
    close $fh;
    return validate_content( %o, content => $content, file => $file );
}

1;
