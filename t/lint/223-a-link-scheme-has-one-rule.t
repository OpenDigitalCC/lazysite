#!/usr/bin/perl
# P23 (WORK-PLAN-0154, ruled 2026-10-12): one rule for whether a link target's
# scheme may be a link, on both sides of ADR 0001.
#
# The render judges it in the processor's _url_safe_filter (`| url_safe`,
# SM970), and now in parse_nav. The writes - nav-save and set_nav, a nav file
# saved through Manager::Files or WebDAV, `lazysite validate` and
# `lazysite check` - judge it with Lazysite::Util::unsafe_link_scheme, a marked
# copy, because the render path loads nothing from lib/. Two copies of one rule
# drift; this runs both over the same texts, including the spellings a
# hand-rolled check gets wrong, and requires the same answer: the copy calls a
# value unsafe exactly when the filter would not pass it through unchanged.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(load_processor setup_minimal_site site_tempdir);
use Lazysite::Util ();

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

my @TEXTS = (
    '',                    '/', '/about', 'about', '?q=1', '#top', '//cdn.example/x',
    'http://example.com',  'HTTPS://example.com', 'mailto:a@example.com', 'tel:+44',
    'javascript:alert(1)', 'JavaScript:alert(1)', ' javascript:alert(1)', "\tjavascript:x",
    "java\nscript:x", "java\tscript:x", 'data:text/html,x', 'vbscript:msgbox', 'file:///etc/passwd',
    'ftp://example.com', 'jav&#x61;script:x', 'jav&#97;script:x', 'javascript&colon;x',
    'javascript%3Ax', '%6Aavascript:x', 'jav&amp;#x61;script:x', 'a:b', 'x-y.z+w:1', '1abc:x',
    '/path:with:colons', 'https://example.com/?u=javascript:x', "\x00javascript:x",
    '&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;x',
    ( '%25' x 9 ) . '41',
);

for my $t (@TEXTS) {
    my $filtered = main::_url_safe_filter($t);
    my $unsafe   = Lazysite::Util::unsafe_link_scheme($t);
    ( my $show = $t ) =~ s/([\x00-\x1f])/sprintf '\\x%02x', ord $1/ge;
    is( ( defined $unsafe ? 1 : 0 ), ( $filtered ne $t ? 1 : 0 ),
        "the copy and the render agree on: '$show'" )
        or diag( 'render: ' . $filtered . '  copy: ' . ( $unsafe // 'safe' ) );
}

ok( defined Lazysite::Util::unsafe_link_scheme('javascript:x'), 'the copy refuses something (not vacuous)' );
ok( !defined Lazysite::Util::unsafe_link_scheme('/x'), 'and passes something' );

done_testing();
