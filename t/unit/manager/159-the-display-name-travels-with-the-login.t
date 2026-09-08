#!/usr/bin/perl
# SM778: THE ENGINE HOLDS THE NAMES AND HANDS BACK LOGINS.
#
# Reported from familyhq.explore: a site rendering bylines had no route from a
# login to a display name except for its own viewer, so it mirrored the names
# of the account-holders into its own table - and the mirror drifted, until
# every byline on the site read as a bare login.
#
# The ruling narrowed it: a person who never signs in is app data, and stays in
# the app's table. What is platform is the ACCOUNT-HOLDERS' names, which the
# engine already has.
#
# Two things are asserted here. First, the display name travels beside the
# login WHEREVER a login is handed back - one shape (`display_names`), added
# without disturbing any existing key, so nothing that reads these responses
# today has to change. Second, `display-names` resolves logins a caller
# already holds, with no capability beyond being signed in - and is NOT a
# listing: it answers for what it is given and nothing else.
#
# SM784 rides along: `display_names_readable` is the fourth state. An absent
# entry means "no name set" when it is true and "could not tell" when it is
# false, and those must not arrive at a page as one sentence.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps site_tempdir);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}
sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = site_tempdir();
make_path("$d/lazysite/auth");
make_path("$d/lazysite/layouts/base/themes/live");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "layout: base\ntheme: live\ncontrol_api_enabled: true\n";
close $cf;
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"admins":{"label":"Admins","ui":1,"manage_users":1}}';
close $gsf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf 'sekret' x 6, "\n";
close $sf;

# Three accounts whose LOGINS are the problem: a roster of these tells nobody
# who is who, which is the report in one line.
uapi( $d, { action => 'add', username => 'sjm',     password => 'x' } );
uapi( $d, { action => 'add', username => 'sm2',     password => 'x' } );
uapi( $d, { action => 'add', username => 'nonamer', password => 'x' } );
grant_caps( $d, 'sjm', 'manage_content', 'api' );
uapi( $d, { action => 'settings-set', username => 'sjm', key => 'display_name', value => 'Steve Morris' } );
uapi( $d, { action => 'settings-set', username => 'sm2', key => 'display_name', value => 'Sam Morris' } );
# A token client, which is the channel the report came in on: the site
# renders bylines from a connector, not from a manager session.
my $tok = uapi( $d, { action => 'token', username => 'sjm' } )->{token};
# The account roster is the manager UI's screen, served only over a cookie
# session - so the two listing assertions below ask as an operator.
uapi( $d, { action => 'add',       username => 'op', password => 'x' } );
uapi( $d, { action => 'group-add', username => 'op', group    => 'admins' } );
my $auth = basic( 'sjm', $tok );

subtest 'display-names resolves the logins it is given, and only those' => sub {
    my $r = mapi( $d, REQUEST_METHOD => 'POST',
        QUERY_STRING       => 'action=display-names',
        HTTP_AUTHORIZATION => $auth,
        body               => encode_json( { logins => [ 'sjm', 'nonamer' ] } ) );
    ok( $r->{ok}, 'the call is answered' ) or diag encode_json($r);
    is( $r->{display_names}{sjm}, 'Steve Morris', 'the name that goes with the login' );
    ok( !exists $r->{display_names}{nonamer},
        'an account with no name set has NO entry - the caller renders the login, as before' );
    ok( !exists $r->{display_names}{sm2},
        'and a login that was not asked about is absent: this resolves, it does not list' );
    ok( $r->{display_names_readable}, 'the store was readable, so an absent entry means unset' );
};

subtest 'the query form works, so a plain GET resolves a page of logins' => sub {
    my $r = mapi( $d,
        QUERY_STRING       => 'action=display-names&logins=sjm,sm2',
        HTTP_AUTHORIZATION => $auth );
    ok( $r->{ok}, 'answered over GET' ) or diag encode_json($r);
    is_deeply( $r->{display_names}, { sjm => 'Steve Morris', sm2 => 'Sam Morris' },
        'a comma-separated list resolves the same way the body array does' );
};

