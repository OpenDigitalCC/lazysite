#!/usr/bin/perl
# SM233: effective_settings surfaces `scope_ceiling` - the chain of ancestors
# currently capping an account's content access. The manager shows it beside the
# emancipation toggle, because without it an operator cannot tell whether the
# toggle would change anything, and no tooltip wording substitutes for showing
# the answer.
#
# It must walk exactly as Auth::Settings::resolve_user_scopes walks (created_by,
# stopping at a scope_independent account, cycle-guarded) or the manager would
# show a ceiling the enforcement does not apply, or hide one it does.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

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
sub ceiling_of {
    return uapi( { action => 'settings-get', username => $_[0] } )
        ->{settings}{scope_ceiling};
}

# alice (top level) -> bob -> carol, plus dave under bob. Sub-accounts must be
# created THROUGH account-create so the created_by provenance is stamped; a plain
# `add` makes a top-level account with no creator.
uapi( { action => 'add', username => 'alice', password => 'pw' } );
uapi( { action => 'group-settings-set', group => 'creators',
        key    => 'create_sub_users', value => 'on' } );
uapi( { action => 'group-add', username => 'alice', group => 'creators' } );
uapi( { action => 'account-create', username => 'bob', password => 'pw',
        created_by => 'alice' } );
# bob must itself hold create_sub_users before it can create carol/dave.
uapi( { action => 'group-add', username => 'bob', group => 'creators' } );
uapi( { action => 'account-create', username => 'carol', password => 'pw',
        created_by => 'bob' } );
uapi( { action => 'account-create', username => 'dave', password => 'pw',
        created_by => 'bob' } );

is_deeply( ceiling_of('alice'), [],
    'a top-level account is capped by nobody' );
is_deeply( ceiling_of('bob'), ['alice'],
    'a sub-account is capped by its creator' );
is_deeply( ceiling_of('carol'), [ 'bob', 'alice' ],
    'the ceiling follows the WHOLE creator chain, in walk order' );

# Emancipation empties the ceiling - that is the change the operator is making,
# and the manager must show it.
uapi( { action => 'account-scope-independent', username => 'carol', value => 1 } );
is_deeply( ceiling_of('carol'), [],
    'an emancipated account reports no ceiling' );

# ... and only for that account. Emancipation is honoured on the STARTING user
# only (SM194), so carol's peers are unaffected and her own creator still caps
# anyone else beneath it.
is_deeply( ceiling_of('dave'), [ 'bob', 'alice' ],
    "a peer's ceiling is untouched by another account's emancipation" );

# Turning it back off restores the ceiling, so the control is reversible and the
# display follows.
uapi( { action => 'account-scope-independent', username => 'carol', value => 0 } );
is_deeply( ceiling_of('carol'), [ 'bob', 'alice' ],
    'clearing the flag restores the ceiling' );

done_testing();
