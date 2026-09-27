#!/usr/bin/perl
# SM881: the engine answers "is this path gated?", and the answer has THREE
# states because a caller that moves files needs the third one.
#
# THE RULING (release manager, 2026-09-14): the ACL read lives in the engine as
# one supported answer that plugins call, not as a private read inside whichever
# plugin needs it next. The precedence already existed - `_acl_entry_for` has
# carried the full ladder since SM287 - and was simply not exported.
#
# WHY THREE STATES, which is the part of this test that matters most. The
# processor's `_acl_governed` returns 1 (governed) when the store will not load:
# correct for a READ, because if we cannot tell we should refuse to serve. A
# caller that MOVES files inverts the consequence - "could not tell" would become
# "relocate every changed file into the private store", silently unpublishing a
# site on the next pull. That is worse than the exposure being fixed, so
# 'unknown' is its own answer and a mover has to stop on it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper          qw(site_tempdir);
use Lazysite::Auth::Acl ();
use Lazysite::Paths     ();

# A docroot whose acls.json holds exactly $json (or none at all if undef).
sub site {
    my ($json) = @_;
    my $d      = site_tempdir();
    my $lz     = Lazysite::Paths::lazysite_dir($d);
    make_path("$lz/auth");
    if ( defined $json ) {
        open my $fh, '>', "$lz/auth/acls.json" or die $!;
        print {$fh} $json;
        close $fh;
    }
    return $d;
}

subtest 'no store at all is OPEN, not unknown' => sub {
    my $d = site(undef);
    is( Lazysite::Auth::Acl::gating_for( $d, 'notes/a.md' ), 'open',
        'a site with no rules gates nothing, and that is a definite answer' )
        or diag( 'Answering unknown here would stop every sync on every site '
            . 'that has never set an ACL, which is most of them.' );
};

subtest 'a rule on the folder gates what is under it' => sub {
    my $d = site('{"private":{"read":["@staff"]}}');
    is( Lazysite::Auth::Acl::gating_for( $d, 'private/secret.md' ), 'gated',
        'a file under the gated folder is gated' );
    is( Lazysite::Auth::Acl::gating_for( $d, 'private/deep/down/x.md' ), 'gated',
        'and so is one further down - the ancestor prefix carries' );
    is( Lazysite::Auth::Acl::gating_for( $d, 'public/open.md' ), 'open',
        'a file outside it is not' );
};

subtest 'the site-wide rule reaches everything under it' => sub {
    my $d = site('{"/":{"read":["@members"]}}');
    is( Lazysite::Auth::Acl::gating_for( $d, 'anything/at/all.md' ), 'gated',
        'the site-wide rule reaches an arbitrary path' );
    is( Lazysite::Auth::Acl::gating_for( $d, 'index.md' ), 'gated',
        'including the landing page' );
};

subtest 'an EMPTY read list does not carve a path out of a root rule' => sub {
    # MEASURED, and the opposite of what I first wrote. `_acl_entry_for` treats an
    # entry with an empty list for the mode as NO RULE - not as a tighter one - so
    # the ladder keeps walking outward and finds the site-wide rule. The result is
    # that `{"index":{"read":[]}}` under a private root leaves index.md gated.
    #
    # Pinned because somebody will try exactly that spelling as a way to make one
    # page public, and it reads as though it should work. A carve-out has to be a
    # more specific entry that GRANTS - a non-empty read list naming who may see
    # it - because only a non-empty list governs at all.
    my $d = site('{"/":{"read":["@members"]},"index":{"read":[]}}');
    is( Lazysite::Auth::Acl::gating_for( $d, 'index.md' ), 'gated',
        'an empty read list is the absence of a rule, so the root rule still governs' )
        or diag( 'If this ever answers open, the resolver has started treating an '
            . 'empty list as a grant, and a private site leaks its landing page.' );

    my $e = site('{"/":{"read":["@members"]},"index":{"read":["@everyone"]}}');
    is( Lazysite::Auth::Acl::gating_for( $e, 'index.md' ), 'gated',
        'and a carve-out that names a group is still GATED to this resolver, '
            . 'because gated means "a rule decides who may read it"' )
        or diag( 'This resolver answers whether access is governed, not whether '
            . 'a particular visitor passes. Who may read is _acl_allows.' );
};

subtest 'an entry with no read list gates nothing' => sub {
    # A draft-only entry, and an owner-only one that action_copy writes for every
    # duplicated file. Neither is a read gate.
    my $d = site('{"drafts":{"draft":1},"copies":{"owner":"ada"}}');
    is( Lazysite::Auth::Acl::gating_for( $d, 'drafts/x.md' ), 'open',
        'a draft section is not read-gated - it already 404s to a stranger' );
    is( Lazysite::Auth::Acl::gating_for( $d, 'copies/x.md' ), 'open',
        'and an owner-only entry is the absence of a rule, not a tight one' );
};

