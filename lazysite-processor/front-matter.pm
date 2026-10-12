package main;

# lazysite-processor/front-matter.pm - the processor's front-matter parser.
#
# HOLDS   parse_yaml_front_matter($text) -> ( \%meta, $body ): a page's front
#         matter as the render path reads it; and the minimal nested-YAML
#         parser behind `sections:` - _parse_sections, _yaml_block, _yaml_value,
#         _yaml_scalar, _yaml_split_flow, _yaml_quoted_scalar_line; and
#         _access_keys_read($fm), the one reading of auth, auth_groups and
#         payment that the gate (auth.pm, _peek_md) and this parse share (SM980).
# OWNS    what a page's front matter means to the engine: process_md, the
#         include path and the registry scan all read it through this one parse.
#         And (P12/P13, at the end of this part) _front_matter_lists with
#         _front_matter_engine_keys and _front_matter_list_item: a YAML list is a
#         list, whatever its key.
# CALLS   strip_tt_directives (lazysite-processor/oembed.pm).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S1). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree,
# and a part that is installed beside the script keeps that property.
use strict;
use warnings;

# --- D035 Phase 3: minimal nested-YAML for front-matter `sections:` -----------
# A self-contained indentation parser for the subset `sections:` needs: a top
# sequence of single-key maps, nested maps, nested sequences, inline flow maps
# {k: v, ...} / seqs [a, b], and quoted/bareword scalars. Only runs for pages
# that declare `sections:`; everything else is untouched. Not a general YAML.
sub _yaml_scalar {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return undef if $s eq '' || $s eq '~' || lc $s eq 'null';
    return $1    if $s =~ /^"(.*)"$/s;
    return $1    if $s =~ /^'(.*)'$/s;
    return $s;
}

