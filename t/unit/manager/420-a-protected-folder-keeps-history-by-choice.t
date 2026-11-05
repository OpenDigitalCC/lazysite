#!/usr/bin/perl
# SM1324 (ruling 50, T-16): A PROTECTED FOLDER KEEPS HISTORY BY CHOICE.
#
# Protected content lives in the private store, outside the docroot the content
# history versions, so it never had a history (SM286, SM683). A folder rule may
# now say `history: true`, and the folder's versions are kept in a SECOND
# repository whose work tree is the private store - never the public one, whose
# history can be pushed to a remote.
#
# What this holds:
#   - OFF by default: a protected folder with no `history` keeps none, and no
#     private repository is ever created;
#   - ON: kept, in the private store's repository, with nothing of the content
#     in the public repository;
#   - listed only to readers: a caller the folder's read rule refuses cannot
#     list, view or restore a version, and the overview leaves the file out;
#   - restore respects the write rule;
#   - a folder only: the site-wide rule and a single file are refused.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use JSON::PP ();
use Lazysite::Git ();
use TestHelper qw(repo_root run_child);

plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();
use Lazysite::Private         ();

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
}

# A site with content history on, and a folder `members` the operator protects
# for alice (read and write) and carol (read only).
sub site {
    my $t = tempdir( CLEANUP => 1 );
    my $d = "$t/site";    # a nested docroot, so the store beside it is ours
    make_path( "$d/lazysite/auth", "$d/members", "$d/open" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ngit_history: enabled\n" );
    spit( "$d/members/plan.md",        "---\ntitle: Plan\n---\n\nSECRET-ONE\n" );
    spit( "$d/open/x.md",              "---\ntitle: X\n---\n\nopen\n" );
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    $Lazysite::Auth::Acl::DOCROOT       = $d;
    $Lazysite::Manager::Files::LOCK_DIR = "$t/locks";
    Lazysite::Git::reset_cache();
    my $i = Lazysite::Git::init( $d, 'local' );
    die 'git init failed' unless $i->{ok};
    as_operator();
    return ( $t, $d );
}

# The operator writes the rules; the members read as partners would, where no
# bypass applies (a token is never the operator).
sub as_operator {
    $Lazysite::Auth::Acl::token_auth    = 0;
    $Lazysite::Auth::Acl::auth_user     = 'local';
    $Lazysite::Manager::Common::auth_user = 'local';
    return;
}

sub as_partner {
    my ($who) = @_;
    $Lazysite::Auth::Acl::token_auth      = 1;
    $Lazysite::Auth::Acl::auth_user       = $who;
    $Lazysite::Manager::Common::auth_user = $who;
    return;
}

sub protect {
    my (%o) = @_;
    as_operator();
    my $r = Lazysite::Manager::Files::action_acl_set( 'members', 'local', [ 'alice', 'carol' ],
        ['alice'], 'local', undef, { %o } );
    ok( $r->{ok}, 'the folder rule is written' ) or diag explain $r;
    return $r;
}

sub save_as {
    my ( $who, $rel, $text ) = @_;
    as_partner($who);
    my $r = Lazysite::Manager::Files::action_save( $rel, $who, $text, undef );
    as_operator();
    return $r;
}

sub slurp {
    open my $fh, '<', $_[0] or return '';
    local $/;
    return scalar <$fh>;
}

sub private_git { return Lazysite::Private::private_root( $_[0] ) . '/lazysite/git' }

sub public_log {
    my ($d) = @_;
    my ( undef, $out ) = Lazysite::Git::run_git( $d, 'log', '--all', '-p' );
    return $out // '';
}

subtest 'OFF by default: a protected folder keeps no history' => sub {
    my ( $t, $d ) = site();
    protect();
    ok( -e Lazysite::Private::private_path( $d, 'members/plan.md' ), 'the folder is in the private store' );
    my $s = save_as( 'alice', 'members/plan.md', "---\ntitle: Plan\n---\n\nSECRET-TWO\n" );
    ok( $s->{ok}, 'alice saves' ) or diag explain $s;

    ok( !-e private_git($d), 'no private repository is created' )
        or diag('A site that never asked for protected history must not grow a copy of its protected content.');
    as_partner('alice');
    my $h = Lazysite::Manager::Files::action_git_history( 'members/plan.md', 'alice' );
    ok( $h->{ok}, 'the history answers' );
    is_deeply( $h->{versions}, [], 'with no versions' );
    ok( !$h->{versioned}, 'and says the file is not versioned' );
    like( $h->{notice} // '', qr/set history on the folder's rule/, 'and how to keep it' );
    unlike( public_log($d), qr/SECRET-TWO/, 'the public history has none of it' );
};

subtest 'ON: kept in the private repository, and only there' => sub {
    my ( $t, $d ) = site();
    my $r = protect( history => JSON::PP::true() );
    ok( $r->{acl}{history}, 'the rule records history' );
    ok( -f private_git($d) . '/HEAD', 'a private repository exists' );
    is( index( private_git($d), "$d/" ), -1, 'outside the document root' );
    is( sprintf( '%04o', ( stat private_git($d) )[2] & 07777 ), '2770',
        "with the store's own permissions" );

    my $s = save_as( 'alice', 'members/plan.md', "---\ntitle: Plan\n---\n\nSECRET-TWO\n" );
    ok( $s->{ok}, 'alice saves' ) or diag explain $s;

    as_partner('alice');
    my $h = Lazysite::Manager::Files::action_git_history( 'members/plan.md', 'alice' );
    ok( $h->{versioned}, 'the file is versioned' ) or diag explain $h;
    is( scalar @{ $h->{versions} || [] }, 2, 'the first version and the edit' );
    is( $h->{history_kept_by}, '/members', 'kept by the folder rule' );
    ok( !defined $h->{notice}, 'with no notice' );

    my $old = $h->{versions}[-1]{sha};
    my $v   = Lazysite::Manager::Files::action_git_show( 'members/plan.md', 'alice', $old );
    ok( $v->{ok}, 'alice views the first version' ) or diag explain $v;
    like( $v->{content} // '', qr/SECRET-ONE/, 'and it is the first version' );

    # SECRET-ONE is there: it was public, and versioned publicly, before the
    # folder was protected (SM683's third step, which this does not address).
    # Nothing written after protection may join it.
    unlike( public_log($d), qr/SECRET-TWO/, 'the public repository holds none of what was kept' )
        or diag('Two object stores is the design: a public history can be pushed to a remote.');

    my $sum = Lazysite::Manager::Files::action_git_history_summary( [], 'alice' );
    ok( ( grep { $_->{path} eq 'members/plan.md' } @{ $sum->{files} || [] } ),
        'the overview lists it to a reader' );
};

subtest 'a non-reader cannot list, view or restore' => sub {
    my ( $t, $d ) = site();
    protect( history => 'true' );
    save_as( 'alice', 'members/plan.md', "---\ntitle: Plan\n---\n\nSECRET-TWO\n" );
    as_partner('alice');
    my $sha = Lazysite::Manager::Files::action_git_history( 'members/plan.md', 'alice' )->{versions}[-1]{sha};
    ok( $sha, 'a version exists' ) or return;

    as_partner('bob');
    my $h = Lazysite::Manager::Files::action_git_history( 'members/plan.md', 'bob' );
    ok( !$h->{ok}, 'bob cannot list it' );
    ok( !exists $h->{versions}, 'and is handed no versions' );
    my $v = Lazysite::Manager::Files::action_git_show( 'members/plan.md', 'bob', $sha );
    ok( !$v->{ok}, 'bob cannot view a version' );
    unlike( $v->{content} // '', qr/SECRET/, 'and is handed no content' );
    my $x = Lazysite::Manager::Files::action_git_restore( 'members/plan.md', 'bob', $sha );
    ok( !$x->{ok}, 'bob cannot restore one' );
    my $sum = Lazysite::Manager::Files::action_git_history_summary( [], 'bob' );
    ok( !( grep { $_->{path} eq 'members/plan.md' } @{ $sum->{files} || [] } ),
        'the overview leaves it out for him' );
    ok( ( grep { $_->{path} eq 'open/x.md' } @{ $sum->{files} || [] } ),
        '...and still lists what he may read' );
    as_operator();
    like( slurp( Lazysite::Private::private_path( $d, 'members/plan.md' ) ),
        qr/SECRET-TWO/, 'the file is as alice left it' );
};

subtest 'restore respects the write rule' => sub {
    my ( $t, $d ) = site();
    protect( history => 1 );
    save_as( 'alice', 'members/plan.md', "---\ntitle: Plan\n---\n\nSECRET-TWO\n" );
    as_partner('carol');
    my $h = Lazysite::Manager::Files::action_git_history( 'members/plan.md', 'carol' );
    ok( $h->{ok} && @{ $h->{versions} || [] } == 2, 'carol, a reader, lists the versions' );
    my $sha = $h->{versions}[-1]{sha};
    my $x   = Lazysite::Manager::Files::action_git_restore( 'members/plan.md', 'carol', $sha );
    ok( !$x->{ok}, 'carol, who may not write, cannot restore' ) or diag explain $x;

    as_partner('alice');
    my $y = Lazysite::Manager::Files::action_git_restore( 'members/plan.md', 'alice', $sha );
    ok( $y->{ok}, 'alice, who may write, restores' ) or diag explain $y;
    my $after = Lazysite::Manager::Files::action_git_history( 'members/plan.md', 'alice' );
    is( scalar @{ $after->{versions} || [] }, 3, 'and the restore is the newest version' );
    like( $after->{versions}[0]{subject} // '', qr/\Arestore members\/plan\.md/, 'named as a restore' );
};

subtest 'a folder only' => sub {
    my ( $t, $d ) = site();
    as_operator();
    my $r = Lazysite::Manager::Files::action_acl_set( 'open/x.md', 'local', ['alice'], ['alice'],
        'local', undef, { history => 1 } );
    ok( !$r->{ok}, 'a single file is refused' );
    is( $r->{field}, 'history', 'naming the field' );
    my $s = Lazysite::Manager::Files::action_acl_set( '/', 'local', ['alice'], ['alice'],
        'local', undef, { history => 1 } );
    ok( !$s->{ok}, 'the site-wide rule is refused' );
    my $u = Lazysite::Manager::Files::action_acl_set( 'members', 'local', ['alice'], ['alice'],
        'local', undef, { history => 'please' } );
    ok( !$u->{ok}, 'an unrecognised value is refused' );
    ok( !exists Lazysite::Auth::Acl::load_acls()->{members}, '...and writes nothing' );
};

subtest 'a protected folder beside one that keeps history keeps none' => sub {
    my ( $t, $d ) = site();
    make_path("$d/staff");
    spit( "$d/staff/rota.md", "---\ntitle: Rota\n---\n\nSTAFF-ONE\n" );
    protect( history => 1 );
    as_operator();
    my $r = Lazysite::Manager::Files::action_acl_set( 'staff', 'local', ['alice'], ['alice'],
        'local', undef, {} );
    ok( $r->{ok} && !$r->{acl}{history}, 'staff is protected without history' );
    save_as( 'alice', 'staff/rota.md', "---\ntitle: Rota\n---\n\nSTAFF-TWO\n" );
    as_partner('alice');
    my $h = Lazysite::Manager::Files::action_git_history( 'staff/rota.md', 'alice' );
    ok( !$h->{versioned}, 'its file is not versioned' );
    is_deeply( $h->{versions}, [], 'and has no versions' );
    my ( undef, $log ) = Lazysite::Git::run_git( Lazysite::Private::private_root($d), 'log', '--all', '-p' );
    unlike( $log // '', qr/STAFF-/, 'the private repository holds nothing of it' )
        or diag('The rule that relocates a path decides; a folder that did not opt in is never read into it.');
};

subtest 'switching it off stops recording and keeps what was recorded' => sub {
    my ( $t, $d ) = site();
    protect( history => 1 );
    my $r = protect( history => 0 );
    ok( !$r->{acl}{history}, 'the rule no longer records history' );
    save_as( 'alice', 'members/plan.md', "---\ntitle: Plan\n---\n\nSECRET-THREE\n" );
    as_partner('alice');
    my $h = Lazysite::Manager::Files::action_git_history( 'members/plan.md', 'alice' );
    is( scalar @{ $h->{versions} || [] }, 1, 'the first version is still listed' );
    ok( !$h->{versioned}, 'and the file is no longer versioned' );
};

# The CLI is one of the four surfaces that set a rule; it carries the flag to
# the same writer, and `show` says so.
subtest 'lazysite acl set --history' => sub {
    my ( $t, $d ) = site();
    my $tool = repo_root() . '/tools/lazysite-acl.pl';
    my $set  = run_child( [ $^X, $tool, 'set', 'members', '--docroot', $d, '--actor', 'local',
            '--read', 'alice', '--write', 'alice', '--history' ], stderr => 'inherit' );
    is( $set->{status}, 0, 'set exits 0' ) or diag $set->{out};
    my $raw = slurp("$d/lazysite/auth/acls.json");
    like( $raw, qr/"history"\s*:\s*true/, 'the rule carries history' );
    ok( -f private_git($d) . '/HEAD', 'and the private repository is made' );
    my $show = run_child( [ $^X, $tool, 'show', 'members', '--docroot', $d, '--actor', 'local' ],
        stderr => 'inherit' );
    like( $show->{out}, qr/history: kept/, 'show says so' );
};

done_testing();
