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

# --- SM121: compound groups (a group listed as a member of another group) -----
# 'admins' lists the GROUP 'editors' as a member, so every editor inherits the
# admin capabilities as well as their own.
w( "$auth/groups", "editors: ada\nadmins: editors\n" );
w( "$auth/groups-settings.json",
    encode_json( { editors => { manage_content => 1 },
        admins => { manage_config => 1, manage_users => 1 } } ) );
my $comp = caps_for('ada');
ok( $comp->{manage_content}, 'compound: keeps its own group capability' );
ok( $comp->{manage_config} && $comp->{manage_users},
    'compound: inherits the parent group capabilities (group-of-groups)' );

# Inheritance is transitive: g1 in g2 in g3.
w( "$auth/groups", "g1: ada\ng2: g1\ng3: g2\n" );
w( "$auth/groups-settings.json", encode_json( { g3 => { manage_themes => 1 } } ) );
ok( caps_for('ada')->{manage_themes}, 'compound: capabilities inherit transitively (3 levels)' );

# A membership cycle terminates (no hang) and still resolves both groups.
w( "$auth/groups", "cyc1: ada, cyc2\ncyc2: cyc1\n" );
w( "$auth/groups-settings.json",
    encode_json( { cyc1 => { manage_content => 1 }, cyc2 => { audit => 1 } } ) );
my $cyc = caps_for('ada');
ok( $cyc->{manage_content} && $cyc->{audit},
    'compound: a membership cycle resolves both groups without hanging' );

# A plain username member is still resolved normally (not mistaken for a group).
w( "$auth/groups", "team: ada, someuser\n" );
w( "$auth/groups-settings.json", encode_json( { team => { webdav => 1 } } ) );
ok( caps_for('ada')->{webdav} && caps_for('someuser')->{webdav},
    'a plain username member still resolves directly' );

done_testing;
