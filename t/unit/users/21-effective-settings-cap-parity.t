#!/usr/bin/perl
# Every @CAP_KEYS capability must be SURFACED by effective_settings, or the grant
# is dormant: caps_for resolves it, but the cookie manager gate (_user_caps) and
# the Users page read effective_settings, so a cap missing from that map silently
# does nothing. This bit manage_domains / feedback / read_submissions (F3 audit,
# 2026-07) - a non-operator grant of them had no effect. Pins the two in sync so
# a newly added @CAP_KEYS entry cannot be forgotten in effective_settings.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper               qw(repo_root);
use Lazysite::Auth::Settings qw(@CAP_KEYS);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

# One user in a group carrying every capability.
uapi( { action => 'add', username => 'all', password => 'pw' } );
uapi( { action => 'group-add', username => 'all', group => 'everything' } );
uapi( { action => 'group-settings-set', group => 'everything', key => $_, value => 'on' } )
    for @CAP_KEYS;

my $s = uapi( { action => 'settings-get', username => 'all' } )->{settings} || {};

# The 'ui' capability (group-granted manager access) is surfaced under the name
# manager_ui (the bare 'ui' key is the separate interactive-login flag); every
# other capability keeps its name. All must be present.
for my $cap (@CAP_KEYS) {
    my $key = $cap eq 'ui' ? 'manager_ui' : $cap;
    ok( exists $s->{$key},
        "effective_settings surfaces capability '$cap'"
            . ( $cap eq 'ui' ? " (as manager_ui)" : '' ) );
}

done_testing();