subtest 'a store that exists and will not parse is UNKNOWN' => sub {
    # THE TRAP THIS WHOLE TRI-STATE EXISTS FOR.
    my $d = site('{ this is not json');
    is( Lazysite::Auth::Acl::gating_for( $d, 'private/secret.md' ), 'unknown',
        'an unparseable store is not answered as open OR gated' )
        or diag( 'Answered "gated", a mover unpublishes the whole site on the '
            . 'next pull. Answered "open", the exposure this closes is back. '
            . 'Neither is acceptable, which is why there is a third state.' );

    my $e = site('[]');
    is( Lazysite::Auth::Acl::gating_for( $e, 'private/secret.md' ), 'unknown',
        'and neither is a store whose top level is not an object' );
};

subtest 'a store that cannot be OPENED is unknown, not open' => sub {
    # SM770's rule, and t/lint/121 caught the first version of this code for
    # breaking it: the reader had `return 'open' unless -e $path` in front of the
    # read. A stat this process may not make fails exactly as an open it may not
    # make, so that guard rendered a permissions fault as "no rules" - which is
    # the exposure this whole tri-state exists to avoid, arrived at by a different
    # route. The open decides now, and errno says which failure it was.
    plan skip_all => 'running as root - file modes do not bind' if $> == 0;

    my $d  = site('{"private":{"read":["@staff"]}}');
    my $lz = Lazysite::Paths::lazysite_dir($d);
    chmod 0000, "$lz/auth/acls.json" or plan skip_all => 'cannot chmod';

    is( Lazysite::Auth::Acl::gating_for( $d, 'private/secret.md' ), 'unknown',
        'an unreadable store is unknown' )
        or diag( 'Answered open, a permissions fault on acls.json would publish '
            . 'every pulled file into a gated folder and report success.' );
    is( Lazysite::Auth::Acl::root_gating($d), 'unknown',
        'and the root answer agrees' );

    chmod 0644, "$lz/auth/acls.json";
};

subtest 'an empty store file is OPEN' => sub {
    # Distinct from unparseable: an empty file is a site with no rules written
    # yet, which is an answer rather than a failure.
    my $d = site('');
    is( Lazysite::Auth::Acl::gating_for( $d, 'private/secret.md' ), 'open',
        'an empty store reads as no rules' );
};

subtest 'a missing path argument cannot be answered' => sub {
    my $d = site('{"private":{"read":["@staff"]}}');
    is( Lazysite::Auth::Acl::gating_for( $d, '' ), 'unknown',
        'an empty path is unknown rather than open' )
        or diag( 'Answering open for a path nobody named would let a caller '
            . 'with a bug publish into a gated folder and be told it was fine.' );
    is( Lazysite::Auth::Acl::gating_for( $d, undef ), 'unknown',
        'and so is an undefined one' );
};

subtest 'root_gating answers only on the site-wide key' => sub {
    # SM882's invariant needs "is this whole root gated?", and it is deliberately
    # NOT "has somebody gated every folder individually" - that shape is
    # indistinguishable from an unfinished job.
    my $all = site('{"/":{"read":["@members"]}}');
    is( Lazysite::Auth::Acl::root_gating($all), 'gated',
        'a site-wide read rule makes the root fully gated' );

    my $some = site('{"private":{"read":["@staff"]},"also":{"read":["@staff"]}}');
    is( Lazysite::Auth::Acl::root_gating($some), 'open',
        'two gated folders are not a fully gated root' )
        or diag( 'Reporting an invariant the operator never declared would make '
            . 'the check noise on every site that gates anything.' );

    is( Lazysite::Auth::Acl::root_gating( site(undef) ), 'open',
        'and no store is an open root' );
    is( Lazysite::Auth::Acl::root_gating( site('{ nope') ), 'unknown',
        'an unparseable store is unknown here too' );
};

subtest 'the two answers are exported, which is the whole point of the ruling' => sub {
    # The ruling was that a PLUGIN can ask. A sub that exists and is not exported
    # is the state this filing was raised about.
    my %ok = map { $_ => 1 } @Lazysite::Auth::Acl::EXPORT_OK;
    ok( $ok{gating_for},  'gating_for is in @EXPORT_OK' );
    ok( $ok{root_gating}, 'root_gating is in @EXPORT_OK' );
};

done_testing();