# SM940: is this line a single quoted scalar, and nothing else?
#
# The question exists because `_yaml_block`'s mapping test splits on the first
# colon, and a quote is exactly what an author adds to protect a value that
# CONTAINS a colon - so `'https://github.com/x'` was read as the key `'https`
# with the value `//github.com/x'`. Silent: a layout received single-key hashes
# where it expected strings, and the page merely rendered wrong.
#
# THE OBVIOUS TEST IS WRONG, which is why this is a named sub rather than a
# pattern inline. "Starts with a quote and ends with the same quote" also
# describes `'a': 'b'`, a legitimate quoted-KEY mapping, and reading that as a
# scalar would trade one defect for another. The discriminator is whether the
# OPENING quote closes at the end of the line:
#
#   'https://github.com/x'   closes at the last character  -> scalar
#   'a': 'b'                 closes before the colon       -> mapping
sub _yaml_quoted_scalar_line {
    my ($s) = @_;
    return 0 unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return 0 unless length($s) >= 2;
    return 0 unless $s =~ /^(["'])/;
    return index( $s, $1, 1 ) == length($s) - 1 ? 1 : 0;
}

sub _yaml_split_flow {
    my ($s) = @_;
    my @parts;
    my ( $cur, $depth, $q ) = ( '', 0, '' );
    for my $ch ( split //, $s ) {
        if ($q)                          { $cur .= $ch; $q = '' if $ch eq $q; next }
        if ( $ch eq '"' || $ch eq "'" )  { $q = $ch; $cur .= $ch; next }
        if ( $ch eq '{' || $ch eq '[' )  { $depth++; $cur .= $ch; next }
        if ( $ch eq '}' || $ch eq ']' )  { $depth--; $cur .= $ch; next }
        if ( $ch eq ',' && $depth == 0 ) { push @parts, $cur; $cur = ''; next }
        $cur .= $ch;
    }
    push @parts, $cur if $cur =~ /\S/;
    return @parts;
}

sub _yaml_value {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    if ( $s =~ /^\{(.*)\}$/s ) {
        my %h;
        for my $pair ( _yaml_split_flow($1) ) {
            next unless $pair =~ /^\s*(.+?)\s*:\s*(.*)$/s;
            $h{ _yaml_scalar($1) } = _yaml_value($2);
        }
        return \%h;
    }
    if ( $s =~ /^\[(.*)\]$/s ) {
        return [ map { _yaml_value($_) } _yaml_split_flow($1) ];
    }
    return _yaml_scalar($s);
}

# Recursive block parser over [indent, text] tokens.
sub _yaml_block {
    my ( $toks, $i, $ind ) = @_;
    return undef if $$i > $#$toks || $toks->[$$i][0] < $ind;
    my $first = $toks->[$$i][1];

    if ( $first =~ /^-(?:\s|$)/ ) {    # sequence
        my @seq;
        while ( $$i <= $#$toks
            && $toks->[$$i][0] == $ind
            && $toks->[$$i][1] =~ /^-(?:\s|$)/ )
        {
            ( my $rest = $toks->[$$i][1] ) =~ s/^-\s*//;
            my @sub;
            push @sub, [ $ind + 2, $rest ] if length $rest;
            $$i++;
            while ( $$i <= $#$toks && $toks->[$$i][0] > $ind ) {
                push @sub, $toks->[$$i];
                $$i++;
            }
            my $j = 0;
            push @seq, _yaml_block( \@sub, \$j, $ind + 2 );
        }
        return \@seq;
    }

    # SM940: a wholly quoted line is a SCALAR, and that has to be decided before
    # the mapping test below, which splits on the first colon. The sequence branch
    # above strips the `- ` and recurses, so `- 'https://github.com/x'` arrives
    # here as a bare quoted string and was read as a mapping - key `'https`, value
    # `//github.com/x'`. The flow form was always correct, because _yaml_split_flow
    # tracks quote state; these two paths now agree.
    if ( _yaml_quoted_scalar_line($first) ) {
        $$i++;
        return _yaml_scalar($first);
    }

    if ( $first !~ /^[\[{]/ && $first =~ /^(.+?)\s*:\s*(.*)$/ ) {    # mapping
        my %map;
        while ( $$i <= $#$toks && $toks->[$$i][0] == $ind ) {
            my $line = $toks->[$$i][1];
            last if $line =~ /^-(?:\s|$)/;
            # SM940, the same question inside the loop: a quoted scalar at mapping
            # indent is not a `key: value` pair and must not be accumulated as one.
            last if $line     =~ /^(["'])/ && _yaml_quoted_scalar_line($line);
            last unless $line =~ /^(.+?)\s*:\s*(.*)$/;
            my ( $k, $v ) = ( _yaml_scalar($1), $2 );
            $$i++;
            if ( defined $v && $v =~ /\S/ ) {
                $map{$k} = _yaml_value($v);
            }
            elsif ( $$i <= $#$toks && $toks->[$$i][0] > $ind ) {
                $map{$k} = _yaml_block( $toks, $i, $toks->[$$i][0] );
            }
            else { $map{$k} = undef }
        }
        return \%map;
    }

    my $v = _yaml_value($first);    # bare scalar / flow
    $$i++;
    return $v;
}

sub _parse_sections {
    my ($block) = @_;
    my @toks;
    for my $line ( split /\n/, $block ) {
        next if $line !~ /\S/;
        next if $line =~ /^\s*#/;
        my ($lead) = $line =~ /^(\s*)/;
        ( my $expanded = $lead ) =~ s/\t/    /g;
        ( my $text     = $line ) =~ s/^\s+//;
        $text =~ s/\s+$//;
        push @toks, [ length $expanded, $text ];
    }
    return [] unless @toks;
    my $i    = 0;
    my $data = _yaml_block( \@toks, \$i, $toks[0][0] );
    return ref $data eq 'ARRAY' ? $data : [];
}

# SM980 (ruled 2026-10-11, "Parse it + fail closed"): THE ACCESS KEYS, READ ONE
# WAY. `auth`, `auth_groups` and `payment` decide who gets a page; each was read
# by a regex that took one spelling, and a value spelt any other way was not
# read at all - which for a restriction means it did not apply:
#
#   auth_groups: [a, b]    the YAML flow list - no groups, any signed-in user in
#   auth: "required"       quoted - (\w+) saw no word, the page went public
#   payment: "required"    quoted or capitalised - not 'required', served free
#
# This reads what the author meant where YAML is unambiguous (a flow or block
# list, one level of quotes, any case, a trailing comment) and answers
# `unreadable => { key => why }` for anything else, which check_auth turns into a
# 403 for everyone. Never a guess: a single bare name is a string to YAML, not a
# list, and an empty list names nobody - both refused, saying what to write.
#
# $fm is the front-matter text. Returns { auth, auth_groups, payment,
# unreadable }; a key that is absent is undef and unreadable says nothing of it.
#
# SM993 (ruled 2026-10-12, Findings 3+4, "Fix both as recommended"): $where
# says where the page is, when the caller knows - 'manager' for a page under the
# manager path, 'content' for any other. `auth: manager` is enforced only by
# the manager path's own gate; on a content page it enforced nothing (served to
# anonymous visitors), so there it is UNREADABLE and the page is refused to
# everyone. A caller that does not know ($where undef - the gate's peek, keyed
# by file) reads it as before and check_auth, which has the URI, applies this
# by asking the reader again with 'content'.
#
# MARKED COPY (ADR 0001): Lazysite::Validate::read_access_keys is this reading
# for `lazysite validate` and validate_page, which cannot load the processor.
# t/lint/220 runs both over the same texts. Change one, change both.
sub _access_keys_read {
    my ( $fm, $where ) = @_;
    my %out   = ( unreadable => {} );
    my @lines = split /\r?\n/, ( $fm // '' );
    my $NAME  = qr/\A[A-Za-z0-9_.-]+\z/;
    my $clean = sub {
        my ($v) = @_;
        $v //= '';
        $v =~ s/\s+#.*\z//;
        $v =~ s/\A\s+|\s+\z//g;
        $v =~ s/\A"(.*)"\z/$1/ or $v =~ s/\A'(.*)'\z/$1/;
        return $v;
    };
    my %seen;
    for ( my $i = 0; $i < @lines; $i++ ) {
        my $line = $lines[$i];
        next unless $line =~ /\A(auth|auth_groups|payment)[ \t]*:(.*)\z/i;
        my ( $key, $rest ) = ( lc $1, $2 );
        if ( $seen{$key}++ ) {
            $out{unreadable}{$key} = "'$key' is given more than once";
            next;
        }
        if ( $key eq 'auth' || $key eq 'payment' ) {
            my $v = lc $clean->($rest);
            my @ok = $key eq 'auth' ? qw(required optional none manager) : qw(required none);
            if ( $key eq 'auth' && $v eq 'manager' && defined $where && $where ne 'manager' ) {
                $out{unreadable}{auth} = "'auth: manager' applies only to the manager's own pages - "
                    . 'on this page it enforces nothing; write auth: required (and auth_groups to name who)';
            }
            elsif ( grep { $_ eq $v } @ok ) { $out{$key} = $v }
            else {
                $out{unreadable}{$key} = length $v
                    ? "'$key: $v' is not one of " . join( ', ', @ok )
                    : "'$key' has no value - write one of " . join( ', ', @ok );
            }
            next;
        }

        # auth_groups: an inline value, or the indented `- name` lines below it.
        my $inline = $rest;
        $inline =~ s/\s+#.*\z//;
        $inline =~ s/\A\s+|\s+\z//g;
        my ( @items, $stray );
        # Indented lines, and `- name` lines at the key's own column (valid YAML).
        while ( $i + 1 < @lines && $lines[ $i + 1 ] =~ /\A(?:[ \t]|-(?:[ \t]|\z))/ ) {
            my $next = $lines[ ++$i ];
            next if $next =~ /\A\s*(?:#.*)?\z/;
            if ( $next =~ /\A[ \t]*-[ \t]*(.*)\z/ ) { push @items, $1 }
            else                                    { $stray = 1 }
        }
        my ( @names, $why );
        if ( length $inline ) {
            if ( @items || $stray ) { $why = 'has a value on its line and an indented list below it' }
            elsif ( $inline =~ /\A\[(.*)\]\z/ ) {
                my $inner = $1;
                if ( $inner =~ /\A\s*\z/ ) { $why = 'is an empty list - it names no group' }
                else { @names = map { $clean->($_) } split /,/, $inner, -1 }
            }
            else {
                $why = "is one value, not a list - write [$inline] or a '- $inline' line below it";
            }
        }
        elsif ($stray) { $why = 'has an indented line below it that is not a list item' }
        elsif (@items) { @names = map { $clean->($_) } @items }
        else           { $why   = 'has no value - it names no group' }
        if ( !defined $why ) {
            my ($bad) = grep { $_ !~ $NAME } @names;
            $why = length( $bad // '' )
                ? "'$bad' is not a group name (letters, digits, '.', '_' or '-')"
                : 'has an empty entry'
                if defined $bad;
        }
        if   ( defined $why ) { $out{unreadable}{auth_groups} = "'auth_groups' $why" }
        else                  { $out{auth_groups}             = \@names }
    }
    return \%out;
}

sub parse_yaml_front_matter {
    my ($text) = @_;
    my %meta;

    if ( $text =~ s/\A---\s*\n(.*?)\n---\s*\n//s ) {
        my $yaml = $1;

        # Parse register list (- item lines)
        if ( $yaml =~ /^register\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @registries;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @registries, strip_tt_directives($1);
            }
            $meta{register} = \@registries;
        }

        # SM483: FLOW-STYLE too - `register: [sitemap.xml, llms.txt]`. The MCP
        # writer emitted exactly this shape while only the block form parsed,
        # so every MCP-created page was invisible to every registry while
        # list_pages echoed its registers back as though registered. The
        # writer is fixed to emit block style; this heals the pages already
        # deployed in the field.
        elsif ( $yaml =~ /^register\s*:\s*\[([^\]\n]*)\]/m ) {
            my @registries = grep { length }
                map { my $v = $_; $v =~ s/^\s+|\s+$//g; $v =~ s/^["']|["']$//g; strip_tt_directives($v) }
                split /,/, $1;
            $meta{register} = \@registries if @registries;
        }

        # Parse tt_page_var block (indented key: value pairs)
        # The alternation (?:\n|$) handles the last line which may have no
        # trailing newline if it is the final line of the front matter block
        if ( $yaml =~ /^tt_page_var\s*:\s*\n((?:[ \t]+\S[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my %tt_vars;
            while ( $block =~ /^[ \t]+(\w+)\s*:\s*(.+)$/mg ) {
                $tt_vars{$1} = $2;
            }
            $meta{tt_page_var} = \%tt_vars;
        }

        # Parse tags list (- item lines)
        if ( $yaml =~ /^tags\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @tags;
            while ( $block =~ /^[ \t]*-[ \t]*(.+?)[ \t]*$/mg ) {
                push @tags, strip_tt_directives($1);
            }
            $meta{tags} = \@tags;
        }

        # SM980: auth_groups is read by the gate's own reader (auth.pm,
        # _access_keys_read) - the block list and the flow list `[a, b]` alike.
        # One that cannot be read is no list here; the gate refuses the page.
        {
            my $ak = _access_keys_read($yaml);
            $meta{auth_groups} = $ak->{auth_groups} if ref $ak->{auth_groups} eq 'ARRAY';
        }

        # Parse query_params list (- item lines)
        if ( $yaml =~ /^query_params\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @params;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @params, $1;
            }
            $meta{query_params} = \@params;
        }

        # D035 Phase 3: parse the nested `sections:` block (data-driven pages).
        # Captures indented/blank lines after `sections:` up to the next
        # column-0 key, then hands them to the minimal nested-YAML parser.
        if ( $yaml =~ /^sections\s*:[ \t]*\n((?:[ \t]+\S[^\n]*\n?|[ \t]*\n)*)/m ) {
            my $parsed = _parse_sections($1);
            $meta{sections} = $parsed if @$parsed;
        }

        # Parse scalar key: value pairs (skip tt_page_var, register, query_params blocks)
        while ( $yaml =~ /^(\w+)\s*:\s*([^\n]+)$/mg ) {
            next if $1 eq 'tt_page_var';
            next if $1 eq 'register';
            next if $1 eq 'query_params';
            next if $1 eq 'sections'; # nested block; parsed above (and \s* here would eat its first line)
            next if $1 eq 'tags'        && ref $meta{tags} eq 'ARRAY';
            next if $1 eq 'auth_groups';    # SM980: a list, read above, or none
            # Strip TT directives from all scalar values including title and subtitle
            my ( $k, $v ) = ( $1, strip_tt_directives($2) );
            # YAML quoting: a matched pair of surrounding quotes is syntax, not
            # content - strip one level so `title: "Welcome"` yields Welcome (not
            # a literal "Welcome" that a template then double-quotes).
            $v =~ s/\s+\z//;
            $v =~ s/\A"(.*)"\z/$1/s or $v =~ s/\A'(.*)'\z/$1/s;
            $meta{$k} = $v;
        }

        # P12/P13: any other key whose value is a YAML list is a list.
        _front_matter_lists( $yaml, \%meta );

        # Sanitise auth value
        if ( defined $meta{auth} ) {
            $meta{auth} = lc( $meta{auth} );
            $meta{auth} = 'none'
                unless $meta{auth} =~ /^(required|optional|none)$/;
        }

        # Sanitise form name
        #
        # SM976 Q15f: WHICH FORM A PAGE BINDS IS READ HERE, and nowhere else
        # decides it differently. Lazysite::Manager::Common::page_form is a
        # MARKED COPY of this reading - the block above, the scalar loop and
        # this sanitiser - for the manager's form rule, which cannot load the
        # processor; t/lint/219 runs both over the same texts. Change one, change
        # both.
        if ( defined $meta{form} ) {
            $meta{form} =~ s/[^a-zA-Z0-9_-]//g;
            delete $meta{form} unless length $meta{form};
        }
    }

    return ( \%meta, $text );
}

# P12/P13 (WORK-PLAN-0154, ruled 2026-10-12 "Full front matter + general
# lists"): A YAML LIST IS A LIST, whatever its key. Only `tags` (and the
# engine's own register, auth_groups, query_params) was read as one;
# `categories:` with `- item` lines reached the scan as the raw text
# `- "Perl Foundation"`, because the scalar loop's `\s*` runs on to the next
# line.
#
# Two shapes, read where YAML is unambiguous and nowhere else:
#   key: [a, "b c", d]       a flow list of scalars (quotes stripped, one level)
#   key:                     a block list: every line below it, until the next
#     - a                    key, is a `- item` at one indent (the key's own
#     - "b c"                column is valid YAML too); blank and comment lines
#                            are allowed between items
# An item that is itself a mapping (`- name: x`), a nested list, or a block with
# any other line in it is not a list of scalars: the key is left as the scalar
# loop read it, as before. An empty flow list `[]` is an empty list.
#
# THE ENGINE'S KEYS ARE NOT TOUCHED (_front_matter_engine_keys): each has its
# own reading, and the access keys (auth, auth_groups, payment) belong to the
# gate's reader - a list where the engine expects one scalar would change what
# a page does rather than what it says. A key already read as a list (tags) is
# left as read.
sub _front_matter_engine_keys {
    return { map { $_ => 1 } qw(
            auth auth_groups payment form register tt_page_var sections query_params
            layout theme title subtitle meta_title meta_desc date search
            api raw content_type ttl redirect lang ) };
}

sub _front_matter_list_item {
    my ($v) = @_;
    $v //= '';
    $v =~ s/\A\s+|\s+\z//g;
    $v =~ s/\A"(.*)"\z/$1/s or $v =~ s/\A'(.*)'\z/$1/s;
    return strip_tt_directives($v);
}

sub _front_matter_lists {
    my ( $yaml, $meta ) = @_;
    my $engine = _front_matter_engine_keys();
    my @lines  = split /\n/, $yaml;
    for ( my $i = 0; $i < @lines; $i++ ) {
        next unless $lines[$i] =~ /\A(\w+)[ \t]*:[ \t]*(.*?)[ \t]*\z/;
        my ( $k, $v ) = ( $1, $2 );
        next if $engine->{$k} || ref $meta->{$k};
        if ( length $v ) {
            next unless $v =~ /\A\[(.*)\]\z/s;
            my @raw = _yaml_split_flow($1);
            next if grep { /\A\s*[\[{]/ } @raw;    # nested: not a list of scalars
            $meta->{$k} = [ map { _front_matter_list_item($_) } @raw ];
            next;
        }
        my ( @items, $indent );
        my $simple = 1;
        my $j      = $i + 1;
        while ( $j < @lines ) {
            my $l = $lines[$j];
            if ( $l =~ /\A\s*(?:#.*)?\z/ ) { $j++; next }
            last if $l =~ /\A\w+[ \t]*:/;          # the next key
            if ( $l =~ /\A([ \t]*)-(?:[ \t]+(.*?))?[ \t]*\z/ ) {
                my ( $lead, $item ) = ( $1, $2 // '' );
                $indent //= $lead;
                $simple = 0 if $lead ne $indent || $item =~ /\A[\w-]+[ \t]*:(?:[ \t]|\z)/ || $item =~ /\A[\[{-]/;
                push @items, $item;
                $j++;
                next;
            }
            $simple = 0;                           # an indented line that is not an item
            last;
        }
        next unless $simple && @items;
        $meta->{$k} = [ grep { length } map { _front_matter_list_item($_) } @items ];
    }
    return;
}

1;
