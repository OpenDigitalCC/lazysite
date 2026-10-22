#!/usr/bin/perl
# SM1264 (ruled 2026-10-22): THE FORM CHECK SEES WHAT IT DID NOT, AND WARNS.
#
# The validator passed any `key:value` rule, so `maxx:5` or `capture:front` -
# dropped without a word when the form renders - went unreported, and it read
# only the FIRST `::: form` block of a page though the renderer renders every
# one. Both are reported now, as WARNINGS: what blocked a save before (an
# unknown word or an uncompilable pattern in the first block) is the only
# thing that still does. Asserted through validate_content, `lazysite
# validate`, and a manager save of the same page.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use Lazysite::Validate ();

sub check { Lazysite::Validate::validate_content( content => $_[0] ) }
sub kinds { my ( $r, $sev ) = @_; [ map { $_->{kind} } @{ $r->{$sev} } ] }
sub page  { "---\ntitle: T\nform: f\n---\n\n" . join( "\n", map {"::: form\n$_\nsubmit | Go\n:::\n"} @_ ) }

# --- an unknown key:value, in the first block: a warning, never an issue -------
for my $tok (qw(maxx:5 capture:front max:many colour:red)) {
    my $r = check( page("x | X | required $tok") );
    ok( $r->{valid}, "$tok: the page is still valid" );
    is_deeply( kinds( $r, 'issues' ), [], "$tok: no issue" );
    ok( ( grep { $_->{kind} eq 'unknown-form-rule' && $_->{message} =~ /\Q'$tok'\E/ } @{ $r->{warnings} } ),
        "$tok: a warning names it" );
}
for my $tok ( 'max:200', 'capture:user', 'placeholder:"Your name"', 'value:', 'prefill:ref', 'checklist-qty:a,b' ) {
    my $r = check( page("x | X | $tok") );
    ok( !( grep { $_->{kind} eq 'unknown-form-rule' } @{ $r->{warnings} } ), "$tok: a rule the form reads is not warned" );
}

# --- the first block's issues are exactly what they were -------------------------
{
    my $r = check( page('x | X | requierd') );
    ok( !$r->{valid}, 'an unknown word in the first block still fails the page' );
    is_deeply( kinds( $r, 'issues' ), ['invalid-form-rule'], 'as invalid-form-rule' );
    $r = check( page('x | X | pattern:[a-') );
    is_deeply( kinds( $r, 'issues' ), ['uncompilable-pattern'], 'and a broken pattern there as uncompilable-pattern' );
}

# --- a later block: read, and warned -----------------------------------------------
{
    my $r = check( page( 'x | X | required', 'y | Y | requierd', 'z | Z | pattern:[a-' ) );
    ok( $r->{valid}, 'a typo in the second or third form does not fail the page' );
    my @w = @{ $r->{warnings} };
    ok( ( grep { $_->{kind} eq 'unknown-form-rule' && $_->{message} =~ /^form 2: unknown form rule 'requierd'/ } @w ),
        'the second form\'s typo is a warning naming its form' );
    ok( ( grep { $_->{kind} eq 'pattern-will-not-compile' && $_->{message} =~ /^form 3: the pattern on field 'z'/ } @w ),
        'and the third form\'s broken pattern too' );

    $r = check( page('x | X | requierd') );
    is( scalar( grep { $_->{message} =~ /requierd/ } @{ $r->{warnings} } ), 0,
        'the first block\'s issue is not repeated as a warning' );
}

# --- the same page through `lazysite validate` and a manager save -----------------
my $pg = page( 'x | X | required maxx:5', 'y | Y | requierd' );
{
    my $f = "/tmp/sm1264-$$.md";
    open my $fh, '>', $f or die $!;
    print {$fh} $pg;
    close $fh;
    my $out = `\Q$^X\E -I\Q@{[repo_root()]}/lib\E \Q@{[repo_root()]}/tools/lazysite-validate.pl\E \Q$f\E 2>&1`;
    my $rc  = $? >> 8;
    unlink $f;
    is( $rc, 0, 'lazysite validate passes the page' ) or diag $out;
    like( $out, qr/maxx:5/, 'and prints the warning' );
}
SKIP: {
    skip 'manager api missing', 2 unless -f repo_root() . '/lazysite-manager-api.pl';
    my $s = new_site( root => repo_root() );
    $s->add_user('writer');
    $s->grant( 'writer', 'editors', [qw(ui manage_content)], [qw(ui manage_content)] );
    my $r = $s->call( 'writer', 'save', query => 'action=save&path=/sm1264.md', body => { content => $pg } );
    ok( $r->{ok}, 'a manager save of the page succeeds' ) or diag explain $r;
    my $d = $s->docroot;
    ok( -f "$d/sm1264.md", 'and the page is written' );
}

done_testing();
