#!/usr/bin/perl
# SM268: regression tests for the August 2026 adversarial security review.
#
# Every case here was REPRODUCED by a reviewer against the pre-release tree
# before it was fixed. The point of this file is that none of them creep back:
# each subtest fails on the unfixed code.
#
# They are grouped because they share a shape rather than a component: in all
# four, a guard existed and did not cover the spelling, the caller or the
# namespace it was written for. That is the class this file guards.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root);
use Lazysite::Manager::Common  ();
use Lazysite::Manager::Plugins ();
use Lazysite::Manager::Backups ();

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

# --- C1: `local` is the operator identity, not an available username --------
# A delegate holding only create_sub_users made an account called `local`; every
# `ne 'local'` check in the codebase then handed it operator status - the
# %COOKIE_CAP gate, %DELEGABLE, the %ACTOR_FORBIDDEN backstop and the SM195
# ceiling, all bypassed at once.
subtest 'the username `local` is reserved at every door' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    my $tool = repo_root() . '/tools/lazysite-users.pl';

    my $run = sub {
        my @a   = @_;
        my $cmd = join ' ', map { quotemeta } $^X, $tool, '--docroot', $d, @a;
        return scalar qx($cmd 2>&1);
    };

    like( $run->( 'add', 'local', 'pw' ), qr/reserved/,
        'add refuses it' );
    ok( !-e "$d/lazysite/auth/users" || $run->('list') !~ /^local:/m,
        'and no such account exists' );

    $run->( 'add', 'boss', 'pw' );
    like( $run->( 'account-create', 'local', 'pw', '--by', 'boss' ), qr/reserved/,
        'sub-user creation refuses it - the door the reproduction used' );

    $run->( 'add', 'alice', 'pw' );
    like( $run->( 'rename', 'alice', 'local' ), qr/reserved/,
        'and rename cannot arrive at it either - one unreserved door is the '
            . 'whole vulnerability' );

    # Case matters: the sentinel comparisons are exact, so a case variant must
    # not slip through and then be normalised somewhere downstream.
    like( $run->( 'add', 'LOCAL', 'pw' ), qr/reserved/, 'case variants too' );
};

# --- C2: the reserved-root check compared literally --------------------------
# `./lazysite` was not "lazysite" and not under "lazysite/", so a domain's
# content_root could be set there and a "no secrets" site package exported the
# account store, the ACLs and the session HMAC secret.
subtest 'path_is_reserved normalises before comparing' => sub {
    for my $spelling (
        'lazysite',       'lazysite/auth',
        './lazysite',     './lazysite/auth',
        './/lazysite',    'lazysite//auth',
        '/lazysite/auth', './/lazysite/auth/users',
        'lazysite/./auth',
        )
    {
        ok( Lazysite::Manager::Common::path_is_reserved($spelling),
            "reserved: $spelling" );
    }

    # And it must not over-reach onto ordinary content that merely starts with
    # the same letters - a guard that refuses real content gets turned off.
    for my $ok (qw(lazysiteen content/lazysite-notes notes/lazysite.md)) {
        ok( !Lazysite::Manager::Common::path_is_reserved($ok),
            "not reserved: $ok" );
    }
};

# --- C3: the tar exclusion only matched archives tar itself made -------------
# GNU tar matches --exclude against the member name as stored, so a hostile
# archive naming its member `lazysite/auth/users` (no `./`) walked straight
# through the M-TAR-AUTH guard and replaced the account store.
subtest 'restore excludes lazysite/ however the member is spelled' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/stage/lazysite/auth", "$d/stage/content" );
    spit( "$d/lazysite/lazysite.conf",    "site_name: T\n" );
    spit( "$d/lazysite/auth/users",       "operator:REAL-HASH\n" );
    spit( "$d/stage/lazysite/auth/users", "attacker:ATTACKER-HASH\n" );
    spit( "$d/stage/content/page.md",     "# hello\n" );

    # Build the hostile archive with member names that carry NO leading "./".
    my $pkg = "$d/lazysite/backups/lazysite-site-uploaded-20260809T000000Z.tar.gz";
    make_path("$d/lazysite/backups");
    my $stage = "$d/stage";
    system( 'tar', 'czf', $pkg, '-C', $stage, 'lazysite', 'content' ) == 0
        or plan skip_all => 'tar unavailable';

    my @members = `tar tzf \Q$pkg\E 2>/dev/null`;
    ok( ( grep { m{\Alazysite/auth/users} } @members ),
        'the archive really does name the member without ./ - otherwise this '
            . 'test would pass for the wrong reason' );

    local $Lazysite::Manager::Backups::DOCROOT      = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
    my $r = Lazysite::Manager::Backups::action_backup_restore(
        'lazysite-site-uploaded-20260809T000000Z.tar.gz');
    ok( $r->{ok}, 'the restore ran' ) or diag( $r->{error} // '' );

    open my $uf, '<', "$d/lazysite/auth/users" or die $!;
    my $users = do { local $/; <$uf> };
    close $uf;
    like( $users, qr/REAL-HASH/, 'the real account store survived' );
    unlike( $users, qr/ATTACKER-HASH/,
        'and the archive did NOT overwrite it - this is the documented '
            . 'escalation chain the guard claimed to neutralise' );

    ok( -f "$d/content/page.md", 'while ordinary content still restored' );
};

# --- H1: the submissions reader was an arbitrary .jsonl reader --------------
# A token holding the least-privilege read_submissions capability read
# lazysite/auth/sessions.jsonl - operator usernames, source IPs, User-Agents and
# session ids - and another domain's leads.
subtest 'form-submissions is confined to the submission stores' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/auth", "$d/lazysite/forms/submissions", "$d/content/clientB" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/sessions.jsonl",
        qq({"t":1786000000,"user":"admin","ip":"198.51.100.9","sid":"a1b2c3d4"}\n) );
    spit( "$d/content/clientB/leads.jsonl",
        qq({"email":"ceo\@clientb.example","secret":"private"}\n) );
    spit( "$d/lazysite/forms/submissions/contact.jsonl",
        qq({"name":"a real submission"}\n) );

    local $Lazysite::Manager::Plugins::DOCROOT = $d;

    for my $bad (qw(lazysite/auth/sessions.jsonl content/clientB/leads.jsonl)) {
        my $r = Lazysite::Manager::Plugins::action_form_submissions($bad);
        ok( !$r->{ok}, "refused: $bad" );
        is( scalar @{ $r->{rows} || [] }, 0, "and returned no rows: $bad" );
    }

    my $good = Lazysite::Manager::Plugins::action_form_submissions(
        'lazysite/forms/submissions/contact.jsonl');
    ok( $good->{ok}, 'a real submissions store still reads' );
    is( scalar @{ $good->{rows} || [] }, 1, 'and returns its rows' );
};

done_testing();
