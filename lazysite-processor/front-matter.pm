package main;

# lazysite-processor/front-matter.pm - the processor's front-matter parser.
#
# HOLDS   parse_yaml_front_matter($text) -> ( \%meta, $body ): a page's front
#         matter as the render path reads it; and the minimal nested-YAML
#         parser behind `sections:` - _parse_sections, _yaml_block, _yaml_value,
#         _yaml_scalar, _yaml_split_flow, _yaml_quoted_scalar_line.
# OWNS    what a page's front matter means to the engine: process_md, the
#         include path and the registry scan all read it through this one parse.
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

        # Parse auth_groups list (- item lines)
        if ( $yaml =~ /^auth_groups\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @groups;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @groups, $1;
            }
            $meta{auth_groups} = \@groups;
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
            next if $1 eq 'auth_groups' && ref $meta{auth_groups} eq 'ARRAY';
            # Strip TT directives from all scalar values including title and subtitle
            my ( $k, $v ) = ( $1, strip_tt_directives($2) );
            # YAML quoting: a matched pair of surrounding quotes is syntax, not
            # content - strip one level so `title: "Welcome"` yields Welcome (not
            # a literal "Welcome" that a template then double-quotes).
            $v =~ s/\s+\z//;
            $v =~ s/\A"(.*)"\z/$1/s or $v =~ s/\A'(.*)'\z/$1/s;
            $meta{$k} = $v;
        }

        # Sanitise auth value
        if ( defined $meta{auth} ) {
            $meta{auth} = lc( $meta{auth} );
            $meta{auth} = 'none'
                unless $meta{auth} =~ /^(required|optional|none)$/;
        }

        # Sanitise form name
        if ( defined $meta{form} ) {
            $meta{form} =~ s/[^a-zA-Z0-9_-]//g;
            delete $meta{form} unless length $meta{form};
        }
    }

    return ( \%meta, $text );
}

1;
