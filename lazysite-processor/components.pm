package main;

# lazysite-processor/components.pm - the processor's content components.
#
# HOLDS   convert_fenced_components($text, $layout_dir, $md_path, $meta): each
#         `::: <name>` fence naming a component (the layout's, else a built-in)
#         is rendered through components/<name>.tt with content, attrs and
#         slots; _render_component, _component_exists, _md_fragment (a
#         component's inner Markdown through the page's own fence passes).
# OWNS    what a component fence becomes on the page.
# CALLS   convert_fenced_divs, convert_fenced_include, convert_md, the
#         markdown/json/url_safe filters, log_event (lazysite-processor.pl);
#         Template (loaded by the script before its parts load).
# READS   $LAZYSITE_DIR (the script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S5). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ($LAZYSITE_DIR);

# --- Content components (D035 Phase 2) ------------------------------------
# A ::: <name> fence whose <name> matches components/<name>.tt under the active
# layout is rendered THROUGH that component: the inner Markdown becomes
# `content`, key="value" pairs on the opening line become `attrs`, and direct
# child ::: <slot> fences become `slots.<slot>`. Fence names with no matching
# component pass through untouched to convert_fenced_divs. Balanced (nesting-
# aware), and byte-preserving for everything that is not a component block.
sub _component_exists {
    my ( $layout_dir, $name ) = @_;
    return 0 unless defined $name   && $name =~ /\A[\w-]+\z/;
    return 1 if defined $layout_dir && -f "$layout_dir/components/$name.tt";
    # Built-in components (e.g. ::: qr) ship under lazysite/templates/components
    # and are available on ANY layout - a layout component of the same name wins.
    return 1 if -f "$LAZYSITE_DIR/templates/components/$name.tt";
    return 0;
}

sub _md_fragment {
    my ( $text, $layout_dir, $md_path, $meta ) = @_;
    return '' unless defined $text && $text =~ /\S/;
    $text .= "\n" unless $text =~ /\n\z/;    # fence closers need a trailing newline
        # Run the inner through the same fence passes as the page body, so a component
        # can contain nested components, fenced divs and includes - then Markdown.
    my $t = convert_fenced_components( $text, $layout_dir, $md_path, $meta );
    $t = convert_fenced_divs($t);
    $t = convert_fenced_include( $t, $md_path, $meta ) if defined $md_path;
    my $html = convert_md($t);
    $html =~ s/\A\s+//;
    $html =~ s/\s+\z//;
    return $html;
}

sub convert_fenced_components {
    my ( $text, $layout_dir, $md_path, $meta ) = @_;
    # Proceed if the active layout has a components/ dir OR built-in components
    # exist (::: qr and friends work even on a layout that ships none).
    return $text
        unless ( defined $layout_dir && -d "$layout_dir/components" )
        || -d "$LAZYSITE_DIR/templates/components";
    return $text unless $text =~ /^:::[ \t]+[\w-]+/m;    # fast bail

    my @lines = split /\n/, $text, -1;
    my @out;
    my $i = 0;
    while ( $i <= $#lines ) {
        my $l = $lines[$i];
        if ( $l =~ /^:::[ \t]+([\w-]+)[ \t]*(.*?)[ \t]*$/
            && _component_exists( $layout_dir, $1 ) )
        {
            my ( $name, $attr ) = ( $1, $2 );
            my @inner;
            my $depth = 1;
            my $j     = $i + 1;
            while ( $j <= $#lines && $depth > 0 ) {
                my $x = $lines[$j];
                if ( $x =~ /^:::[ \t]+\S/ ) { $depth++; push @inner, $x }
                elsif ( $x =~ /^:::[ \t]*$/ ) { $depth--; push @inner, $x if $depth > 0 }
                else                          { push @inner, $x }
                $j++;
            }
            if ( $depth != 0 ) {
                # GS11 (SM492): unbalanced - the fence stays in the page as text,
                # which is the visible symptom; the CAUSE is named here so the
                # build log says which component, on which body line.
                log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                    'component fence never closed', component => $name,
                    body_line => $i + 1, page => $md_path // '-' );
                push @out, $l;
                $i++;
                next;
            }
            push @out, _render_component( $layout_dir, $name, $attr,
                join( "\n", @inner ), $md_path, $meta );
            $i = $j;
        }
        else { push @out, $l; $i++; }
    }
    return join "\n", @out;
}

sub _render_component {
    my ( $layout_dir, $name, $attr_str, $inner, $md_path, $meta ) = @_;

    my %attrs;
    while ( $attr_str =~ /([\w-]+)\s*=\s*"([^"]*)"/g ) { $attrs{$1} = $2 }
    while ( $attr_str =~ /([\w-]+)\s*=\s*'([^']*)'/g ) { $attrs{$1} //= $2 }

    # Direct-child ::: <slot> fences whose name is NOT itself a component become
    # named slots; a child fence that IS a component (or any other content) goes
    # to content, where _md_fragment renders it (nested components).
    my ( %slots, @content_lines );
    my @il = split /\n/, $inner, -1;
    my $i  = 0;
    while ( $i <= $#il ) {
        my $l = $il[$i];
        if ( $l =~ /^:::[ \t]+([\w-]+)[ \t]*.*$/ ) {
            my $fence = $1;
            my @sb;
            my $depth = 1;
            my $j     = $i + 1;
            while ( $j <= $#il && $depth > 0 ) {
                my $x = $il[$j];
                if ( $x =~ /^:::[ \t]+\S/ ) { $depth++; push @sb, $x }
                elsif ( $x =~ /^:::[ \t]*$/ ) { $depth--; push @sb, $x if $depth > 0 }
                else                          { push @sb, $x }
                $j++;
            }
            if ( $depth == 0 ) {
                # A child fence that is itself a component, or a reserved built-in
                # (include/oembed/form), belongs to content so the pipeline renders
                # it; any other name is a named slot.
                if ( _component_exists( $layout_dir, $fence )
                    || $fence =~ /\A(?:include|oembed|form)\z/ )
                {
                    push @content_lines, $l, @sb, ':::';
                }
                else {
                    $slots{$fence} =
                        _md_fragment( join( "\n", @sb ), $layout_dir, $md_path, $meta );
                }
                $i = $j;
                next;
            }
        }
        push @content_lines, $l;
        $i++;
    }

    my $content =
        _md_fragment( join( "\n", @content_lines ), $layout_dir, $md_path, $meta );

    my $tt = Template->new(
        ABSOLUTE  => 1,
        EVAL_PERL => 0,
        # Layout components win; built-in components (lazysite/templates) are the
        # fallback so ::: qr resolves on any layout.
        INCLUDE_PATH => [ grep { defined } ( $layout_dir, "$LAZYSITE_DIR/templates" ) ],
        FILTERS      => {
            markdown => \&_markdown_filter,
            json     => \&_json_filter,
            url_safe => \&_url_safe_filter,    # SM970
        },
    );
    my $rendered = '';
    $tt->process( "components/$name.tt",
        { content => $content, attrs => \%attrs, slots => \%slots }, \$rendered )
        or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'component render failed',
            component => $name, error => $tt->error() );
        return "<!-- component '$name' failed to render -->";
        };
    $rendered =~ s/\s+\z//;
    return $rendered;
}

1;
