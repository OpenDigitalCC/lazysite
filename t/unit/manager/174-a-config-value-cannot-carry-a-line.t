#!/usr/bin/perl
# SM838: a line break in an extension setting cannot add a line to the config.
#
# Found while building SM802, then REPRODUCED before it was fixed: one
# plugin-save to the Logging extension with
#
#   log_level => "INFO\nalias.victim.example.allowed_groups: attackers"
#
# wrote both lines into lazysite.conf. The allowlist checked the KEY and never
# the value, and every value is written as `key: value` on a line of its own.
# plugin-save needs manage_config; allowed_groups is behind manage_domains AND
# manage_users by the SM647 ruling - so this crossed a ruled boundary, and the
# same line break injects any key at all.
#
# Driven against a REAL shipped extension in an isolated tree, because the path
# that writes lazysite.conf is the one that matters and it only runs for an
# extension declaring config_keys.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Manager::Plugins ();

my $root   = repo_root();
my $parent = site_tempdir();    # lint 118: not a bare tempdir
my $d      = "$parent/public_html";
make_path( "$d/lazysite", "$parent/plugins" );
copy( "$root/plugins/log.pl", "$parent/plugins/log.pl" ) or die $!;
chmod 0755, "$parent/plugins/log.pl";
local $ENV{PERL5LIB} = "$root/lib" . ( $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '' );

my $conf = "$d/lazysite/lazysite.conf";
sub reset_conf { open my $c, '>', $conf or die $!; print {$c} "site_name: T\n"; close $c }
sub conf       { open my $h, '<', $conf or return ''; local $/; return <$h> }
$Lazysite::Manager::Plugins::DOCROOT = $d;

sub save { return Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/log.pl', {@_} ) }

# --- THE CANARY -------------------------------------------------------------
# A refusal test passes against a save that writes nothing at all, so first prove
# an ordinary value lands.
reset_conf();
{
    my $r = save( log_level => 'DEBUG' );
    ok( $r->{ok}, 'an ordinary value saves' ) or diag( $r->{error} // '' );
    like( conf(), qr/^log_level: DEBUG$/m, '...and is written to lazysite.conf' );
}

# --- THE FINDING ------------------------------------------------------------
for my $brk ( [ "\n", 'a newline' ], [ "\r", 'a carriage return' ], [ "\r\n", 'a CRLF' ] ) {
    reset_conf();
    my ( $sep, $what ) = @$brk;
    my $r = save( log_level => "INFO${sep}alias.victim.example.allowed_groups: attackers" );
    ok( !$r->{ok}, "a value containing $what is refused" );
    is( $r->{field} // '', 'log_level', '...naming the setting' );
    unlike( conf(), qr/allowed_groups/, '...and nothing reaches lazysite.conf' )
        or diag "lazysite.conf now:\n" . conf();
}

# A refusal of one value must not leave the others half-written.
reset_conf();
{
    my $r = save( log_format => 'json', log_level => "INFO\nx: y" );
    ok( !$r->{ok}, 'a save with one bad value is refused as a whole' );
    unlike( conf(), qr/^log_format: json$/m, '...and its good value was not written either' );
}

done_testing();
