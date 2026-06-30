#!/usr/bin/perl
# SM095: the single capability resolver (Lazysite::Auth::Settings::caps_for) that
# the manager UI, control API, MCP and the WebDAV endpoint all consult.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Settings qw(caps_for);

my $d    = tempdir( CLEANUP => 1 );
my $auth = "$d/lazysite/auth";
make_path($auth);
$Lazysite::Auth::Settings::AUTH_DIR = $auth;

sub w { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

# ada is in content-team, which carries manage_content + webdav.
w( "$auth/groups", "content-team: ada\nempty:\n" );
w( "$auth/groups-settings.json",
    encode_json( { 'content-team' => { manage_content => 1, webdav => 1, manage_nav => 1 } } ) );

my $c = caps_for('ada');
ok( $c->{manage_content}, 'a group grant resolves: manage_content' );
ok( $c->{webdav},         'a group grant resolves: webdav' );
ok( $c->{manage_nav},     'a group grant resolves: manage_nav' );
ok( !$c->{manage_themes}, 'ungranted capability stays off' );
ok( !$c->{analytics},     'ungranted capability stays off (analytics)' );

# Compounding: a second group adds themes.
w( "$auth/groups", "content-team: ada\ndesign: ada\n" );
w( "$auth/groups-settings.json",
    encode_json( { 'content-team' => { manage_content => 1 },
                   'design'       => { manage_themes => 1, manage_layouts => 1 } } ) );
my $c2 = caps_for('ada');
ok( $c2->{manage_content} && $c2->{manage_themes} && $c2->{manage_layouts},
    'multiple groups compound (union of capabilities)' );

# Clean cut: a legacy per-user grant is NOT honoured - capabilities come from
# groups only.
w( "$auth/user-settings.json", encode_json( { bob => { analytics => 1 } } ) );
ok( !caps_for('bob')->{analytics}, 'a per-user grant is ignored (groups-only)' );

# An ungranted account has nothing.
my $none = caps_for('nobody');
ok( !$none->{webdav} && !$none->{manage_content}, 'an ungranted account has no capabilities' );

done_testing;
