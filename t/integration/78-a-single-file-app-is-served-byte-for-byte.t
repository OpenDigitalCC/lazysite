#!/usr/bin/perl
# SM265 phase 0: a single-file browser app is served BYTE-FOR-BYTE, including
# when an ACL store routes it through the engine.
#
# SM133 established that a .html with no .md or .url beside it is served
# verbatim, and t/integration/01 covers that it is served at all and that a .md
# shadows it. Neither asserts the property SM265 actually depends on: that the
# bytes come back UNCHANGED.
#
# That matters here more than it usually would. The Golden Link apps are single
# files - their own HTML, CSS and JavaScript in one document - and SM223 means
# that on any site with an ACL entry the file no longer goes out through the web
# server but through the engine, which is a program that inserts things into
# pages for a living: a layout, a theme, an admin bar, the footer credit. If any
# of that reached a raw .html, the app would break in a way that looks like the
# app's fault.
#
# So this asserts the negative: nothing is added, nothing is removed, nothing is
# rewritten - with and without an ACL store present.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_minimal_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);

# Deliberately hostile bytes: the things an engine might touch. A template
# directive that must NOT be interpolated, an entity that must not be decoded,
# a script block, and trailing whitespace that a rewriter would trim.
my $app = <<'APP';
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Studio</title>
<style>body{--x:[% not_a_variable %]}</style></head>
<body>
<div id="app" data-k="a&amp;b" data-lt="&lt;tag&gt;"></div>
<script>
var TPL = "[% auth_user %]";
var RE  = /\[%[\s\S]*?%\]/g;
console.log(TPL, RE, "é™");
</script>
</body></html>
APP

my $path = "$docroot/studio-app.html";
open my $fh, '>', $path or die $!;
print {$fh} $app;
close $fh;

my $on_disk = do {
    open my $in, '<', $path or die $!;
    local $/; <$in>;
};

sub body_of {
    my ($out) = @_;
    # CGI: headers, blank line, body.
    my ( undef, $body ) = split /\r?\n\r?\n/, $out, 2;
    return defined $body ? $body : '';
}

subtest 'served verbatim with no ACL store' => sub {
    my $out = run_processor( $docroot, '/studio-app.html' );
    like( $out, qr/Status: 200/, 'the app is served' ) or diag($out);

    my $body = body_of($out);
    is( $body, $on_disk, 'the bytes are IDENTICAL to what is on disk' );

    # The specific things that would silently break a single-file app.
    unlike( $body, qr/lazysite\.io/i,
        'no footer credit is injected into a raw .html' );
    unlike( $body, qr/ls-admin-bar/,
        'no admin bar is injected' );
    like( $body, qr/\Q[% auth_user %]\E/,
        'a template directive inside <script> is NOT interpolated' );
    like( $body, qr/data-k="a&amp;b"/,
        'an HTML entity is not decoded' );
};

subtest 'served verbatim with an ACL store present' => sub {
    # SM223: any ACL entry sends every static request through the engine, so a
    # deployed app on an ACL'd site takes this path. What is asserted here is
    # the ENGINE's behaviour in that state - that it adds nothing to a raw
    # .html when an ACL store exists.
    #
    # WHAT THIS DOES NOT PROVE, stated because the subtest's first title
    # claimed it: the harness invokes the processor directly, so every request
    # here already goes through the engine. It cannot demonstrate the web
    # server's routing DECISION. That is t/lint/31's job, which checks all ten
    # shipped front-end configs route an existing static to the engine when an
    # ACL store is present. The two together cover the path; neither covers it
    # alone.
    mkdir "$docroot/lazysite";
    mkdir "$docroot/lazysite/auth";
    open my $a, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$a} '{"read":{"/private/":["someone"]}}';
    close $a;

    my $out = run_processor( $docroot, '/studio-app.html' );
    like( $out, qr/Status: 200/, 'still served with an ACL store present' )
        or diag($out);

    my $body = body_of($out);
    is( $body, $on_disk,
        'the bytes are STILL identical when routed through the engine' );
};

done_testing();
