#!/usr/bin/perl
# SM310: acl-get reads the site root the same way set and remove write it.
#
# THE DEFECT. SM287 taught the two WRITERS that '/', '', '.' and './' all mean
# the whole site, and taught the protected-sections panel to list such a rule
# with site_wide:1. It did not teach action_acl_get, which still went through
# validate_path and _acl_norm - and _acl_norm strips leading slashes, so the
# canonical key '/' that the writer produces became the lookup key '' and missed.
#
# The result: asking "what rule governs the site root?" answered `acl: null`
# while a site-wide rule was in force and being enforced on every request. Two
# readers of one store disagreed, and the wrong one is the one a caller checking
# a SPECIFIC path would use - including anything reconciling a path against the
# rule that governs it.
#
# HOW IT WAS FOUND. Not by review. A control subtest in the SM306 work asserted
# that an explicit site-wide rule still worked, wrote one, and could not read it
# back. The assertion was there to prove the SM306 fix had not broken the
# feature; it found a different defect that had shipped in 0.10.8 and survived
# 0.10.9.
#
# That is the same shape as SM287's own note - "found by the writer test, not by
# review" - which is worth recording, because it is now twice that this store's
# root handling was fixed on one side and left on the other. The remedy each
# time was a test that made a round trip rather than checking one direction.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Manager::Files qw(action_acl_set action_acl_get action_acl_remove);
use Lazysite::Auth::Acl      qw(load_acls);

my $docroot = tempdir( CLEANUP => 1 );
mkdir "$docroot/lazysite"      or die $!;
mkdir "$docroot/lazysite/auth" or die $!;

# All three, as t/unit/manager/67 does. Setting only Files::DOCROOT leaves
# Common and Private reading an undefined docroot, which still passes while
# emitting a page of uninitialised-value warnings - a test that works by
# accident is not evidence.
$Lazysite::Manager::Files::DOCROOT  = $docroot;
$Lazysite::Manager::Common::DOCROOT = $docroot;
$Lazysite::Auth::Acl::DOCROOT       = $docroot;

# THE FIXTURE IS WRITTEN BY THE REAL WRITER, never by hand. A hand-built store
# is how the SM292 defect survived: the protected-sections tests wrote acls.json
# themselves with trailing slashes, so they agreed with each other and never with
# the writer, and the panel was empty for everyone using the supported route.
sub write_root_rule {
    my $r = action_acl_set( '/', 'operator',
        ['alice'], ['alice'], undef, undef );
    die 'fixture: the writer refused a root rule' unless $r->{ok};
    return $r;
}

subtest 'a rule written at the root is readable at the root' => sub {
    write_root_rule();

    for my $spelling ( '/', '', '.', './' ) {
        my $g = action_acl_get( $spelling, 'operator' );
        ok( $g->{ok}, "acl-get('$spelling') succeeds" );
        is_deeply( $g->{acl}{read}, ['alice'],
            "acl-get('$spelling') returns the rule the writer stored" )
            or diag( "Got: " . ( defined $g->{acl} ? 'a rule' : 'acl => null' )
                . " - the store holds the key the writer produced, and this"
                . " reader looked somewhere else." );
        is( $g->{path}, '/', "and reports the canonical path for '$spelling'" );
    }
};

subtest 'the answer agrees with the sections panel' => sub {
    # Two readers, one store. The panel was right throughout; that is precisely
    # why the disagreement went unnoticed - the screen an operator looks at
    # showed the rule, so nothing looked wrong from the outside.
    my $p = Lazysite::Manager::Files::action_protected_sections( 'operator', [] );
    my ($site_wide) = grep { $_->{site_wide} } @{ $p->{sections} || [] };
    ok( $site_wide, 'protected-sections lists the site-wide rule' );

    my $g = action_acl_get( '/', 'operator' );
    is_deeply( $g->{acl}{read}, $site_wide->{read},
        'and acl-get agrees with it about who may read' );
};

subtest 'a glob spelling is refused, as it is for set and remove' => sub {
    # SM287 refuses '*' on the writers because the store has no glob syntax
    # anywhere else, so accepting one would imply a matching language that does
    # not exist. A reader that quietly returned null for '*' would suggest the
    # same thing more subtly: that the pattern was understood and matched
    # nothing.
    for my $glob ( '*', '/*', '**' ) {
        my $g = action_acl_get( $glob, 'operator' );
        ok( !$g->{ok}, "acl-get('$glob') is refused" );
        like( $g->{error} // '', qr{"/"},
            "and names \"/\" as the way to ask about the whole site" );
    }
};

subtest 'an ordinary path is unaffected' => sub {
    mkdir "$docroot/section" or die $!;
    my $w = action_acl_set( '/section', 'operator',
        ['bob'], ['bob'], undef, undef );
    ok( $w->{ok}, 'a folder rule is written' );

    my $g = action_acl_get( '/section', 'operator' );
    is_deeply( $g->{acl}{read}, ['bob'],
        'and reads back unchanged - the root branch does not capture it' );
};

done_testing();
