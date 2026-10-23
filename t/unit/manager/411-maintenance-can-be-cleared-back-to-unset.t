#!/usr/bin/perl
# SM1297 (O-1, edge walk of 0.16.1): THE MAINTENANCE SWITCH CAN BE CLEARED BACK TO
# UNSET. Switched on and then off through config-set, lazysite.conf read
# `maintenance: off` where it had been empty, and config-set refused the empty
# value ("maintenance must be 'on' or 'off'"), so the site could never again read
# like one that was never switched. Empty is now accepted, with the meaning of off:
# the site is open and `lazysite check` says nothing. The Config page's switch,
# turned off, sends the empty value.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root run_processor run_child);
use ManagerSession qw(new_site);
use PageScript     ();

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my $s = new_site( root => $root );
my $d = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'ops', [qw(ui manage_config maintenance_access)],
    [qw(ui manage_config maintenance_access)] );
sub conf { open my $f, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; return <$f> }
sub set { return $s->call( 'boss', 'config-set', body => { key => 'maintenance', value => $_[0] } ) }

subtest 'on, off, then cleared through config-set' => sub {
    ok( set('on')->{ok},  'on' );
    ok( set('off')->{ok}, 'off' );
    like( conf(), qr/^maintenance: off$/m, 'the key reads off' );
    my $r = set('');
    ok( $r->{ok}, 'empty is accepted' ) or diag explain $r;
    like( conf(), qr/^maintenance:[ \t]*$/m, '...and the key is unset again' );
    is( $s->call( 'boss', 'config-read' )->{config}{maintenance}, '', 'config-read says it is empty' );
    ok( set('  ')->{ok}, 'blank is empty too' );
    my $bad = set('yes please');
    ok( !$bad->{ok}, 'anything else is still refused' );
    like( $bad->{error} // '', qr/'on', 'off' or empty/, '...saying empty is allowed' );
};

subtest 'empty means off: the site is open and the check is quiet' => sub {
    open my $p, '>', "$d/hello.md" or die $!;
    print {$p} "---\ntitle: Hello\n---\nOPEN-FOR-BUSINESS\n";
    close $p;
    set('');
    my $out = run_processor( $d, '/hello' );
    like( $out, qr/OPEN-FOR-BUSINESS/, 'the page is served' );
    unlike( $out, qr/Status: 30[23]/, '...not sent to the maintenance page' );
    my $chk = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-check.pl", '--docroot', $d ],
        stderr => 'merge' )->{out};
    unlike( $chk, qr/IN MAINTENANCE|reads as OFF/, 'lazysite check says nothing about it' );
};

subtest 'the Config page\'s switch, off, sends the empty value' => sub {
    chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
    plan skip_all => 'node not installed' unless length $node && -x $node;
    my $src = PageScript::page_source("$root/starter/manager/config.md");
    my ($schema)  = $src =~ /(var SITE_SCHEMA = \[.*?\n\];)/s;
    my ($presets) = $src =~ /(var SERVICE_PRESETS = \{.*?\n\};)/s;
    ok( $schema && $presets, 'the page defines its schema' ) or return;
    my $fn  = PageScript::extract_function( $src, 'renderSiteForm', 'config.md' );
    my $dir = tempdir( CLEANUP => 1 );
    open my $js, '>', "$dir/p.js" or die $!;
    print {$js} "var location = { protocol: 'https:', host: 'x' }; var availableLayouts = [];\n"
        . "function esc(s) { return String(s); }\n$schema\n$presets\n$fn\n"
        . "['', 'off', 'on'].forEach(function (v) {\n"
        . "  var h = renderSiteForm({ maintenance: v });\n"
        . "  var m = h.match(/<input type=\"hidden\" name=\"maintenance\" id=\"cfg-maintenance\" value=\"([^\"]*)\">"
        . "<label class=\"mg-chk\"><input type=\"checkbox\" class=\"mg-toggle\"( checked)?[^>]*h\\.value=this\\.checked\\?'on':'([^']*)'/);\n"
        . "  console.log(JSON.stringify(m ? { v: v, hidden: m[1], checked: !!m[2], off: m[3] } : { v: v, missing: 1 }));\n"
        . "});\n";
    close $js;
    my $r = run_child( [ $node, "$dir/p.js" ], stderr => 'merge' );
    my %got;
    for my $l ( split /\n/, $r->{out} ) { my $o = eval { JSON::PP::decode_json($l) } or next; $got{ $o->{v} } = $o }
    is_deeply( $got{''},   { v => '',    hidden => '',   checked => JSON::PP::false, off => '' }, 'unset: off, and sends empty' )
        or diag $r->{out};
    is_deeply( $got{off},  { v => 'off', hidden => '',   checked => JSON::PP::false, off => '' }, 'off: shown off, and a save clears it' );
    is_deeply( $got{on},   { v => 'on',  hidden => 'on', checked => JSON::PP::true,  off => '' }, 'on: shown on; switched off it sends empty' );
};

done_testing;
