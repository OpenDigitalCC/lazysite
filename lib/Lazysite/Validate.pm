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
    html_pattern_problem
);

use Lazysite::Manager::Common ();

# Rules a form field may carry. A word outside this list is a typo, and a typo
# in a rule is silently ignored at render time - which is why it is worth
# naming before publish.
my %FORM_FLAGS = map { $_ => 1 }
    qw(required optional email tel date time number url password textarea);

# --- SM921: a `pattern` a browser cannot compile validates NOTHING -----------
#
# An HTML `pattern` attribute is compiled as `new RegExp("^(?:"+pattern+")$","v")`
# - the `v` (unicodeSets) flag - and the specification's answer to a pattern that
# will not compile is to IGNORE THE ATTRIBUTE IN FULL. So a pattern with a syntax
# error does not over-reject or under-reject: it is not there, no console message
# reaches the author, and the field accepts anything. The engine's own shipped
# default for `tel` was in exactly that state, and an owner found it by typing the
# single letter S into their phone field and being allowed.
#
# THE LIST IS MEASURED, NOT REASONED. Perl cannot run that compiler, so this is the
# enumerable subset - but the subset was established by running every shape through
# node's `v` flag, which is the same engine (tmp/measure-v-flag-shapes.js, node
# v20.19.2, 2026-10-01):
#
#   ( ) { } [ ] / |   bare inside a character class  -> uncompilable
#   a hyphen at the start or end of a class          -> uncompilable
#   !! or ##          inside a class                 -> uncompilable (set operation)
#   ~ ! # & ^         bare inside a class            -> COMPILE, and are not flagged
#   anything outside a class                         -> unaffected
#
# The filing's list named ( ) - [ ] { } and missed `/` and `|`, both of which fail.
# `~ ! # &` would have been plausible additions and compile fine, which is why the
# list is measured: this drives a REFUSAL at validate time, so a shape flagged
# wrongly rejects a page that works.
#
# UNDER-FLAGGING IS THE SAFE DIRECTION and is deliberate. A mid-class hyphen that
# is not a range (`[a.-z]`) is not flagged; the browser's behaviour for anything
# missed is what it is today, which is the state this check improves on rather than
# a new hazard.
my %CLASS_RESERVED = map { $_ => 1 } qw< ( ) { } [ ] / | >;

