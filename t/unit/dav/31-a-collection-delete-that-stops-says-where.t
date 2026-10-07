#!/usr/bin/perl
# SM939 SC2 (ruled R1, amended 2026-10-07): a collection DELETE that cannot finish
# says what stopped it.
#
# Recursive DELETE works (t/unit/dav/04). When a directory INSIDE the collection
# is not writable, remove_tree gets part of the way and stops; the top-level
# check saw a writable parent and answered a bare 500 "Cannot delete the entry",
# skipping the housekeeping for the pages that WERE removed. Ruled: keep recursive
# delete, answer 507 naming the directory that blocked it and what was left.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper          qw(setup_dav_site run_dav);
use Lazysite::Auth::Acl ();

sub acls {
    my ( $doc, $set ) = @_;
    local $Lazysite::Auth::Acl::DOCROOT = $doc;
    my $a = Lazysite::Auth::Acl::load_acls();
    if ($set) { $a->{$_} = $set->{$_} for keys %$set; Lazysite::Auth::Acl::save_acls($a) or die 'acls'; }
    return $a;
}

plan skip_all => 'running as root: a read-only directory does not refuse root' if $> == 0;

my $s = setup_dav_site();
my $a = $s->{auth};
my $d = $s->{docroot};
run_dav( $d, 'MKCOL', '/content/old',             HTTP_AUTHORIZATION => $a );
run_dav( $d, 'MKCOL', '/content/old/locked',      HTTP_AUTHORIZATION => $a );
run_dav( $d, 'PUT',   '/content/old/a.md',        body => "a", HTTP_AUTHORIZATION => $a );
run_dav( $d, 'PUT',   '/content/old/locked/b.md', body => "b", HTTP_AUTHORIZATION => $a );
ok( -f "$d/content/old/locked/b.md", 'the fixture: a page inside a subdirectory' );
# Rules on the collection and on the file that will be left: a partial delete
# must not forget them (forget_path takes every rule beneath a key).
acls( $d, { 'content/old' => { owner => 'deploy', write => ['deploy'] },
        'content/old/locked/b.md' => { owner => 'deploy', write => ['deploy'] } } );
chmod 0555, "$d/content/old/locked";

my $r = run_dav( $d, 'DELETE', '/content/old', HTTP_AUTHORIZATION => $a );
chmod 0755, "$d/content/old/locked";    # so the temp tree can be cleaned up

is( $r->{code}, 507, 'a partial delete answers 507, not a bare 500' ) or diag( $r->{body} );
like( $r->{body}, qr{'content/old/locked'}, 'naming the directory that stopped it, relative to the site' );
unlike( $r->{body}, qr{\Q$d\E}, 'and no filesystem path' );
like( $r->{body}, qr/1 file\(s\) were left/, 'saying how much is left' );
ok( !-e "$d/content/old/a.md",       'what could be removed was removed' );
ok( -e "$d/content/old/locked/b.md", 'and what could not is still there' );
my $kept = acls($d);
ok( $kept->{'content/old/locked/b.md'} && $kept->{'content/old'},
    'the rules on what is left are kept - forgetting them would unprotect it' );

my $ok = run_dav( $d, 'DELETE', '/content/old', HTTP_AUTHORIZATION => $a );
is( $ok->{code}, 204, 'once the directory is writable, the same DELETE finishes' );
ok( !-e "$d/content/old",                   'and the collection is gone' );
ok( !acls($d)->{'content/old/locked/b.md'}, 'and its rules with it' );

done_testing();
