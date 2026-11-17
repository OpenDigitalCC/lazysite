#!/usr/bin/perl
# SM1399: THE TEMPLATE FILTERS CAN BE TESTED FROM OUTSIDE.
#
# A layouts catalogue renders its layouts in its own tests and wants the engine's real
# `| json` and `| url_safe`, not copies that drift. They are subs of a processor part
# (lazysite-processor/include.pm, package main). The layout reference now documents
# loading them by `require`-ing that file from an installed engine, with no -I and no
# site; this test is that documentation run:
#
#   1. the reference names the file and both subs;
#   2. the part, copied to a bare directory laid out as an installed engine and loaded
#      by a fresh perl with no @INC beyond the default, gives both filters, loads no
#      Lazysite:: module, and answers as the reference says;
#   3. a Template built with the two filters, as the reference shows, renders them.
#
# Reverting the documentation, renaming a sub, or giving the part a load-time dependency
# on the script or on lib/ fails it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();

# 1. the reference names it
my $doc = do {
    open my $fh, '<', "$root/starter/lazysite/templates/docs/layouts.md" or die "layouts.md: $!";
    local $/;
    <$fh>;
};
like( $doc, qr/^### Testing a layout against the engine's own filters$/m, 'the layout reference has the section' );
like( $doc, qr{require "[^"\n]*/lazysite-processor/include\.pm"}, '...naming the part to require' );
like( $doc, qr/\\&main::_json_filter/, '...and the json filter sub' );
like( $doc, qr/\\&main::_url_safe_filter/, '...and the url_safe filter sub' );

# 2. an installed engine: the part beside lazysite-processor.pl, nothing else
my $cgi = site_tempdir() . '/cgi-bin';
make_path("$cgi/lazysite-processor");
copy( "$root/lazysite-processor/include.pm", "$cgi/lazysite-processor/include.pm" ) or die "copy: $!";

my $probe = site_tempdir() . '/probe.pl';
open my $pf, '>', $probe or die $!;
print {$pf} <<'PERL';
use strict;
use warnings;
my ($engine) = @ARGV;
require "$engine/lazysite-processor/include.pm";
my @lz = grep { m{\ALazysite/} } keys %INC;
print "loaded=", scalar(@lz), "\n";
print "json=", main::_json_filter(q(a "q" </script> & b)), "\n";
print "json-undef=", main::_json_filter(undef), "\n";
print "url-js=", main::_url_safe_filter('javascript:alert(1)'), "\n";
print "url-entity=", main::_url_safe_filter('java&#115;cript:alert(1)'), "\n";
print "url-rel=", main::_url_safe_filter('/a/b?c=1#d'), "\n";
print "url-https=", main::_url_safe_filter('https://example.com/x'), "\n";
PERL
close $pf;

my $out = qx{cd / && perl $probe $cgi 2>&1};
is( $? >> 8, 0, 'a fresh perl requires the part from an installed-engine layout' ) or diag $out;
my %got = $out =~ /^([\w-]+)=(.*)$/mg;
is( $got{loaded}, 0, '...and it loads no Lazysite:: module (the render path stays free of the tree)' );
is( $got{json}, '"a \\"q\\" \\u003c/script\\u003e \\u0026 b"', 'json: quotes, </script> and & are escaped' );
is( $got{'json-undef'}, '""', 'json: an undefined value is the empty string' );
is( $got{'url-js'},     '#', 'url_safe: javascript: becomes #' );
is( $got{'url-entity'}, '#', 'url_safe: a scheme hidden in a character reference becomes #' );
is( $got{'url-rel'},    '/a/b?c=1#d', 'url_safe: a relative path passes unchanged' );
is( $got{'url-https'},  'https://example.com/x', 'url_safe: https passes unchanged' );

# 3. a Template with the two filters, as the reference shows it
SKIP: {
    skip 'Template Toolkit is not installed', 2 unless eval { require Template; 1 };
    require "$cgi/lazysite-processor/include.pm";
    my $tt = Template->new( FILTERS => {
        json     => \&main::_json_filter,
        url_safe => \&main::_url_safe_filter,
    } );
    my $res = '';
    ok( $tt->process( \q{<a href="[% u | url_safe %]">[% t %]</a><script>{"n":[% t | json %]}</script>}, { u => 'javascript:x', t => '</script>' }, \$res ),
        'a template with both filters renders' )
        or diag $tt->error;
    is( $res, '<a href="#"></script></a><script>{"n":"\u003c/script\u003e"}</script>', '...through the engine\'s own filters' );
}

done_testing;
