#!/usr/bin/perl
# SM1213 (n697's audit, SM1209): AN EMPTY FRONT-MATTER KEY READS AS EMPTY.
#
# The page front matter's scalar reader was `^(\w+)\s*:\s*([^\n]+)$` with /mg, in
# the renderer (lazysite-processor/front-matter.pm) and in its manager copy
# (Lazysite::Manager::Common::page_form); raw_html_page_refusal read api/raw and
# content_type the same way. The `\s*` after the colon runs over the newline, so
# a key with no value took the NEXT LINE as its value and that line's own key was
# lost:
#
#     title:                    title = 'subtitle: Hello'
#     subtitle: Hello           subtitle missing
#
# The value is confined to its own line now ([ \t]*:[ \t]*), an empty key is no
# value (a later empty key clears an earlier one, as YAML's null does), and the
# next key is read. The gate's reader (_access_keys_read) and the validator were
# line-based already; this runs every reader over the same texts so they agree.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);
use Lazysite::Manager::Common ();
use Lazysite::Validate        ();

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

sub render_meta {
    my ($fm) = @_;
    my $t = "---\n$fm---\nbody\n";
    utf8::upgrade($t);
    my ($meta) = main::parse_yaml_front_matter($t);
    return $meta;
}

subtest 'the renderer reads an empty key as no value and reads the next key' => sub {
    my @cases = (
        [ "title:\nsubtitle: Hello\nauth: required\n",   'empty' ],
        [ "title:   \nsubtitle: Hello\nauth: required\n", 'spaces after the colon' ],
        [ "title:\t\nsubtitle: Hello\nauth: required\n",  'a tab after the colon' ],
        [ "title :\nsubtitle: Hello\nauth: required\n",   'a space before the colon' ],
        [ "title:\r\nsubtitle: Hello\r\nauth: required\r\n", 'CRLF' ],
        [ "title:\n\nsubtitle: Hello\n\nauth: required\n", 'a blank line below it' ],
    );
    for my $c (@cases) {
        my ( $fm, $label ) = @$c;
        my $m = render_meta($fm);
        ok( !exists $m->{title}, "$label: the empty key has no value" )
            or diag( "title = '" . ( $m->{title} // '' ) . "'" );
        is( $m->{subtitle}, 'Hello',    "$label: the next key is read" );
        is( $m->{auth},     'required', "$label: and the one after it" );
    }

    # YAML's continuation: an INDENTED line below an empty key is its value
    # (SM976 Q15f binds `form:` / `  leads`); only a column-0 line is a key.
    my $c = render_meta("title:\n  continued\nsubtitle: Hello\n");
    is( $c->{title},    'continued', 'an indented line below an empty key is its continuation' );
    is( $c->{subtitle}, 'Hello',     '  ...and the key after it is read' );
    is( render_meta("form:\n\n  leads\n")->{form}, 'leads', '  ...past a blank line' );
    is( Lazysite::Manager::Common::page_form("---\nform:\n  leads\n---\n"),
        'leads', '  ...and the manager reads it the same' );

    my $m = render_meta("form: leads\nform:\n");
    ok( !exists $m->{form}, 'a later empty key clears an earlier value (YAML null)' );
    is( render_meta("title: \"\"\n")->{title}, '', 'a quoted empty value is an empty string' );
    is( render_meta("title: T\nsubtitle: S\n")->{title}, 'T', 'an ordinary key is unchanged' );
    ok( !exists render_meta("title: X\napi:\ntrue\n")->{api}, '`api:` with `true` below it is not api: true' );
    $m = render_meta("meta_desc:\nsubtitle: Sub\n");
    ok( !exists $m->{meta_desc}, 'an empty meta_desc is absent, so the description falls back to the subtitle' );
};

# The texts every reader is run over: an empty key above each key that decides
# what a page does.
my @AGREE = (
    "title:\nsubtitle: Hello\nauth: required\n",
    "title:\nauth: required\n",
    "title:\nauth: none\n",
    "subtitle:\nauth_groups: [admins]\n",
    "title:\nauth_groups:\n  - admins\n",
    "title:\npayment: required\n",
    "title:\naddresses: [office]\n",
    "title:\nform: leads\n",
    "form:\ntitle: T\n",
    "form: leads\nform:\n",
    "title:   \nsearch: false\n",
    "title:\r\nform: leads\r\nauth: required\r\n",
);

subtest 'the renderer, the manager, the validator and the gate agree' => sub {
    for my $fm (@AGREE) {
        ( my $label = $fm ) =~ s/\r/\\r/g;
        $label =~ s/\n/\\n/g;
        my $r = render_meta($fm);
        my $v = Lazysite::Validate::parse_front_matter($fm);
        for my $k (qw(title subtitle search)) {
            is( $r->{$k} // '', $v->{$k} // '', "$label: $k - renderer = validator" );
        }
        my $page = "---\n$fm---\nbody\n";
        is( Lazysite::Manager::Common::page_form($page), $r->{form}, "$label: form - manager = renderer" );
        my $gp = main::_access_keys_read($fm);
        my $gv = Lazysite::Validate::read_access_keys($fm);
        is_deeply( $gv, $gp, "$label: access keys - validator = gate" );
        is( $r->{auth} // '', $gp->{auth} // '', "$label: auth - renderer = gate" );
        is( $v->{auth} // '', $gp->{auth} // '', "$label: auth - validator = gate" );
        is( $r->{payment} // '', $gp->{payment} // '', "$label: payment - renderer = gate" );
    }
};

subtest 'search: false below an empty key keeps the page out of search' => sub {
    mkdir "$d/s147";
    for ( [ 'listed', "title: Listed\nsearch: true\n" ], [ 'unlisted', "title: Unlisted\ntag:\nsearch: false\n" ] ) {
        open my $fh, '>', "$d/s147/$_->[0].md" or die $!;
        print {$fh} "---\n$_->[1]---\nx\n";
        close $fh;
    }
    my %by = map { $_->{title} => $_ } @{ main::resolve_scan('/s147/*.md') };
    is( $by{Listed}{searchable},   1, 'search: true is searchable' );
    is( $by{Unlisted}{searchable}, 0, 'search: false under an empty key is not' );
};

subtest 'the manager refuses the raw HTML page the engine serves as raw' => sub {
    my $refused = sub { defined Lazysite::Manager::Common::raw_html_page_refusal( $_[0] ) ? 1 : 0 };
    is( $refused->("---\napi: true\ncontent_type: text/html\n---\nx\n"), 1, 'api: true + text/html (as before)' );
    is( $refused->("---\napi: true\ncontent_type:\ncontent_type: text/html\n---\nx\n"),
        1, 'an empty content_type above the real one does not hide it' );
    is( $refused->("---\napi: \"true\"\ncontent_type: text/html\n---\nx\n"), 1, 'api: "true" (quoted, as the renderer reads it)' );
    is( $refused->("---\nraw: 'true'\ncontent_type: \"text/html\"\n---\nx\n"), 1, "raw: 'true' + a quoted type" );
    is( $refused->("---\napi:\ntrue\ncontent_type: text/html\n---\nx\n"),
        0, '`api:` with `true` below it is not raw - the engine renders it through the layout' );
    is( $refused->("---\napi: true\ncontent_type: application/json\n---\nx\n"), 0, 'a data type is not refused' );
};

done_testing;