# Returns one sentence naming the problem, or '' when nothing is found. Shared by
# validate_content (which REFUSES) and tools/lazysite-check.pl (which WARNS) -
# t/lint/204 holds it to one definition, because two copies of this judgement is
# the arrangement ADR 0001 only tolerates where a module cannot be loaded.
sub html_pattern_problem {
    my ($pattern) = @_;
    return '' unless defined $pattern && length $pattern;

    my $in_class = 0;
    my @chars    = split //, $pattern;

    # A C-STYLE LOOP, because the escape below SKIPS a character. `for my $i (
    # 0 .. $#chars )` aliases $i to each element of a temporary list, so
    # incrementing it inside the body is discarded on the next iteration - and the
    # failure mode is the worst available one here: `[\(]` would read the `(` as
    # unescaped and REFUSE a page whose pattern is correct.
    for ( my $i = 0; $i <= $#chars; $i++ ) {
        my $c = $chars[$i];

        # An escape covers the next character wherever we are.
        if ( $c eq '\\' ) { $i++; next }

        if ( !$in_class ) {
            $in_class = 1 if $c eq '[';
            next;
        }

        # Inside a class. The close bracket is the one reserved character that
        # ends it rather than breaking it.
        if ( $c eq ']' ) { $in_class = 0; next }

        if ( $CLASS_RESERVED{$c} ) {
            return "the character class contains an unescaped $c - a browser "
                . "compiles `pattern` with the `v` flag, under which $c must be "
                . "written \\$c inside [ ]. An uncompilable pattern is ignored "
                . 'in full, so the field validates nothing.';
        }
        if ( $c eq '!' && ( $chars[ $i + 1 ] // '' ) eq '!' ) {
            return 'the character class contains `!!`, which the `v` flag reads '
                . 'as a set operation. Write \\!\\! - an uncompilable pattern is '
                . 'ignored in full, so the field validates nothing.';
        }
        if ( $c eq '#' && ( $chars[ $i + 1 ] // '' ) eq '#' ) {
            return 'the character class contains `##`, which the `v` flag reads '
                . 'as a set operation. Write \\#\\# - an uncompilable pattern is '
                . 'ignored in full, so the field validates nothing.';
        }
    }

    # A hyphen at either end of a class is a literal in older syntax and a syntax
    # error under `v`. This is the one that cost the reporter an hour: removing the
    # parentheses from the shipped default is not enough, because the `-` before
    # `]` fails on its own.
    return 'a character class begins or ends with an unescaped hyphen, which the '
        . '`v` flag refuses - write \\- . An uncompilable pattern is ignored in '
        . 'full, so the field validates nothing.'
        if _class_has_edge_hyphen($pattern);

    return '';
}

# The hyphen check, kept apart because it reads the classes rather than the
# characters: a `-` BETWEEN two members is a range and legal, and only one at the
# very start or the very end of a class is not.
sub _class_has_edge_hyphen {
    my ($pattern) = @_;
    my @body;
    my ( $in_class, $buf ) = ( 0, '' );
    my @chars = split //, $pattern;
    for ( my $i = 0; $i <= $#chars; $i++ ) {
        my $c = $chars[$i];
        if ( $c eq '\\' ) { $buf .= $c . ( $chars[ $i + 1 ] // '' ) if $in_class; $i++; next }
        if ( !$in_class ) { ( $in_class, $buf ) = ( 1, '' ) if $c eq '['; next }
        if ( $c eq ']' )  { push @body, $buf; $in_class = 0; next }
        $buf .= $c;
    }
    push @body, $buf if $in_class;    # an unclosed class, read as far as it goes

    for my $b (@body) {
        $b =~ s/\A\^//;               # a negated class: ^ is not a member
        next unless length $b;
        return 1 if $b =~ /\A-/ || $b =~ /(?<!\\)-\z/;
    }
    return 0;
}

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

        # SM857: (mine) on a table with no created_by renders nothing and says
        # so only in the render log, so it is said here too - by the parser the
        # render uses, not a second reading of the grammar.
        my ($spec) = $line =~ /:\s*(db:.*?)\s*\z/;
        my $q = eval { require Lazysite::Data::Query;
            Lazysite::Data::Query::parse_binding( $spec, $d ) } || {};
        if ( ( $q->{kind} // '' ) eq 'mine_needs_timestamps' ) {
            push @$issues, { kind => 'db-mine-no-owner',
                message => "this page binds db:$table with (mine), and $q->{error}." };
            next;
        }

        # A (mine) BINDING IS NOT HELPED BY PUBLISHING. An anonymous viewer
        # owns no rows, so it renders nothing to them whether or not the table
        # is public, and any signed-in account may read an unpublished table -
        # advice to add public: true would widen a table for no gain.
        next if $q->{mine};

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
            # SM921: THE PATTERN IS READ BEFORE THE TOKENS, and it takes the rest of
            # the line exactly as the processor now does - the two have to agree
            # about where a pattern ends or this checks a different page from the
            # one that renders. A quoted pattern keeps its own value.
            my $pat;
            ( my $check = $rules ) =~ s/\bselect:.*$//s;
            if    ( $check =~ s/\bpattern:"((?:[^"\\]|\\.)*)"// ) { $pat = $1 }
            elsif ( $check =~ s/\bpattern:(\S.*)\z//s )           { $pat = $1 }
            if    ( defined $pat ) {
                $pat =~ s/\s+\z//;
                if ( my $why = html_pattern_problem($pat) ) {
                    push @$issues, { kind => 'uncompilable-pattern',
                        message => "the pattern on field '$name' will not compile: $why" };
                }
            }

            # select: takes the rest of the line (its options are not rules and may
            # contain spaces) - dropped above before the remaining rule tokens are
            # checked, as the pattern now is.
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
        # SM976 Q15f: the form the page binds as the processor renders it.
        my $fname = Lazysite::Manager::Common::page_form($content);
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
    # SM900: with the front-matter offset, as _check_fences has always done, so
    # the two checks on one page count from the same place - the top of the file.
    push @issues, Lazysite::Manager::Common::page_parse_issues( $body, _fm_line_offset($fm) );
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
#
# SM976 Q15i (ruled 2026-10-09, "Same rule" for every page walk): a file whose
# bytes are not valid UTF-8 is unreadable in the same sense - it is not
# validated, it is reported, and the run carries on. Read through a lax :utf8
# layer, such a file made the checks die ("Malformed UTF-8 character
# (fatal)"), and a run over every page of a site printed nothing for any of
# them (tmp/q15i-more-probe.before.out). Judged by the rule a page write is
# judged by (Manager::Common::invalid_utf8_offset); a valid file is decoded as
# the :utf8 layer read it.
sub validate_file {
    my ( $file, %o ) = @_;
    open my $fh, '<:raw', $file
        or return { valid => 0, warnings => [],
        issues => [ { kind => 'unreadable', severity => 'issue', file => $file,
                message => "cannot read $file: $!" } ] };
    my $content = do { local $/; <$fh> };
    close $fh;
    my $at = Lazysite::Manager::Common::invalid_utf8_offset($content);
    return { valid => 0, warnings => [],
        issues => [ { kind => 'unreadable', severity => 'issue', file => $file,
                message => "cannot read $file: it is not valid UTF-8 (the first invalid byte is at "
                    . "offset $at), so it was not checked - save it as UTF-8 and check it again" } ] }
        if defined $at;
    utf8::decode($content) if defined $content;
    return validate_content( %o, content => $content, file => $file );
}

1;
