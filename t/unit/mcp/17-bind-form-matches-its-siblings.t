#!/usr/bin/perl
# SM421, then SM842: the surfaces agree about how a form is bound.
#
# SM421 made them agree by giving bind_form the inline delivery targets the
# control API and WebDAV already accepted. SM842 made them agree the other way:
# inline targets are gone from every surface, and a form names handlers and
# nothing else. The ruling that did it was the release manager's - forms call
# a handler, the handler may be a connector, the timer calls handlers too, one
# way to do it - and SM579's, that where site data goes is a conferral of its
# own (manage_connectors), which an inline webhook under manage_forms bypassed.
#
# What is asserted here is the MCP half of that contract: bind_form offers no
# inline target, says so, and binds through the SAME function the control
# API's form-targets-save calls - so a refusal on one surface is a refusal on
# the other by construction rather than by two implementations agreeing. The
# behaviour of that function is t/unit/lib/34's.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
plan skip_all => "no $mcp" unless -f $mcp;
my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };
my $api = do { open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!; local $/; <$fh> };

my ($bind) = $src =~ /\n    bind_form => \{(.*?)\n    \},\n/s;
ok( $bind, 'the bind_form tool is present' ) or BAIL_OUT('cannot find bind_form');

unlike( $bind, qr/\btarget\s*=>\s*\{/, 'its schema offers no inline target' );
like( $bind, qr/there is no inline target/i, 'and its description says so, and what to do instead' );
like( $bind, qr/save_handler/, 'naming the tool that creates a handler' );
like( $bind, qr/Lazysite::Handlers::action_form_targets_save\(/,
    'it binds through the handler contract' );
like( $api, qr/\$action eq 'form-targets-save'.*?Lazysite::Handlers::action_form_targets_save\(/s,
    'and so does the control API - one function, two doors' );

unlike( $src, qr/sub _inline_target_block|sub _write_form_conf/,
    'the inline-target writer and the whole-file form writer are gone' );

# The DAV door: a raw form config is shape-checked by the same contract.
my $dav = do { open my $fh, '<', "$root/lazysite-dav.pl" or die $!; local $/; <$fh> };
like( $dav, qr/Lazysite::Handlers::form_conf_problems\(/,
    'a form config PUT over WebDAV meets the same rules' );

done_testing();