subtest 'it needs no capability beyond being signed in' => sub {
    # `nonamer` holds nothing at all - not manage_content, not manage_users.
    uapi( $d, { action => 'settings-set', username => 'nonamer', key => 'display_name', value => 'No Name' } );
    grant_caps( $d, 'nonamer', 'api' );    # the channel, and nothing else
    my $r = mapi( $d, REQUEST_METHOD => 'POST',
        QUERY_STRING       => 'action=display-names',
        HTTP_AUTHORIZATION => basic( 'nonamer',
            uapi( $d, { action => 'token', username => 'nonamer' } )->{token} ),
        body => encode_json( { logins => ['sjm'] } ) );
    ok( $r->{ok}, 'an account holding no capability may resolve a login it has' )
        or diag encode_json($r);
    is( $r->{display_names}{sjm}, 'Steve Morris', 'and gets the name' );
};

subtest 'an absent logins list is named as absent, not answered' => sub {
    # SM773 answers this before the branch, from the declaration.
    my $r = mapi( $d, REQUEST_METHOD => 'POST',
        QUERY_STRING       => 'action=display-names',
        HTTP_AUTHORIZATION => $auth,
        body               => encode_json( {} ) );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/^logins is required/, 'and named' );
    is( $r->{field}, 'logins', 'with the field a machine can read' );
};

subtest 'one call cannot be turned into a walk of the account store' => sub {
    my $r = mapi( $d, REQUEST_METHOD => 'POST',
        QUERY_STRING       => 'action=display-names',
        HTTP_AUTHORIZATION => $auth,
        body               => encode_json( { logins => [ ('a') x 201 ] } ) );
    ok( !$r->{ok}, 'a list beyond the cap is refused' );
    like( $r->{error}, qr/200 at most/, 'and the cap is stated' );
};

# These are the MANAGER's screens - principals and the account roster are both
# served only over a cookie session, which is the other half of why the report
# was made: the site that needed the names is a token client and could not have
# called either of them. It calls display-names instead.
subtest 'the name travels beside the login wherever one is handed back' => sub {
    my $p = mapi( $d,
        QUERY_STRING         => 'action=principals',
        HTTP_X_REMOTE_USER   => 'op',
        HTTP_X_REMOTE_GROUPS => 'admins' );
    ok( $p->{ok}, 'principals answers' ) or diag encode_json($p);
    is( $p->{display_names}{sjm}, 'Steve Morris',
        'the permissions picker can tell two accounts apart' );
    ok( ref $p->{users} eq 'ARRAY' && grep( { $_ eq 'sm2' } @{ $p->{users} } ),
        'and the existing users list is untouched - nothing that reads it has to change' );

    my $u = mapi( $d,
        QUERY_STRING         => 'action=users&sub=list',
        HTTP_X_REMOTE_USER   => 'op',
        HTTP_X_REMOTE_GROUPS => 'admins' );
    is( $u->{display_names}{sjm}, 'Steve Morris',
        'the account roster names the accounts it lists' )
        or diag encode_json($u);
};

subtest 'a group listing names its members' => sub {
    uapi( $d, { action => 'group-add', username => 'sm2', group => 'admins' } );
    my $g = mapi( $d,
        QUERY_STRING         => 'action=users&sub=groups',
        HTTP_X_REMOTE_USER   => 'op',
        HTTP_X_REMOTE_GROUPS => 'admins' );
    is( $g->{display_names}{sm2}, 'Sam Morris',
        'a member of a group is named, so the roster is readable' )
        or diag encode_json($g);
};

# SM784, the half that a map alone cannot carry: an absent entry has TWO
# meanings and the response has to say which. root searches every directory,
# so the fault cannot be staged as an unprivileged one there.
SKIP: {
    skip 'root searches every directory; this needs an unprivileged user', 2 if $> == 0;
    my $settings = "$d/lazysite/auth/user-settings.json";
    chmod 0000, $settings;
    my $unreadable = !-r $settings;
    chmod 0644, $settings unless $unreadable;
    skip 'this filesystem ignores the file mode', 2 unless $unreadable;

    my $r = mapi( $d, REQUEST_METHOD => 'POST',
        QUERY_STRING       => 'action=display-names',
        HTTP_AUTHORIZATION => $auth,
        body               => encode_json( { logins => ['sjm'] } ) );
    chmod 0644, $settings;

    ok( !$r->{display_names_readable},
        'an unreadable settings store says so rather than answering "nobody has a name"' )
        or diag encode_json($r);
    ok( !exists $r->{display_names}{sjm},
        'and the map is empty, which now means UNKNOWN rather than unset' );
}

done_testing;
