#!/usr/bin/perl
# P23 (WORK-PLAN-0154, ruled 2026-10-12): the nav parser stored a `javascript:`
# URL as written, and every layout puts a nav entry's url in an href. At render
# an address whose scheme can run script - the `| url_safe` rule, SM970 - is
# shown as `#` and logged; a path, http(s), mailto: and tel: pass unchanged.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
local $ENV{LAZYSITE_LOG_LEVEL}           = 'INFO';

my $d = site_tempdir();
setup_minimal_site($d);
sub spit { my ( $p, $t ) = @_; open my $fh, '>:utf8', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/nav.conf", <<'NAV' );
# a comment
Home | /
Bad | javascript:alert(1)
Data | data:text/html;base64,PHNjcmlwdD4=
Docs | /docs
  Child bad | VBScript:msgbox(1)
  Entity | jav&#x61;script:alert(1)
  Mail | mailto:a@example.com
  Away | https://example.com/x
  Phone | tel:+441234
Empty
NAV

load_processor($d);

sub with_log {
    my ($code) = @_;
    my $log = "$d/stderr.log";
    open my $save, '>&', \*STDERR or die $!;
    open STDERR,   '>',  $log     or die $!;
    my @r   = eval { $code->() };
    my $err = $@;
    open STDERR, '>&', $save or die $!;
    open my $fh, '<',  $log  or die $!;
    my $text = do { local $/; scalar <$fh> } // q{};
    return ( $err, $text, @r );
}

my ( $err, $log, $nav ) = with_log( sub { main::parse_nav("$d/lazysite/nav.conf") } );
is( $err, '', 'parse_nav does not die' );
my %url = map { $_->{label} => $_->{url} } @$nav, map { @{ $_->{children} || [] } } @$nav;

is( $url{Bad},         '#',     'javascript: renders as #' );
is( $url{Data},        '#',     'data: renders as #' );
is( $url{'Child bad'}, '#',     'a child entry too, whatever the scheme\'s case' );
is( $url{Entity},      '#',     'and a scheme spelt with a character reference' );
is( $url{Home},        '/',     'a path passes' );
is( $url{Docs},        '/docs', 'a path passes' );
is( $url{Mail},        'mailto:a@example.com',  'mailto: passes' );
is( $url{Away},        'https://example.com/x', 'https: passes' );
is( $url{Phone},       'tel:+441234',           'tel: passes' );
is( $url{Empty},       '',                      'an entry with no address keeps none' );

my @warn = $log =~ /(\[WARN\] .*a nav entry whose address has an unsafe scheme is rendered as #.*)/g;
is( scalar @warn, 4, 'each neutralised entry is logged once' );
like( $log, qr/scheme=javascript\b.*label=Bad\b|label=Bad\b.*scheme=javascript\b/, 'naming the entry' );
like( $log, qr/nav=lazysite\/nav\.conf/, '...and the nav file, by its relative path' );
unlike( $log, qr{\Q$d\E}, '...and not the server path' );

done_testing();
